#!/usr/bin/env python3
"""OneDrive MCP server — zero-dependency (Python stdlib only).

Speaks MCP (JSON-RPC 2.0, newline-delimited) over stdio. Any MCP client
(Claude, Cursor, Hermes, etc.) can load it. No pip installs, rebuild-proof.

Token: ~/.hermes/onedrive_token.json (0600, self-refreshing). Override with
the ONEDRIVE_TOKEN env var to target another account's token file (multi-
account support; the lock sidecar derives from TOKEN_PATH, so per-token-path
locks never contend across accounts).

Client id: read from the ONEDRIVE_CLIENT_ID env var (populated by the agent's
agenix-encrypted .env). It is an identifier, not a secret, but it still lives
in the encrypted .env, not in code. Only needed for the self-login flow (see
below); normal operation uses the stored token's own client_id.

Self-login (device code): when NO valid local token exists, any tool call
starts the device-code login itself instead of failing:
  * the first call POSTs /devicecode (tenant consumers), spawns a DAEMON
    background thread that polls /token at Microsoft's interval until expiry,
    and RETURNS IMMEDIATELY with the verification URL + user code. (An MCP
    stdio call is synchronous — polling WITHIN the same tools/call would
    deadlock: the client can only show the user the link+code once the call
    returns.)
  * while the login is pending, further calls return "login in progress"
    (isError=true — the drive is genuinely unusable until the user enters the
    code; the message tells them exactly what to do).
  * when the daemon thread completes it writes the token file atomically under
    the _TokenLock (0600), so the very next call just works. On expiry the
    thread dies, state resets, and the next call offers a FRESH code.
  * a single process-level state machine (guarded by _LOGIN_LOCK) ensures two
    concurrent calls start exactly ONE device-code flow; later calls report
    the pending one's URL+code. The daemon thread does HTTP + file writes
    only — the main thread exclusively owns stdin/stdout.

Security: reads/searches cover the whole drive (Files.Read); writes are
API-confined by Microsoft to the app folder (Files.ReadWrite.AppFolder).

Graph endpoint quirks (verified against this app's token, 2026-09-17):
  * PUT /content with RAW body bytes stores the content verbatim (byte-exact
    read-back, verified 2026-09-17 via the proven onedrive_api.py token).
    The {"@content.bytes": ...} JSON envelope is stored VERBATIM as the file
    content instead (verified 2026-09-17: 62-byte envelope file for a 30-byte
    payload) — so writes must send raw bytes. Content-Type must be
    application/json: one backend rejects non-JSON Content-Types with 400
    "Entity only allows writes with a JSON Content-Type header" (header check
    only; body still stored as-is).
  * Item paths (/.../folder/name) are rejected with a generic invalidRequest
    on content/mutation calls for this app's token (SharePoint routing);
    the children/ form (/.../folder/children/name) is the ONLY form that
    works for PUT/DELETE (ground-truthed 2026-09-17: 201/204 vs 400).
    A by-name PUT without /content 400s ("Either 'folder' or 'file'...").
  * GET /content on approot items is routed to SharePoint and returns 401
    'unauthenticated' even with a fresh token; metadata GET (children/ form
    for approot) and the @microsoft.graph.downloadUrl it returns work fine,
    so reads fall back to the download URL (raw bytes, verified exact).
  * $search is a NO-OP on this drive (returns the children list unfiltered,
    in every scope), so name search is done client-side against the listed
    children of a scope (default: the app folder).
  * Graph backend routing for approot content/mutation calls was flaky
    (identical requests intermittently 400 for a few minutes). The
    deterministic 400s are resolved by the JSON-envelope write above; api()
    still retries transient 401/429 and network errors (never 404 —
    itemNotFound is a definitive answer).

Usage:
    python3 mcp_server.py            # reads stdin, writes stdout (NDJSON)
"""
import base64
import fcntl
import json
import os
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

