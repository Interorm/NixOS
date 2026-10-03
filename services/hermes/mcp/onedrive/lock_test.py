#!/usr/bin/env python3
"""Concurrency test for the OneDrive token-refresh fcntl.flock guard.

Fires TWO refreshers at once (two subprocesses, launched back-to-back) against
a LOCAL fake Microsoft token endpoint that rotates the refresh token and
rejects a stale one. The fake endpoint sleeps 0.6s per POST so the two
refreshers are guaranteed to overlap in the critical section. Proves the
guard (the deliverable) yields:
  * no unauthenticated / no failed refresh (both children ok), and
  * no lost rotation (exactly ONE rotation served; final file == endpoint's
    current valid token; the second child piggybacks on the winner).

A CONTROL arm re-runs the SAME scenario with the guard disabled
(mode=nolock, the old unguarded read-modify-write) to prove the test is
sensitive to the bug: at least one child then gets a stale-refresh rejection.

No real Microsoft calls. Uses an isolated tmp HOME (token + lock files), so
the production token file is never touched. Self-locating: the tested modules
(api_cli.py / mcp_server.py) live next to this file; pass a dir as argv[1] to
override.

Usage:
    python3 lock_test.py [module-dir]
Exit 0 = all checks passed, 1 = failure.
"""
import http.server
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
BIN = sys.argv[1] if len(sys.argv) > 1 else HERE
CHILD = os.path.join(HERE, "lock_child.py")
PY = sys.executable or "python3"

FAILURES = []


def check(label, ok, detail=""):
    mark = "PASS" if ok else "FAIL"
    print(f"[{mark}] {label}")
    if detail:
        for ln in str(detail).splitlines():
            print(f"       {ln}")
    if not ok:
        FAILURES.append(label)
    return ok


# ---------- fake Microsoft token endpoint ----------
class FakeMS:
    def __init__(self):
        self.lock = threading.Lock()
        self.valid_refresh = "R0"
        self.access = "A0"
        self.rotations = 0
        self.stale_rejects = 0
        self.requests = 0

    def handle(self, body):
        q = urllib.parse.parse_qs(body)
        rt = q.get("refresh_token", [""])[0]
        with self.lock:
            self.requests += 1
            # Widen the race window so simultaneous refreshers overlap.
            time.sleep(0.6)
            if rt == self.valid_refresh:
                self.rotations += 1
                self.valid_refresh = f"R{self.rotations}"
                self.access = f"A{self.rotations}"
                return 200, {"access_token": self.access,
                             "refresh_token": self.valid_refresh,
                             "expires_in": 3600}
            self.stale_rejects += 1
            return 400, {"error": "invalid_grant",
                        "error_description": "stale (rotated) refresh token"}

    def reset(self):
        with self.lock:
            self.valid_refresh, self.access = "R0", "A0"
            self.rotations, self.stale_rejects, self.requests = 0, 0, 0


FAKE = FakeMS()


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(n).decode()
        code, payload = FAKE.handle(body)
        data = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def start_server():
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    port = srv.server_address[1]
    threading.Thread(target=srv.serve_forever, daemon=True).start()
    return srv, f"http://127.0.0.1:{port}/"


def run_arm(module, mode, auth_url):
    """Launch two barrier-free back-to-back refreshers; collect their results."""
    home = tempfile.mkdtemp(prefix="odlock_")
    tok = os.path.join(home, "onedrive_token.json")
    lockp = tok + ".lock"
    # Fresh EXPIRED token so both children must refresh (no fast-path return).
    with open(tok, "w") as f:
        json.dump({"access_token": "A0", "refresh_token": "R0",
                   "client_id": "cid", "access_token_expires": 0}, f)
    os.chmod(tok, 0o600)
    procs = [subprocess.Popen(
        [PY, CHILD, BIN, module, mode, tok, lockp, auth_url],
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, text=True) for _ in range(2)]
    results, errs = [], []
    for p in procs:
        out, err = p.communicate(timeout=60)
        errs.append(err.strip()[-300:])
        line = out.strip().splitlines()[-1] if out.strip() else ""
        try:
            results.append(json.loads(line))
        except Exception:
            results.append({"ok": False, "error": f"no result line; out={out!r}"})
    with open(tok) as f:
        final_tok = json.load(f)
    stat = os.stat(tok)
    shutil.rmtree(home, ignore_errors=True)
    return results, final_tok, stat, errs


