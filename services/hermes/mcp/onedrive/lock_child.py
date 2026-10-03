#!/usr/bin/env python3
"""Refresher child: force exactly one access_token() refresh.

Driven by the orchestrator (lock_test.py). Speaks against a LOCAL fake
Microsoft token endpoint (passed in) rather than the real one, so the
concurrency test is hermetic and makes zero real Microsoft calls.

argv:
  1  module dir        path of the dir holding api_cli.py / mcp_server.py
  2  module           'api_cli' or 'mcp_server'
  3  mode             'lock'   = call the real (guarded) access_token()
                              'nolock' = reconstruct the OLD unguarded
                                         read-modify-write (control, to prove
                                         the test is sensitive to the bug)
  4  token path       isolated token file (tmp HOME)
  5  lock path        isolated sidecar lock file (tmp HOME)
  6  auth url         fake Microsoft token endpoint

Prints ONE json line to stdout: {"ok":bool, ...} and exits 0 (it always
reports its own outcome; the orchestrator decides pass/fail).
"""
import importlib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

BIN, MODULE, MODE = sys.argv[1], sys.argv[2], sys.argv[3]
TOK, LOCK, AUTH = sys.argv[4], sys.argv[5], sys.argv[6]

sys.path.insert(0, BIN)
m = importlib.import_module(MODULE)
# Point at the isolated (tmp) files; the lazy LOCK_PATH read in _TokenLock
# picks up the module global at call time, so this routes the lock correctly.
m.TOKEN_PATH = TOK
m.LOCK_PATH = LOCK
m.AUTH_URL = AUTH


def _read():
    with open(m.TOKEN_PATH) as f:
        return json.load(f)


def _write(t):
    with open(m.TOKEN_PATH, "w") as f:
        f.write(json.dumps(t, indent=2))
    os.chmod(m.TOKEN_PATH, 0o600)


def _post(body):
    return urllib.request.urlopen(urllib.request.Request(AUTH, data=body), timeout=30)


def unlocked_refresh():
    """The OLD unguarded read-modify-write — kept only as the control arm."""
    t = _read()
    if t.get("access_token_expires", 0) > time.time() + 60:
        return t["access_token"]
    body = urllib.parse.urlencode({
        "grant_type": "refresh_token",
        "refresh_token": t["refresh_token"],
        "client_id": t["client_id"],
    }).encode()
    r = _post(body)
    d = json.loads(r.read())
    t["access_token"] = d["access_token"]
    if "refresh_token" in d:
        t["refresh_token"] = d["refresh_token"]
    t["access_token_expires"] = time.time() + d.get("expires_in", 3600)
    _write(t)
    return t["access_token"]


def main():
    out = {"module": MODULE, "mode": MODE}
    try:
        tok = m.access_token() if MODE == "lock" else unlocked_refresh()
        out["ok"] = True
        out["token"] = tok
    except urllib.error.HTTPError as e:
        out["ok"] = False
        out["http_status"] = e.code
        out["error"] = e.read().decode(errors="replace")
    except Exception as e:  # noqa: BLE001
        out["ok"] = False
        out["error"] = repr(e)
    print(json.dumps(out), flush=True)


if __name__ == "__main__":
    main()