TOKEN_PATH = os.path.expanduser(os.environ.get("ONEDRIVE_TOKEN", "~/.hermes/onedrive_token.json"))
LOCK_PATH = TOKEN_PATH + ".lock"
CLIENT_ID = os.environ.get("ONEDRIVE_CLIENT_ID", "")  # from the agenix .env
TENANT = "consumers"  # personal accounts; use your tenant id for M365
AUTH_URL = f"https://login.microsoftonline.com/{TENANT}/oauth2/v2.0/token"
DEVICECODE_URL = f"https://login.microsoftonline.com/{TENANT}/oauth2/v2.0/devicecode"
SCOPES = "Files.Read Files.ReadWrite.AppFolder offline_access openid profile"
GRAPH = "https://graph.microsoft.com/v1.0"
NET_TIMEOUT = 30  # every urlopen gets this; no indefinite hangs on stalled sockets
_LOCK_ATTEMPTS = 3      # non-blocking acquire tries before giving up
_LOCK_RETRY_SLEEP = 1.0  # seconds between tries (~3 x 1s total budget)
PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "onedrive"
SERVER_VERSION = "1.1.0"


# ---------- token ----------
def _load():
    with open(TOKEN_PATH) as f:
        return json.load(f)


def _save(t):
    # Ensure the parent dir exists: the self-login flow writes the token file
    # fresh (e.g. a brand-new account's path), and the default ~/.hermes/ may
    # not exist yet. abspath() guards against a bare filename (empty dirname).
    os.makedirs(os.path.dirname(os.path.abspath(TOKEN_PATH)), exist_ok=True)
    with open(TOKEN_PATH, "w") as f:
        f.write(json.dumps(t, indent=2))
    os.chmod(TOKEN_PATH, 0o600)


class _TokenLock:
    """Best-effort flock on a sidecar file; serialises token refresh across
    concurrent Hermes profiles / MCP server processes.

    Acquire is NON-BLOCKING (LOCK_NB): we never hold up another profile's
    request queue. On contention we retry ~3x1s; if we still can't take it we
    give up (held==False) so the caller falls through WITHOUT the lock —
    never deadlocking, and never raising out of access_token() (which sits
    outside api()'s transient-retry try/except). In that rare fall-through the
    in-lock re-read still lets us piggyback on a sibling's fresh token, and a
    genuinely-lost race surfaces as the usual transient 401 that api() retries.
    The lock is advisory — it only orders the read-modify-write of the token
    file; a process that loses the race simply re-reads the winner's token.
    """

    def __init__(self, path=None):
        # Lazy read of the module global so a HOME/token override (tests)
        # resolves the matching sidecar lock at call time, not import time.
        self._path = path if path is not None else LOCK_PATH
        self._fd = None
        self.held = False

    def acquire(self, attempts=_LOCK_ATTEMPTS, sleep_s=_LOCK_RETRY_SLEEP):
        for _ in range(attempts):
            try:
                fd = os.open(self._path, os.O_RDWR | os.O_CREAT, 0o600)
            except OSError:
                return False
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except OSError:
                os.close(fd)
                time.sleep(sleep_s)
                continue
            self._fd = fd
            self.held = True
            return True
        return False

    def release(self):
        if self._fd is not None:
            try:
                fcntl.flock(self._fd, fcntl.LOCK_UN)
            finally:
                os.close(self._fd)
                self._fd = None
        self.held = False

    def __enter__(self):
        # Best-effort: proceed whether or not the lock was taken (never raise).
        self.acquire()
        return self

    def __exit__(self, exc_type, exc, tb):
        self.release()
        return False


def access_token():
    t = _load()
    if t.get("access_token_expires", 0) > time.time() + 60:
        return t["access_token"]
    with _TokenLock():
        # Re-read under the lock: a sibling may have refreshed while we waited.
        t = _load()
        if t.get("access_token_expires", 0) > time.time() + 60:
            return t["access_token"]
        body = urllib.parse.urlencode({
            "grant_type": "refresh_token",
            "refresh_token": t["refresh_token"],
            "client_id": t["client_id"],
        }).encode()
        r = urllib.request.urlopen(urllib.request.Request(AUTH_URL, data=body),
                                   timeout=NET_TIMEOUT)
        d = json.loads(r.read())
        t["access_token"] = d["access_token"]
        if "refresh_token" in d:
            t["refresh_token"] = d["refresh_token"]
        t["access_token_expires"] = time.time() + d.get("expires_in", 3600)
        _save(t)
        return t["access_token"]


def _ttl():
    try:
        return max(0, int(_load().get("access_token_expires", 0) - time.time()))
    except (ValueError, TypeError):
        return 0


# ---------- self-login (device code) ----------
_LOGIN_LOCK = threading.Lock()  # guards the process-level login state machine
_login_state = {
    "pending": False,
    "verification_uri": "",
    "user_code": "",
    "started_at": 0.0,
    "thread": None,
}