def main():
    print("onedrive token-refresh concurrency test (fake Microsoft endpoint)")
    print(f"module dir: {BIN}")
    srv, auth_url = start_server()
    try:
        # ---------------- DELIVERABLE: locked ----------------
        print("\n=== ARM 1: fcntl.flock guard ON (the deliverable) ===")
        for module in ("api_cli", "mcp_server"):
            FAKE.reset()
            t0 = time.time()
            results, final_tok, stat, errs = run_arm(module, "lock", auth_url)
            dt = time.time() - t0
            print(f"  module={module}  both-ok={all(r['ok'] for r in results)}  {dt:.2f}s")
            for i, r in enumerate(results):
                tail = f"  err={r.get('error','')[:80]}" if not r.get("ok") else ""
                print(f"    child{i}: ok={r.get('ok')} token={r.get('token')}{tail}")
            no_fail = all(r["ok"] for r in results)
            single_rot = (FAKE.rotations == 1 and FAKE.stale_rejects == 0)
            no_lost = (final_tok["refresh_token"] == FAKE.valid_refresh
                       and final_tok["access_token"] == FAKE.access)
            fresh = final_tok.get("access_token_expires", 0) > time.time() + 60
            perm_ok = (stat.st_mode & 0o777) == 0o600
            check(f"{module}: no unauthenticated/failed refresh (both children ok)", no_fail,
                  "; ".join(f"child{i}:{r.get('error','ok')}" for i, r in enumerate(results)))
            check(f"{module}: no lost rotation (exactly 1 rotation, 0 stale rejects)", single_rot,
                  f"rotations_served={FAKE.rotations} stale_rejects={FAKE.stale_rejects}")
            check(f"{module}: final file == endpoint's current token (piggyback works)", no_lost,
                  f"file={final_tok['refresh_token']}/{final_tok['access_token']} "
                  f"endpoint={FAKE.valid_refresh}/{FAKE.access}")
            check(f"{module}: final access token is fresh (expires>now+60s)", fresh,
                  f"ttl={int(final_tok.get('access_token_expires',0)-time.time())}s")
            check(f"{module}: token file still 0600", perm_ok, oct(stat.st_mode & 0o777))
            if any(e.strip() for e in errs):
                print(f"    stderr: {[e for e in errs if e.strip()]}")

        # ---------------- CONTROL: guard OFF ----------------
        print("\n=== ARM 2: guard OFF (unguarded read-modify-write) — sensitivity control ===")
        # Same scenario, but the OLD code path. Expect a collision: one child
        # posts the already-rotated refresh token and is rejected (stale).
        coll_detected = False
        for module in ("api_cli", "mcp_server"):
            FAKE.reset()
            results, final_tok, stat, errs = run_arm(module, "nolock", auth_url)
            failed = [i for i, r in enumerate(results) if not r["ok"]]
            print(f"  module={module}  oks={[r.get('ok') for r in results]} "
                  f"stale_rejects={FAKE.stale_rejects} rotations={FAKE.rotations}")
            for i, r in enumerate(results):
                tail = f"  err={r.get('error','')[:90]}" if not r.get("ok") else ""
                print(f"    child{i}: ok={r.get('ok')}{tail}")
            if (FAKE.stale_rejects >= 1) or failed:
                coll_detected = True
        print(f"\n  sensitivity: collision exhibited in unguarded path = {coll_detected}")
        check("control arm exhibited the concurrency bug (stale reject / child fail)",
              coll_detected,
              "if False, the 0.6s window is too narrow to catch the bug — widen it")
    finally:
        srv.shutdown()

    print(f"\n{'=' * 60}\nRESULT: {'ALL CHECKS PASSED' if not FAILURES else 'FAILURES: ' + ', '.join(FAILURES)}\n{'=' * 60}")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
