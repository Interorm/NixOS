#!/usr/bin/env python3
"""OneDrive (Microsoft Graph) API helper — stdlib only.
Token: ~/.hermes/onedrive_token.json (0600), self-refreshing. Override the
path with the ONEDRIVE_TOKEN env var to target another account's token (the
lock sidecar derives from TOKEN_PATH, so per-token-path locks never contend
across accounts).

Usage:
  api_cli.py GET /me/drive/special/approot
  api_cli.py PUT /me/drive/special/approot/children/hello.txt/content '{"@content.bytes":"aGVsbG8="}'
  api_cli.py token          # force refresh + print expiry
"""
import fcntl
import json, os, sys, time, urllib.error, urllib.parse, urllib.request

TOKEN_PATH = os.path.expanduser(os.environ.get("ONEDRIVE_TOKEN", "~/.hermes/onedrive_token.json"))
LOCK_PATH = TOKEN_PATH + ".lock"
TENANT = "consumers"  # personal accounts; use your tenant id for M365
AUTH_URL = f"https://login.microsoftonline.com/{TENANT}/oauth2/v2.0/token"
GRAPH = "https://graph.microsoft.com/v1.0"
NET_TIMEOUT = 30  # every urlopen gets this; no indefinite hangs on stalled sockets
_LOCK_ATTEMPTS = 3      # non-blocking acquire tries before giving up
_LOCK_RETRY_SLEEP = 1.0  # seconds between tries (~3 x 1s total budget)


def load():
    with open(TOKEN_PATH) as f:
        return json.load(f)


def save(t):
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
    never deadlocking, and never raising out of access_token(). In that rare
    fall-through the in-lock re-read still lets us piggyback on a sibling's
    fresh token, and a genuinely-lost race surfaces as the usual transient 401
    that the api() caller can retry. The lock is advisory — it only orders the
    read-modify-write of the token file; a process that loses the race simply
    re-reads the winner's token.
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
    t = load()
    if t.get("access_token_expires", 0) > time.time() + 60:
        return t["access_token"]
    with _TokenLock():
        # Re-read under the lock: a sibling may have refreshed while we waited.
        t = load()
        if t.get("access_token_expires", 0) > time.time() + 60:
            return t["access_token"]
        body = urllib.parse.urlencode({
            "grant_type": "refresh_token",
            "refresh_token": t["refresh_token"],
            "client_id": t["client_id"],
        }).encode()
        r = urllib.request.urlopen(urllib.request.Request(AUTH_URL, data=body),
                                   timeout=NET_TIMEOUT)
        data = json.loads(r.read())
        t["access_token"] = data["access_token"]
        if "refresh_token" in data:  # MS may rotate it
            t["refresh_token"] = data["refresh_token"]
        t["access_token_expires"] = time.time() + data.get("expires_in", 3600)
        save(t)
        return t["access_token"]


def api(method, path, body=None, raw=False):
    from urllib.parse import urlsplit, urlunsplit, quote  # %encode $filter etc.
    parts = urlsplit(path)
    path = urlunsplit((parts.scheme, parts.netloc, parts.path,
                       quote(parts.query, safe="=&"), ""))
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(GRAPH + path, data=data, method=method,
                                 headers={"Authorization": f"Bearer {access_token()}",
                                          "Content-Type": "application/json"})
    try:
        r = urllib.request.urlopen(req, timeout=NET_TIMEOUT)
        out = r.read()
        return r.status, (out if raw else (json.loads(out) if out else None))
    except urllib.error.HTTPError as e:
        out = e.read()
        try:
            return e.code, json.loads(out or b"null")
        except json.JSONDecodeError:
            return e.code, out.decode(errors="replace")


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "token":
        tok = access_token()
        print(f"ok, expires in {int(load()['access_token_expires'] - time.time())}s")
        sys.exit(0)
    if len(sys.argv) < 3:
        print(__doc__); sys.exit(2)
    method, path = sys.argv[1], sys.argv[2]
    body = json.loads(sys.argv[3]) if len(sys.argv) > 3 else None
    status, result = api(method, path, body)
    print(json.dumps(result, indent=2) if isinstance(result, (dict, list)) else result)
    sys.exit(0 if status < 300 else 1)