def _login_message(state):
    return (f"OneDrive login in progress — open {state['verification_uri']}, "
            f"sign in, and enter the code {state['user_code']}. "
            f"Once entered, just re-run this tool / ask again; the token is "
            f"saved automatically and subsequent calls work.")


def _start_device_login(client_id):
    """Start the device-code flow; spawn the daemon poller; return state dict."""
    req = urllib.request.Request(
        DEVICECODE_URL,
        data=urllib.parse.urlencode({"client_id": client_id, "scope": SCOPES}).encode(),
        method="POST")
    r = urllib.request.urlopen(req, timeout=NET_TIMEOUT)
    d = json.loads(r.read())
    deadline = time.time() + d.get("expires_in", 900)
    interval = max(1, int(d.get("interval", 5)))

    def poller():
        # Daemon thread: HTTP + file writes ONLY. Never touches stdin/stdout —
        # the main thread exclusively owns those.
        while time.time() < deadline:
            time.sleep(interval)
            try:
                tr = urllib.request.urlopen(urllib.request.Request(
                    AUTH_URL,
                    data=urllib.parse.urlencode({
                        "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                        "device_code": d["device_code"],
                        "client_id": client_id,
                    }).encode()), timeout=NET_TIMEOUT)
                tok = json.loads(tr.read())
                tok["client_id"] = client_id
                tok["access_token_expires"] = time.time() + tok.get("expires_in", 3600)
                # Atomic 0600 write under the token lock: a concurrent
                # refresh/reader cannot clobber or observe a partial file.
                with _TokenLock():
                    _save(tok)
                log(f"onedrive_mcp: device login complete, token saved to {TOKEN_PATH}")
                with _LOGIN_LOCK:
                    _login_state["pending"] = False
                return
            except urllib.error.HTTPError as e:
                try:
                    err = json.loads(e.read() or b"{}")
                except Exception:  # noqa: BLE001
                    err = {}
                code = err.get("error", "")
                if code in ("slow_down", "authorization_pending"):
                    continue  # keep polling at the same interval
                log(f"onedrive_mcp: device login failed: {json.dumps(err)}")
                break
            except urllib.error.URLError as e:
                log(f"onedrive_mcp: device login poll network error: {e.reason}; retrying")
                continue
        # Expiry, failure, or timeout: reset state so the next call offers a
        # FRESH code (single state machine, no zombie "pending" forever).
        with _LOGIN_LOCK:
            _login_state["pending"] = False
        log("onedrive_mcp: device login ended without a token; state reset")

    th = threading.Thread(target=poller, daemon=True, name="onedrive-device-login")
    th.start()
    return {
        "pending": True,
        "verification_uri": d["verification_uri"],
        "user_code": d["user_code"],
        "started_at": time.time(),
        "thread": th,
    }


def ensure_login():
    """Return a status message when no usable token exists, else None.

    None  -> a valid token is available (or a silent refresh succeeded).
    str   -> human-readable status for the caller: either the fresh
             device-code prompt (first call) or the "login in progress"
             notice (subsequent calls while the daemon poller runs).

    Any token-unavailable condition (missing token file, or a failed silent
    refresh e.g. a revoked/rotated refresh token) self-heals via the
    device-code login: the next call after the user enters the code simply
    works. Only a missing ONEDRIVE_CLIENT_ID is a hard setup error.
    """
    try:
        access_token()  # fast path: valid token, or silent refresh succeeds
        return None
    except Exception as e:  # noqa: BLE001
        tok_err = e

    if not CLIENT_ID:
        return ["ERROR: OneDrive not set up — no token at "
                f"{TOKEN_PATH} and ONEDRIVE_CLIENT_ID is not set "
                f"(token error: {tok_err!r}). "
                "Add ONEDRIVE_CLIENT_ID=<app-client-id> to the agent's .env "
                "(agenix hermes-karl.age secret), then re-run this tool."]

    with _LOGIN_LOCK:
        st = _login_state
        if st["pending"]:
            # A login is already in flight: report THAT one (single state
            # machine — never start a second device-code flow).
            return [_login_message(st)]
        try:
            st.update(_start_device_login(CLIENT_ID))
        except Exception as e:  # noqa: BLE001
            st["pending"] = False
            return [f"ERROR: could not start OneDrive device login: {e!r}"]
        log(f"onedrive_mcp: device login started (code {st['user_code']}); "
            f"daemon poller running until expiry")
        return [_login_message(st)]


