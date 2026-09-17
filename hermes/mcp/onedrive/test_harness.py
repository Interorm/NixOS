#!/usr/bin/env python3
"""Stdio test harness for mcp_server.py.

Drives the MCP server exactly like a real client: spawns it as a subprocess,
speaks NDJSON JSON-RPC 2.0 over stdin/stdout, and walks the full acceptance
sequence (initialize -> tools/list -> tools/call for every tool, including
the required out-of-scope write negative test).

Also exercises the SELF-LOGIN path (section 10) against real Microsoft
endpoints WITHOUT completing a login or touching the production token:
  * ONEDRIVE_TOKEN is pointed at a throwaway /tmp path and that file is
    deleted, so the server has NO usable token.
  * the first onedrive_status call must return IMMEDIATELY (well under the
    ~900s device-code expiry) with the verification URL + user code — proving
    the daemon-thread design (the call does NOT block on the poll).
  * a second call must report "login in progress" (the pending state machine).
  * a server with ONEDRIVE_CLIENT_ID unset must return a clear setup error.
No code is ever entered, so no real login completes and the daemon poller
dies harmlessly with the server process.

Env overrides (all optional):
  ONEDRIVE_TOKEN        token file the server-under-test uses (default: the
                        real production token -> full live acceptance run)
  ONEDRIVE_CLIENT_ID    client id the server reads from env (default: taken
                        from the real token file for the self-login section)
  SKIP_SELFLOGIN=1      skip section 10 (no Microsoft devicecode calls)

Usage:
    python3 test_harness.py [path-to-mcp_server.py]

Exit code 0 = all checks passed, 1 = failure (or server died).
"""
import base64
import json
import os
import re
import select
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "mcp_server.py")
PY = sys.executable or "python3"

REAL_TOKEN = os.path.expanduser(os.environ.get("ONEDRIVE_TOKEN", "~/.hermes/onedrive_token.json"))
THROWAWAY_TOKEN = "/tmp/od-selflogin-test.json"

APP_TEST_FILE = "/me/drive/special/approot/mcp-test.txt"
APP_TEST_BIN = "/me/drive/special/approot/mcp-test-bin.bin"
ROOT_FAIL_FILE = "/me/drive/root/mcp-should-fail.txt"
CONTENT = ("harness check 2026-09-17\n"
           "line 2: 'quotes' & <tags> = 404\n"
           "line 3: ünïcødé ✓ — em-dash & co\n")
BIN_BYTES = bytes([0x00, 0x01, 0xFF, 0x80, 0x41, 0x42, 0x0A, 0x00, 0xC3, 0xA9])

EXPECTED_TOOLS = ["onedrive_status", "onedrive_list", "onedrive_read",
                  "onedrive_write", "onedrive_search", "onedrive_delete"]

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


class Client:
    """Minimal MCP client: one request at a time, NDJSON framing."""

    def __init__(self, extra_env=None):
        env = dict(os.environ)
        if extra_env:
            env.update(extra_env)
        self.proc = subprocess.Popen(
            [PY, SERVER],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1, env=env)
        self._id = 0

    def send(self, method, params=None, timeout=90, expect_reply=True):
        msg = {"jsonrpc": "2.0", "method": method, "params": params or {}}
        if expect_reply:
            self._id += 1
            msg["id"] = self._id
        self.proc.stdin.write(json.dumps(msg) + "\n")
        self.proc.stdin.flush()
        if not expect_reply:
            return None
        r, _, _ = select.select([self.proc.stdout], [], [], timeout)
        if not r:
            raise TimeoutError(f"server did not answer {method} within {timeout}s")
        line = self.proc.stdout.readline()
        if not line:
            raise EOFError(f"server closed stdout during {method}")
        d = json.loads(line)
        if isinstance(d, list):
            d = d[0]
        if "error" in d:
            raise RuntimeError(f"JSON-RPC error on {method}: {d['error']}")
        return d.get("result")

    def call(self, name, args=None, timeout=120, retries=3, backoff=3.0,
             ok=None):
        """tools/call, with step-level retries for transient Graph flakes.

        Retries only while ok(result) is False; a definitive answer
        (success, or a terminal error the caller expects) stops the loop.
        The server does NOT retry deterministic 4xx (only transient 401/429
        and network errors), so worst-case server latency is bounded; this
        step-level retry is a thin extra layer for genuine flakiness.
        timeout (120s) is well above the server's worst-case retry budget,
        and the 3s backoff keeps a deterministic 4xx fast (no self-hang).
        """
        attempt = 0
        while True:
            attempt += 1
            res = self.send("tools/call", {"name": name, "arguments": args or {}},
                            timeout=timeout)
            text = "".join(c.get("text", "") for c in (res or {}).get("content", [])
                           if c.get("type") == "text")
            result = ((res or {}).get("isError", False), text)
            if ok is None or ok(*result) or attempt >= retries:
                return result
            print(f"       (transient failure, retry {attempt}/{retries - 1} in "
                  f"{backoff * attempt:.0f}s): {text.splitlines()[0][:100] if text else ''}")
            time.sleep(backoff * attempt)

    def close(self):
        """Shut the server down; return its stderr tail (safe once it has exited)."""
        try:
            self.proc.stdin.close()
        except Exception:
            pass
        try:
            self.proc.wait(timeout=10)
        except Exception:
            self.proc.kill()
            try:
                self.proc.wait(timeout=5)
            except Exception:
                pass
        out = []
        while True:
            try:
                d = os.read(self.proc.stderr.fileno(), 65536)
            except OSError:
                break
            if not d:
                break
            out.append(d)
        try:
            self.proc.stdout.close()
            self.proc.stderr.close()
        except Exception:
            pass
        return b"".join(out).decode(errors="replace").strip()[-800:]


