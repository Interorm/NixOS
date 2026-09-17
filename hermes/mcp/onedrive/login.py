#!/usr/bin/env python3
"""One-time device-code login for a public-client Graph app (no secret).

Client id resolution: ONEDRIVE_CLIENT_ID env var FIRST (populated by the
agent's agenix-encrypted .env), argv position 1 as a fallback for manual use.
If neither is set, a clear setup error is printed.

Token path: ONEDRIVE_TOKEN env var or ~/.hermes/onedrive_token.json by
default; overridable via argv so a second account can log in to its own file
(the lock sidecar derives from the token path, so accounts don't contend).

Usage:
    login.py [CLIENT_ID] [token_path]
    # with ONEDRIVE_CLIENT_ID set in the environment:
    login.py [token_path]
Shows the code for the user to enter at the verification URI, then polls
and writes the token file (0600, under the token-refresh lock).
"""
import fcntl
import json, os, sys, time, urllib.error, urllib.parse, urllib.request

TENANT = "consumers"  # personal accounts; use your tenant id for M365
BASE = f"https://login.microsoftonline.com/{TENANT}/oauth2/v2.0"
SCOPES = "Files.Read Files.ReadWrite.AppFolder offline_access openid profile"
NET_TIMEOUT = 30  # every urlopen gets this; no indefinite hangs on stalled sockets
_LOCK_ATTEMPTS = 3
_LOCK_RETRY_SLEEP = 1.0

# ---- client id: env first, argv fallback ----
CLIENT_ID = os.environ.get("ONEDRIVE_CLIENT_ID", "")
if CLIENT_ID:
    # env supplied the id: argv[1] (if any) is the optional token path
    TOKEN_PATH = os.path.expanduser(sys.argv[1]) if len(sys.argv) > 1 else \
        os.path.expanduser(os.environ.get("ONEDRIVE_TOKEN", "~/.hermes/onedrive_token.json"))
else:
    # legacy/manual form: login.py <CLIENT_ID> [token_path]
    if len(sys.argv) < 2:
        print("ERROR: no client id. Set ONEDRIVE_CLIENT_ID=<app-client-id> in "
              "your .env (agenix hermes-karl.age secret), or pass it as the "
              "first argument: login.py <CLIENT_ID> [token_path]", file=sys.stderr)
        sys.exit(2)
    CLIENT_ID = sys.argv[1]
    TOKEN_PATH = os.path.expanduser(sys.argv[2]) if len(sys.argv) > 2 else \
        os.path.expanduser(os.environ.get("ONEDRIVE_TOKEN", "~/.hermes/onedrive_token.json"))

LOCK_PATH = TOKEN_PATH + ".lock"


def _save_token(t):
    """Atomic-ish 0600 write under the token-refresh lock: a concurrent
    refresher (MCP server / api_cli) cannot clobber or observe a partial file."""
    with open(LOCK_PATH, "a") as lf:
        try:
            fcntl.flock(lf.fileno(), fcntl.LOCK_EX)
        except OSError:
            pass  # best-effort: proceed unlocked rather than hang a one-shot login
        try:
            os.makedirs(os.path.dirname(os.path.abspath(TOKEN_PATH)), exist_ok=True)
            with open(TOKEN_PATH, "w") as f:
                f.write(json.dumps(t, indent=2))
            os.chmod(TOKEN_PATH, 0o600)
        finally:
            try:
                fcntl.flock(lf.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass


r = urllib.request.urlopen(urllib.request.Request(
    BASE + "/devicecode",
    data=urllib.parse.urlencode({"client_id": CLIENT_ID, "scope": SCOPES}).encode()),
    timeout=NET_TIMEOUT)
d = json.loads(r.read())
print(d.get("message", ""))
print(f"Go to: {d['verification_uri']}")
print(f"Enter code: {d['user_code']}")

deadline = time.time() + d["expires_in"]
while time.time() < deadline:
    time.sleep(d.get("interval", 5))
    try:
        r = urllib.request.urlopen(urllib.request.Request(
            BASE + "/token",
            data=urllib.parse.urlencode({
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code",
                "device_code": d["device_code"], "client_id": CLIENT_ID,
            }).encode()), timeout=NET_TIMEOUT)
        tok = json.loads(r.read())
        tok["client_id"] = CLIENT_ID
        tok["access_token_expires"] = time.time() + tok.get("expires_in", 3600)
        _save_token(tok)
        print("OK: token saved to " + TOKEN_PATH)
        sys.exit(0)
    except urllib.error.HTTPError as e:
        err = json.loads(e.read() or b"{}")
        code = err.get("error", "")
        if code == "slow_down":
            continue
        if code == "authorization_pending":
            continue
        print("ERROR:", json.dumps(err)); sys.exit(1)
print("ERROR: device code expired"); sys.exit(2)