# ---------- graph ----------
def _encode_query(query):
    """Pass the query string through exactly as the caller built it.

    Callers percent-encode query values exactly once with
    urllib.parse.quote(raw_value, safe=""). Graph accepts a literal '$'
    as the OData parameter delimiter. Re-encoding here (the draft's
    quote(query, safe="=&")) double-encoded already-encoded values —
    $search=%27q%27 arrived at Graph as the literal string "%27q%27"
    and failed with "Syntax error: character '%' is not valid at position 0".
    """
    return query


def api(method, path, body=None, raw=False, raw_body=None,
        content_type="application/json", attempts=3):
    """Graph request. body: JSON-able dict/str; raw_body: bytes verbatim.

    raw=True returns the response as bytes (e.g. /content), else JSON.
    Transient 401/429 and network errors are retried (Graph routing flakes);
    deterministic 4xx (400, 404 itemNotFound, 403) are never retried.
    """
    from urllib.parse import urlsplit, urlunsplit
    parts = urlsplit(path)
    path = urlunsplit((parts.scheme, parts.netloc, parts.path,
                       _encode_query(parts.query), ""))
    data = raw_body if raw_body is not None else (
        json.dumps(body).encode() if body is not None else None)
    last_status, last_err = 0, None
    for attempt in range(1, attempts + 1):
        req = urllib.request.Request(GRAPH + path, data=data, method=method,
                                     headers={"Authorization": f"Bearer {access_token()}",
                                              "Content-Type": content_type})
        try:
            r = urllib.request.urlopen(req, timeout=NET_TIMEOUT)
            out = r.read()
            return r.status, (out if raw else (json.loads(out) if out else None))
        except urllib.error.HTTPError as e:
            out = e.read()
            try:
                last_status, last_err = e.code, json.loads(out or b"null")
            except json.JSONDecodeError:
                last_status, last_err = e.code, out.decode(errors="replace")
            if e.code in (401, 429) and attempt < attempts:
                try:
                    time.sleep(float(e.headers.get("Retry-After", 0)) or 1.0 * attempt)
                except ValueError:
                    time.sleep(1.0 * attempt)
                continue
            return last_status, last_err
        except urllib.error.URLError as e:
            last_status, last_err = 0, {"error": {"code": "network", "message": str(e.reason)}}
            if attempt < attempts:
                time.sleep(1.0 * attempt)
                continue
    return last_status, last_err


def child_form(item):
    """children/ form of an item path (item form is rejected on content/mutation calls).

    /a/b/x            -> /a/b/children/x
    /a/b/children/x   -> unchanged (already in children/ form)

    The by-name children/ form is the documented Graph idiom and is the ONLY
    form that works on this drive for PUT/DELETE /content (ground-truthed via
    the proven onedrive_api.py CLI, 2026-09-17): item form 400s with a
    generic invalidRequest, the children/ form returns 201/204.
    """
    item = item.rstrip("/")
    segs = item.split("/")
    if len(segs) >= 2 and segs[-2] == "children":
        return item
    return "/".join(segs[:-1]) + "/children/" + segs[-1]


def _err(res, extra_hint=None):
    msg = res if isinstance(res, str) else json.dumps(res, indent=2)
    hint = ""
    if isinstance(res, dict):
        err = res.get("error", {})
        if isinstance(err, dict) and err.get("code") == "itemNotFound":
            hint = (" (Microsoft rejected this at the API level — the token "
                    "can only write to the app folder)")
        inner = err.get("innerError") if isinstance(err, dict) else None
        if isinstance(inner, dict) and inner.get("request-id"):
            hint += f" [request-id: {inner['request-id']}]"
    if extra_hint:
        hint += f" ({extra_hint})"
    return [f"ERROR: {msg}{hint}"]


# ---------- tool implementations (return a list of text blocks) ----------
def t_status(args):
    msg = ensure_login()
    if msg is not None:
        return msg if isinstance(msg, list) else [msg[0]]
    return [f"ok — access token valid for ~{_ttl()}s; token file {TOKEN_PATH}"]