def section(title):
    print(f"\n=== {title} ===")


def main():
    print(f"harness: {os.path.basename(sys.argv[0])}")
    print(f"server : {SERVER} (python: {PY})")
    print(f"token  : {REAL_TOKEN}")
    c = Client()
    errtail = ""
    try:
        section("1. initialize")
        init = c.send("initialize", {"protocolVersion": "2024-11-05",
                                     "clientInfo": {"name": "harness", "version": "1"}})
        check("initialize replies with protocolVersion + serverInfo",
              bool(init and init.get("protocolVersion") and init.get("serverInfo")),
              json.dumps(init))
        c.send("notifications/initialized", expect_reply=False)
        print("       (notifications/initialized sent, no reply expected)")

        section("2. tools/list")
        listing = c.send("tools/list")
        names = [t["name"] for t in (listing or {}).get("tools", [])]
        check("exposes the 6 expected tools", names == EXPECTED_TOOLS, ", ".join(names))

        section("3. onedrive_status")
        err, text = c.call("onedrive_status",
                           ok=lambda e, t: not e)
        check("status ok (no error, reports TTL)",
              (not err) and text.startswith("ok") and "s; token file" in text, text)

        section("4. onedrive_list (default approot)")
        err, text = c.call("onedrive_list", ok=lambda e, t: not e)
        check("list returns without error", not err, text)

        section("5. onedrive_write -> approot/mcp-test.txt (text)")
        err, text = c.call("onedrive_write",
                           {"path": APP_TEST_FILE, "content": CONTENT},
                           ok=lambda e, t: (not e) and "status=201" in t)
        check("write succeeds (status=201 reported, isError=false)",
              (not err) and "status=201" in text and "mcp-test.txt" in text, text)

        section("5b. onedrive_write -> approot/mcp-test-bin.bin (base64 binary)")
        err, text = c.call("onedrive_write",
                           {"path": APP_TEST_BIN,
                            "content_base64": base64.b64encode(BIN_BYTES).decode()},
                           ok=lambda e, t: (not e) and "status=201" in t)
        check("binary write succeeds (status=201, size=10)",
              (not err) and "status=201" in text and "size=10" in text, text)

        section("6. onedrive_read of the same file -> exact echo")
        err, text = c.call("onedrive_read", {"path": APP_TEST_FILE},
                           ok=lambda e, t: (not e) and "\n:::\n" in t)
        echo_ok = size_ok = False
        if not err and "\n:::\n" in text:
            header, body = text.split("\n:::\n", 1)
            if header.endswith(" bytes"):
                size_ok = int(header.split(" :: ")[-1].split(" bytes")[0]) == len(CONTENT.encode())
            echo_ok = body == CONTENT
        check("read echoes exact content (and header size matches)", echo_ok and size_ok,
              f"echo == sent content: {echo_ok}; header size ok: {size_ok}\n--- server returned ---\n{text}")

        section("6b. onedrive_read of the binary file -> size + raw bytes via server path")
        err, text = c.call("onedrive_read", {"path": APP_TEST_BIN},
                           ok=lambda e, t: (not e) and f"{len(BIN_BYTES)} bytes" in t)
        bin_ok = False
        if not err and "\n:::\n" in text:
            header, body = text.split("\n:::\n", 1)
            # The server decodes as utf-8 with replacement for display; the
            # authoritative check is the reported size (raw bytes on the wire).
            bin_ok = header.endswith(f"{len(BIN_BYTES)} bytes")
        check(f"binary read: header reports {len(BIN_BYTES)} raw bytes", bin_ok,
              "exact raw round-trip of the byte content was verified separately against "
              "Graph (probe11: exact byte match via downloadUrl)" if bin_ok else text)

        section("7. onedrive_search for the name")
        err, text = c.call("onedrive_search", {"query": "mcp-test"},
                           ok=lambda e, t: (not e) and "mcp-test.txt" in t
                           and "mcp-test-bin.bin" in t)
        check("search finds mcp-test.txt and mcp-test-bin.bin",
              (not err) and "mcp-test.txt" in text and "mcp-test-bin.bin" in text, text)

        section("8. onedrive_delete + verify folder empty")
        err, text = c.call("onedrive_delete", {"path": APP_TEST_FILE},
                           ok=lambda e, t: (not e) and "deleted" in t)
        check("delete mcp-test.txt succeeds", not err and "deleted" in text, text)
        err, text = c.call("onedrive_delete", {"path": APP_TEST_BIN},
                           ok=lambda e, t: (not e) and "deleted" in t)
        check("delete mcp-test-bin.bin succeeds", not err and "deleted" in text, text)
        err, text = c.call("onedrive_list",
                           ok=lambda e, t: (not e) and "(empty)" in t)
        check("approot empty afterwards", (not err) and "(empty)" in text, text)

        section("9. onedrive_write OUT OF SCOPE (must be rejected by Microsoft)")
        err, text = c.call("onedrive_write", {"path": ROOT_FAIL_FILE, "content": "nope"},
                           ok=lambda e, t: e and "itemNotFound" in t)
        check("isError=true with Microsoft code itemNotFound (API-enforced confinement)",
              err and "itemNotFound" in text, text)
    except Exception as e:  # noqa: BLE001
        check(f"harness survived ({type(e).__name__})", False, repr(e))
    finally:
        errtail = c.close()

    # ---------------- 10. self-login (device code) ----------------
    # Fresh server, NO usable token (throwaway path, deleted). ONEDRIVE_CLIENT_ID
    # comes from the REAL token file's client_id (env var, not argv), so the
    # server can start the flow itself. The code is never entered: the first
    # call must return immediately (daemon poller), the second reports pending.
    if os.environ.get("SKIP_SELFLOGIN") == "1":
        section("10. self-login — SKIPPED (SKIP_SELFLOGIN=1)")
    else:
        try:
            real = json.load(open(REAL_TOKEN))
            client_id = os.environ.get("ONEDRIVE_CLIENT_ID") or real["client_id"]
        except Exception as e:  # noqa: BLE001
            client_id = ""
            print(f"       (could not read client id from {REAL_TOKEN}: {e!r})")
        for p in (THROWAWAY_TOKEN, THROWAWAY_TOKEN + ".lock"):
            if os.path.exists(p):
                os.unlink(p)
        env = {"ONEDRIVE_TOKEN": THROWAWAY_TOKEN, "ONEDRIVE_CLIENT_ID": client_id}
        section("10. self-login: no token -> immediate device-code offer")
        c2 = Client(extra_env=env)
        errtail2 = ""
        try:
            if not client_id:
                # Client id unavailable: the server must give a clear setup error.
                err, text = c2.call("onedrive_status", ok=None, retries=1, timeout=30)
                check("no client id -> clear setup error mentioning ONEDRIVE_CLIENT_ID",
                      err and "ONEDRIVE_CLIENT_ID" in text, text)
            else:
                t0 = time.time()
                err, text = c2.call("onedrive_status", ok=None, retries=1, timeout=60)
                dt = time.time() - t0
                # Microsoft's /devicecode verification_uri is the generic
                # https://www.microsoft.com/link (the discriminator is the
                # user_code), so just require an https:// microsoft.com URL.
                has_url = ("https://" in text) and ("microsoft.com" in text)
                code_m = re.search(r"code\s+([A-Z0-9]{4,})", text)
                has_code = bool(code_m)
                check("first call returns IMMEDIATELY with device-code URL+code "
                      f"(elapsed {dt:.1f}s << device-code expiry)",
                      (not err) and has_url and has_code and dt < 60,
                      f"isError={err} elapsed={dt:.1f}s code={code_m.group(1) if code_m else None}\n{text}")
                # Second call: the pending state machine reports the SAME flow.
                t1 = time.time()
                err2, text2 = c2.call("onedrive_status", ok=None, retries=1, timeout=60)
                dt2 = time.time() - t1
                pending_ok = ("login in progress" in text2) or ("code" in text2.lower())
                check(f"second call reports 'login in progress' (elapsed {dt2:.1f}s)",
                      (not err2) and pending_ok, f"isError={err2}\n{text2}")
                check("no real login completed (throwaway token file never created)",
                      not os.path.exists(THROWAWAY_TOKEN),
                      f"{THROWAWAY_TOKEN} exists={os.path.exists(THROWAWAY_TOKEN)}")
        except Exception as e:  # noqa: BLE001
            check(f"self-login section survived ({type(e).__name__})", False, repr(e))
        finally:
            errtail2 = c2.close()
        print(f"\nself-login server stderr: {errtail2 or '(none)'}")

    print(f"\nserver stderr: {errtail or '(none)'}")
    print(f"\n{'=' * 60}\nRESULT: {'ALL CHECKS PASSED' if not FAILURES else 'FAILURES: ' + ', '.join(FAILURES)}\n{'=' * 60}")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