def t_list(args):
    pre = ensure_login()
    if pre is not None:
        return pre if isinstance(pre, list) else [pre[0]]
    path = args.get("path", "/me/drive/special/approot").rstrip("/")
    status, res = api("GET", f"{path}/children?$top=200")
    if status >= 300:
        return _err(res)
    items = res.get("value", [])
    if not items:
        return [f"(empty) {path}"]
    lines = [f"{it.get('folder') and '📁' or '📄'} {it['name']:<40} {it.get('size', ''):>10}  {it.get('webUrl', '')}" for it in items]
    return [f"{len(items)} item(s) under {path}:\n" + "\n".join(lines)]


def _read_content(item):
    """GET file content: /content first; on failure, metadata downloadUrl.

    /content is a raw-bytes endpoint (never parsed as JSON here — bug #3).
    For approot items it 401s (SharePoint routing), so fall back to
    GET <children/-form item> metadata and fetch
    @microsoft.graph.downloadUrl.
    """
    status, out = api("GET", f"{item}/content", raw=True)
    if 200 <= status < 300:
        return status, out
    st2, meta = api("GET", child_form(item))
    if st2 == 200 and isinstance(meta, dict) and meta.get("@microsoft.graph.downloadUrl"):
        try:
            r = urllib.request.urlopen(meta["@microsoft.graph.downloadUrl"],
                                       timeout=NET_TIMEOUT)
            return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()
        except urllib.error.URLError as e:
            return 0, {"error": {"code": "network", "message": str(e.reason)}}
    return status, out


def t_read(args):
    pre = ensure_login()
    if pre is not None:
        return pre if isinstance(pre, list) else [pre[0]]
    item = args.get("path", "").rstrip("/")
    if not item:
        return _err({"error": "path is required"})
    status, out = _read_content(item)
    if status >= 300:
        return _err(out if isinstance(out, (dict, str)) else
                    {"error": f"read failed with HTTP {status}"})
    text = out.decode("utf-8", errors="replace")
    # ':::' header separator (own line): content may itself contain newlines.
    return [f"{item} :: {len(out)} bytes\n:::\n{text}"]


def t_write(args):
    pre = ensure_login()
    if pre is not None:
        return pre if isinstance(pre, list) else [pre[0]]
    item = args.get("path", "").rstrip("/")
    if not item:
        return _err({"error": "path is required"})
    if args.get("content_base64"):
        data = base64.b64decode(args["content_base64"])
    else:
        data = args.get("content", "").encode("utf-8")
    # Raw bytes to /content: the endpoint stores the body verbatim, so the
    # read-back is byte-exact (ground-truthed 2026-09-17: the
    # {"@content.bytes"} envelope is instead stored VERBATIM as the file
    # content on this drive — wrong for text round-trips). Content-Type is
    # application/json for EVERY write: one Graph backend rejects non-JSON
    # Content-Types with 400 "Entity only allows writes with a JSON
    # Content-Type header" (header check only; the body bytes are stored
    # as-is regardless — probe C 2026-09-17: 201 + exact read-back).
    status, res = api("PUT", f"{child_form(item)}/content",
                      raw_body=data, content_type="application/json")
    if status >= 300:
        return _err(res)
    size = res.get("size") if isinstance(res, dict) else ""
    url = res.get("webUrl") if isinstance(res, dict) else ""
    return [f"wrote {item} (status={status}, size={size}, {url})"]


def t_search(args):
    pre = ensure_login()
    if pre is not None:
        return pre if isinstance(pre, list) else [pre[0]]
    q = (args.get("query") or "").lower()
    if not q:
        return _err({"error": "query is required"})
    scope = args.get("scope", "/me/drive/special/approot").rstrip("/")
    # $search is a no-op on this drive (verified: returns children unfiltered),
    # so filter the listed children client-side.
    status, res = api("GET", f"{scope}/children?$top=200")
    if status >= 300:
        return _err(res)
    items = [it for it in res.get("value", []) if q in it.get("name", "").lower()]
    if not items:
        return [f"no matches for {q!r} (direct children of {scope})"]
    lines = [f"{it.get('folder') and '📁' or '📄'} {it['name']}  {it.get('webUrl', '')}" for it in items]
    return [f"{len(items)} match(es) for {q!r} (direct children of {scope}):\n" + "\n".join(lines)]


def t_delete(args):
    pre = ensure_login()
    if pre is not None:
        return pre if isinstance(pre, list) else [pre[0]]
    item = args.get("path", "").rstrip("/")
    if not item:
        return _err({"error": "path is required"})
    status, res = api("DELETE", child_form(item))
    if status >= 300:
        return _err(res)
    return [f"deleted {item} (status={status})"]


TOOL_DEFS = {
    "onedrive_status": {
        "description": "Check token health and time-to-expiry. If no valid token exists, starts the device-code login and returns the verification URL + code.",
        "inputSchema": {"type": "object", "properties": {}},
        "impl": t_status,
    },
    "onedrive_list": {
        "description": "List items in a folder (default: the app folder). Args: path (e.g. /me/drive/root).",
        "inputSchema": {
            "type": "object",
            "properties": {"path": {"type": "string", "description": "Drive path, e.g. /me/drive/root"}},
        },
        "impl": t_list,
    },
    "onedrive_read": {
        "description": "Read a file's content (text). Args: path (full item path).",
        "inputSchema": {
            "type": "object",
            "properties": {"path": {"type": "string", "description": "Item path, e.g. /me/drive/special/approot/note.txt"}},
            "required": ["path"],
        },
        "impl": t_read,
    },
    "onedrive_write": {
        "description": "Write a file (text or base64). API-confined to the app folder by Microsoft. Args: path, content OR content_base64.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string", "description": "Target item path"},
                "content": {"type": "string", "description": "Text content"},
                "content_base64": {"type": "string", "description": "Base64 content (binary)"},
            },
            "required": ["path"],
        },
        "impl": t_write,
    },
    "onedrive_search": {
        "description": "Search the drive by name (client-side filter on listed children; "
                       "$search is a no-op on this drive). Args: query, optional scope folder "
                       "(default: the app folder).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {"type": "string"},
                "scope": {"type": "string", "description": "Folder to search, default the app folder"},
            },
            "required": ["query"],
        },
        "impl": t_search,
    },
    "onedrive_delete": {
        "description": "Delete an item. Args: path.",
        "inputSchema": {
            "type": "object",
            "properties": {"path": {"type": "string"}},
            "required": ["path"],
        },
        "impl": t_delete,
    },
}


# ---------- MCP / JSON-RPC ----------
def log(*a):
    print(*a, file=sys.stderr, flush=True)


def tool_result(name, blocks, ok=True):
    return {"content": [{"type": "text", "text": b} for b in blocks], "isError": not ok}


def handle(msg):
    mid, mtype, method, params = msg.get("id"), msg.get("type"), msg.get("method"), msg.get("params", {})
    is_notification = mid is None

    if method == "initialize":
        return {
            "protocolVersion": PROTOCOL_VERSION,
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            "capabilities": {"tools": {}},
            "instructions": "Read/search the whole OneDrive; writes are confined to the app folder by Microsoft. If no token exists, any tool starts the device-code login and returns the URL + code.",
        }

    if method == "notifications/initialized":
        return None
    if method == "ping":
        return {}

    if method == "tools/list":
        return {"tools": [
            {"name": n, "description": d["description"], "inputSchema": d["inputSchema"]}
            for n, d in TOOL_DEFS.items()
        ]}

    if method == "tools/call":
        name = params.get("name")
        if name not in TOOL_DEFS:
            if is_notification:
                return None
            return None  # caller checks isError
        try:
            blocks = TOOL_DEFS[name]["impl"](params.get("arguments", {}) or {})
            ok = not (blocks and blocks[0].startswith("ERROR:"))
            if is_notification:
                return None
            return tool_result(name, blocks, ok)
        except Exception as e:  # noqa: BLE001
            return tool_result(name, [f"ERROR: {e!r}"], ok=False)

    # Unknown method
    if is_notification:
        return None
    return {"error": {"code": -32601, "message": f"Method not found: {method}"}}


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            continue
        msgs = msg if isinstance(msg, list) else [msg]
        out = []
        for m in msgs:
            if not isinstance(m, dict) or "method" not in m:
                continue
            try:
                result = handle(m)
            except Exception as e:  # noqa: BLE001
                result = {"error": {"code": -32603, "message": f"Internal error: {e!r}"}}
            if m.get("id") is not None:
                out.append({"jsonrpc": "2.0", "id": m["id"], "result": result})
            elif result is not None:
                out.append({"jsonrpc": "2.0", "result": result})
        if out:
            sys.stdout.write(json.dumps(out[0] if len(out) == 1 else out) + "\n")
            sys.stdout.flush()
    log("onedrive_mcp: stdin closed, exiting")


if __name__ == "__main__":
    main()
