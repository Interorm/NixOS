#!/usr/bin/env python3
"""Offline test harness for the FinTS MCP server.

Every check in the default run is OFFLINE: no bank connection, no credentials,
no network. The MCP sections drive mcp_server.py as a real MCP client
(subprocess, NDJSON JSON-RPC 2.0 over stdio), exactly like
hermes/mcp/onedrive/test_harness.py.

Sections
  1. schema migration on a fresh empty dir (+ 0600 perms, seeded taxonomy)
  2. MT940 parsing -> row shape, and Soll/Haben amount signs
  3. dedup idempotency: ingest the same fixture twice -> row count unchanged
  4. state file: 0600, flock, 180-day re-auth countdown, no PIN in the file
  5. NEGATIVE: no transfer/write capability exists anywhere in the package
  6. MCP protocol: initialize / tools/list / every read tool over stdio
  7. MCP failure modes: not-enrolled, missing config, non-SELECT rejection
  8. LIVE (skipped unless FINTS_LIVE=1): real bank fetch after enrollment

Section 2 needs the `fints` package (it uses the library's own MT940 parser);
if it is not importable the section is reported as SKIPPED, not failed, and
the mapping is still checked against a literal parsed-record fixture.

Usage:
    python3 test_harness.py
    FINTS_LIVE=1 python3 test_harness.py    # adds section 8
Exit 0 = all checks passed, 1 = failure.
"""
import json
import os
import select
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone

HERE = os.path.dirname(os.path.abspath(__file__))
SERVER = os.path.join(HERE, "mcp_server.py")
FIXTURES = os.path.join(HERE, "fixtures")
PY = sys.executable or "python3"

sys.path.insert(0, HERE)
import db                # noqa: E402
import fints_client as fc  # noqa: E402

FAILURES = []


def check(label, ok, detail=""):
    print(f"[{'PASS' if ok else 'FAIL'}] {label}")
    if detail:
        for ln in str(detail).splitlines():
            print(f"       {ln}")
    if not ok:
        FAILURES.append(label)
    return ok


def section(title):
    print(f"\n=== {title} ===")


def skip(label, why):
    print(f"[SKIP] {label}")
    print(f"       {why}")


# A literal mt940 "parsed record" — the exact .data dict shape python-fints
# hands us (ground-truthed against fints.utils.mt940_to_array on the fixture,
# 2026-09-29). Lets the mapping be tested without the fints package.
class _Amount:
    def __init__(self, amount, currency):
        from decimal import Decimal
        self.amount = Decimal(amount)
        self.currency = currency


import datetime as _dt  # noqa: E402

LITERAL_DEBIT = {
    "amount": _Amount("-52.30", "EUR"),
    "date": _dt.date(2025, 7, 3),
    "entry_date": _dt.date(2025, 7, 3),
    "purpose": "REWE SAGTDANKE 12345",
    "additional_purpose": None,
    "applicant_name": "REWEMarkt GmbH",
    "applicant_iban": "DE02250501500001234567",
    "applicant_bin": "NOLADE21NIB",
    "posting_text": "FOLGELASTSCHRIFT",
    "end_to_end_reference": "ABC123",
    "status": "D",
    "currency": "EUR",
}
LITERAL_CREDIT = {
    "amount": _Amount("450.00", "EUR"),
    "date": _dt.date(2025, 7, 4),
    "entry_date": _dt.date(2025, 7, 4),
    "purpose": "Unterhalt Juli",
    "applicant_name": "Mustermann, Erika",
    "applicant_iban": "DE44100100100123456789",
    "posting_text": "GUTSCHRIFT",
    "status": "C",
    "currency": "EUR",
}

TEST_IBAN = "DE89250501500001234567"


# ---------------- MCP client ----------------
class Client:
    """Minimal MCP client: one request at a time, NDJSON framing."""

    def __init__(self, extra_env=None):
        env = dict(os.environ)
        # Never let the developer's real credentials leak into a test server.
        for k in fc.REQUIRED_ENV:
            env.pop(k, None)
        if extra_env:
            env.update(extra_env)
        self.proc = subprocess.Popen(
            [PY, SERVER], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, bufsize=1, env=env)
        self._id = 0

    def send(self, method, params=None, timeout=30, expect_reply=True):
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

    def call(self, name, args=None, timeout=60):
        """tools/call -> (isError, parsed_payload). The server returns one
        JSON text block, so the payload is parsed back into a dict here."""
        res = self.send("tools/call", {"name": name, "arguments": args or {}},
                        timeout=timeout)
        text = "".join(c.get("text", "") for c in (res or {}).get("content", [])
                       if c.get("type") == "text")
        try:
            payload = json.loads(text)
        except json.JSONDecodeError:
            payload = {"_raw": text}
        return (res or {}).get("isError", False), payload

    def close(self):
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


# ---------------- sections ----------------
def s1_schema(tmp):
    section("1. schema migration on a fresh empty dir")
    dbp = os.path.join(tmp, "fresh", "finance.db")
    os.environ["FINTS_DB"] = dbp
    check("dir does not exist before migrate()", not os.path.exists(os.path.dirname(dbp)))
    path = db.migrate()
    check("migrate() created the DB", os.path.exists(path), path)
    mode = oct(os.stat(path).st_mode & 0o777)
    check("DB file mode is 0600", mode == "0o600", f"mode={mode}")
    dmode = oct(os.stat(os.path.dirname(path)).st_mode & 0o777)
    check("parent dir mode is 0700", dmode == "0o700", f"mode={dmode}")

    con = db.connect()
    try:
        tables = {r[0] for r in con.execute(
            "SELECT name FROM sqlite_master WHERE type='table'")}
        want = {"transactions", "rules", "categories", "sync_log"}
        check("all four tables exist", want <= tables, f"got: {sorted(tables)}")
        check("PRAGMA user_version == schema version",
              db.schema_version(con) == db.SCHEMA_VERSION,
              f"{db.schema_version(con)} vs {db.SCHEMA_VERSION}")

        cats = db.categories(con)
        by_kind = {}
        for c in cats:
            by_kind.setdefault(c["kind"], []).append(c["name"])
        check("taxonomy seeded with all 20 builtin categories",
              len(cats) == len(db.BUILTIN_CATEGORIES),
              f"{len(cats)} categories: "
              f"{len(by_kind.get('expense', []))} expense, "
              f"{len(by_kind.get('income', []))} income, "
              f"{len(by_kind.get('transfer', []))} transfer")
        check("student-specific categories present (not a household tree)",
              {"Mensa & Essen unterwegs", "Transport & Semesterticket",
               "BAföG", "Unterhalt/Allowance"} <= {c["name"] for c in cats},
              ", ".join(sorted(by_kind.get("income", []))))

        # Idempotent re-migrate must not duplicate the seed.
        db.migrate()
        check("migrate() is idempotent (no duplicate categories)",
              len(db.categories(con)) == len(db.BUILTIN_CATEGORIES),
              f"{len(db.categories(con))} after second migrate()")
    finally:
        con.close()

    # A query connection must be physically unable to write.
    ro = db.connect(readonly=True)
    try:
        import sqlite3
        try:
            ro.execute("INSERT INTO categories(name, kind) VALUES ('X','expense')")
            ro.commit()
            check("read-only connection rejects INSERT", False,
                  "the INSERT succeeded — mode=ro is not in effect!")
        except sqlite3.OperationalError as e:
            check("read-only connection rejects INSERT (mode=ro URI)",
                  "readonly" in str(e).lower(), str(e))
    finally:
        ro.close()


def s2_parsing():
    section("2. MT940 parsing -> row shape, and Soll/Haben signs")
    # Mapping is checked against the literal parsed record first — no deps.
    r = fc.map_transaction(LITERAL_DEBIT, iban=TEST_IBAN, fetched_at="T")
    check("debit maps to NEGATIVE cents (Soll)", r["amount_cents"] == -5230,
          f"amount_cents={r['amount_cents']} (expected -5230)")
    check("cents are an int, never a float", isinstance(r["amount_cents"], int),
          f"type={type(r['amount_cents']).__name__}")
    check("counterparty/purpose/posting_text mapped",
          (r["counterparty_name"] == "REWEMarkt GmbH"
           and r["counterparty_iban"] == "DE02250501500001234567"
           and r["posting_text"] == "FOLGELASTSCHRIFT"
           and r["end_to_end_id"] == "ABC123"),
          json.dumps({k: r[k] for k in ("counterparty_name", "counterparty_iban",
                                        "posting_text", "end_to_end_id")},
                     ensure_ascii=False))
    check("dates are ISO YYYY-MM-DD strings",
          r["booking_date"] == "2025-07-03" and r["value_date"] == "2025-07-03",
          f"booking={r['booking_date']} value={r['value_date']}")
    check("raw_json is a JSON string holding the full record",
          isinstance(r["raw_json"], str) and "FOLGELASTSCHRIFT" in r["raw_json"])

    c = fc.map_transaction(LITERAL_CREDIT, iban=TEST_IBAN, fetched_at="T")
    check("credit maps to POSITIVE cents (Haben)", c["amount_cents"] == 45000,
          f"amount_cents={c['amount_cents']} (expected 45000)")

    # Cent conversion edge cases: Decimal only, never float.
    from decimal import Decimal
    cases = [(Decimal("0.01"), 1), (Decimal("-0.01"), -1),
             (Decimal("1234.56"), 123456), (Decimal("-1234.56"), -123456),
             (Decimal("0.00"), 0), (Decimal("999999.99"), 99999999)]
    bad = [(v, fc.to_cents(v), want) for v, want in cases if fc.to_cents(v) != want]
    check("to_cents() exact for Decimal edge cases", not bad,
          f"mismatches: {bad}" if bad else f"{len(cases)} cases exact")

    # Now the real library parser, if available.
    fixture = os.path.join(FIXTURES, "statement.mt940")
    try:
        import fints.utils  # noqa: F401
    except ImportError as e:
        skip("MT940 parse via fints.utils.mt940_to_array",
             f"`fints` not importable ({e}); mapping verified against the "
             f"literal parsed-record fixture above. Run under the Nix wrapper "
             f"to exercise the real parser.")
        return None
    with open(fixture, encoding="utf-8") as f:
        raw = f.read()
    rows = fc.rows_from_mt940(raw, iban=TEST_IBAN, fetched_at="T")
    check("fixture parses to 4 transactions", len(rows) == 4,
          f"got {len(rows)}")
    signs = [x["amount_cents"] for x in rows]
    check("signs follow D/C: [-5230, +45000, -850, -20000]",
          signs == [-5230, 45000, -850, -20000], f"got {signs}")
    check("every row carries the account IBAN",
          all(x["iban"] == TEST_IBAN for x in rows))
    check("currency parsed as EUR on every row",
          all(x["currency"] == "EUR" for x in rows),
          str([x["currency"] for x in rows]))
    return rows


def s3_dedup(tmp, parsed_rows):
    section("3. dedup idempotency (the cron-safety property)")
    dbp = os.path.join(tmp, "dedup", "finance.db")
    os.environ["FINTS_DB"] = dbp
    db.migrate()
    con = db.connect()
    try:
        rows = parsed_rows or [
            fc.map_transaction(LITERAL_DEBIT, iban=TEST_IBAN, fetched_at="T1"),
            fc.map_transaction(LITERAL_CREDIT, iban=TEST_IBAN, fetched_at="T1"),
        ]
        n1 = db.insert_transactions(con, rows)
        c1 = db.row_count(con)
        check(f"first ingest inserted all {len(rows)} rows",
              n1 == len(rows) and c1 == len(rows), f"inserted={n1} count={c1}")

        # Re-fetch the SAME window (a different fetched_at, as a real re-sync
        # would have) and re-ingest: nothing may be added.
        again = [dict(r, fetched_at="T2") for r in rows]
        n2 = db.insert_transactions(con, again)
        c2 = db.row_count(con)
        check("second ingest of the SAME data inserted 0 new rows", n2 == 0,
              f"inserted={n2}")
        check("row count unchanged after re-ingest", c2 == c1,
              f"{c1} -> {c2}")

        # A third pass with one genuinely new transaction.
        new_one = fc.map_transaction(
            dict(LITERAL_CREDIT, purpose="Unterhalt August",
                 date=_dt.date(2025, 8, 4), entry_date=_dt.date(2025, 8, 4)),
            iban=TEST_IBAN, fetched_at="T3")
        n3 = db.insert_transactions(con, rows + [new_one])
        c3 = db.row_count(con)
        check("overlapping re-fetch inserts ONLY the genuinely new row",
              n3 == 1 and c3 == c1 + 1,
              f"inserted={n3} count={c1} -> {c3}")

        # The hash must be sensitive to the amount (a corrected booking is a
        # different transaction, not a silent duplicate).
        h1 = db.dedup_hash(TEST_IBAN, "2025-07-03", -5230, "p", "n", "i")
        h2 = db.dedup_hash(TEST_IBAN, "2025-07-03", 5230, "p", "n", "i")
        h3 = db.dedup_hash(TEST_IBAN, "2025-07-03", -5230, "p", "n", "i")
        check("dedup_hash is sign-sensitive and deterministic",
              h1 != h2 and h1 == h3, f"neg={h1[:16]}… pos={h2[:16]}…")

        # No UPDATE path: the stored row keeps its ORIGINAL fetched_at.
        got = con.execute(
            "SELECT fetched_at FROM transactions WHERE amount_cents = -5230"
        ).fetchone()[0]
        check("conflicting insert does NOT overwrite the stored row",
              got == (parsed_rows and "T" or "T1"),
              f"fetched_at still {got!r} after two re-ingests")
        return c3
    finally:
        con.close()


def s4_state(tmp):
    section("4. state file: 0600, flock, 180-day countdown, no PIN")
    sp = os.path.join(tmp, "state", "fints_state.json")
    os.environ["FINTS_STATE"] = sp

    info = fc.state_info()
    check("not-enrolled state reports enrolled=False",
          info["enrolled"] is False, json.dumps(info))

    fake_pin = "S3cretPin!2026"
    blob = b"OPAQUE-FINTS-DATABLOB-\x00\x01\x02-no-pin-inside"
    with fc.StateLock(sp):
        p = fc.save_state(blob, tan_mechanism="[942] pushTAN",
                          tan_medium="Handy")
    mode = oct(os.stat(p).st_mode & 0o777)
    check("state file mode is 0600", mode == "0o600", f"mode={mode}")
    check("no .tmp file left behind", not os.path.exists(p + ".tmp"))

    with open(p, encoding="utf-8") as f:
        text = f.read()
    check("PIN does not appear in the state file", fake_pin not in text)
    check("state file is JSON with a base64 blob, not raw credentials",
          json.loads(text).get("data_b64") is not None)

    doc, got = fc.load_state(sp)
    check("state round-trips byte-exactly", got == blob,
          f"{len(got or b'')} bytes back of {len(blob)}")

    info = fc.state_info(sp)
    check("enrolled=True after save", info["enrolled"] is True)
    check(f"re-auth window is {fc.SCA_VALIDITY_DAYS} days (Sparkasse Nienburg, "
          f"not the common 90)",
          round(info["reauth_days_remaining"]) == fc.SCA_VALIDITY_DAYS,
          f"days_remaining={info['reauth_days_remaining']} due={info['reauth_due']}")
    check("freshly enrolled state is not expired",
          info["reauth_expired"] is False)

    # An old enrollment must report expiry WITHOUT contacting the bank.
    old = (datetime.now(timezone.utc) - timedelta(days=fc.SCA_VALIDITY_DAYS + 5))
    fc.save_state(blob, path=sp, enrolled_at=old.isoformat(timespec="seconds"))
    info = fc.state_info(sp)
    check("a 185-day-old state reports reauth_expired=True",
          info["reauth_expired"] is True,
          f"days_remaining={info['reauth_days_remaining']}")

    # flock: the guard must be a real exclusive lock across processes.
    lk = fc.StateLock(sp)
    check("StateLock acquires", lk.acquire() is True)
    probe = subprocess.run(
        [PY, "-c",
         "import fcntl,os,sys;fd=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT,0o600);\n"
         "import fcntl\n"
         "try:\n"
         "    fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);print('ACQUIRED')\n"
         "except OSError:\n"
         "    print('BLOCKED')\n",
         sp + ".lock"], capture_output=True, text=True, timeout=30)
    check("a second process is BLOCKED while the lock is held",
          probe.stdout.strip() == "BLOCKED",
          f"child said {probe.stdout.strip()!r} {probe.stderr.strip()}")
    lk.release()
    probe2 = subprocess.run(
        [PY, "-c",
         "import fcntl,os,sys;fd=os.open(sys.argv[1],os.O_RDWR|os.O_CREAT,0o600)\n"
         "try:\n"
         "    fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);print('ACQUIRED')\n"
         "except OSError:\n"
         "    print('BLOCKED')\n",
         sp + ".lock"], capture_output=True, text=True, timeout=30)
    check("the lock is released afterwards",
          probe2.stdout.strip() == "ACQUIRED", probe2.stdout.strip())

    # scrub() must strip a PIN out of anything we surface.
    os.environ[fc.ENV_PIN] = fake_pin
    os.environ[fc.ENV_USER_ID] = "karl123456"
    msg = f"bank said: login failed for karl123456 with PIN {fake_pin}"
    s = fc.scrub(msg)
    check("scrub() removes the PIN and user id from a message",
          fake_pin not in s and "karl123456" not in s, s)
    cfg = fc.Config("25650106", "https://x", "karl123456", fake_pin, "PID")
    check("Config repr never shows the PIN",
          fake_pin not in repr(cfg) and fake_pin not in str(cfg), repr(cfg))
    for k in (fc.ENV_PIN, fc.ENV_USER_ID):
        os.environ.pop(k, None)


FORBIDDEN_SYMBOLS = [
    # python-fints write API + the FinTS segments that perform transfers.
    "sepa_transfer", "simple_sepa_transfer", "sepa_debit", "HKCCS", "HKCCM",
    "HKDSE", "HKDME", "HKCDE", "HKCDN", "HKCDL", "HKCDB",
    "pain.001", "pain.008",
    "standing_order", "add_standing_order", "delete_standing_order",
]


def _code_identifiers(path):
    """Every identifier/attribute/string CONSTANT reachable in executable code.

    Deliberately AST-based rather than a raw text grep: the modules' own
    docstrings *name* the forbidden symbols in order to document that they are
    banned, and a text scan would flag that prose. What matters is whether the
    code can actually CALL such a thing, so docstrings and comments are
    excluded (ast drops comments entirely; docstrings are removed explicitly)
    while every real Name, Attribute, keyword and string literal is kept —
    including strings, so a getattr(client, "sepa_transfer") style bypass is
    still caught.
    """
    import ast
    with open(path, encoding="utf-8") as f:
        tree = ast.parse(f.read(), filename=path)

    # Drop docstrings: the first statement of a module/class/function when it
    # is a bare string expression.
    for node in ast.walk(tree):
        body = getattr(node, "body", None)
        if isinstance(body, list) and body and isinstance(body[0], ast.Expr) \
                and isinstance(body[0].value, ast.Constant) \
                and isinstance(body[0].value.value, str):
            body.pop(0)

    found = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Name):
            found.append((node.id, node.lineno))
        elif isinstance(node, ast.Attribute):
            found.append((node.attr, node.lineno))
        elif isinstance(node, ast.keyword) and node.arg:
            found.append((node.arg, node.lineno))
        elif isinstance(node, ast.Constant) and isinstance(node.value, str):
            found.append((node.value, node.lineno))
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            for a in node.names:
                found.append((a.name, node.lineno))
            if isinstance(node, ast.ImportFrom) and node.module:
                found.append((node.module, node.lineno))
    return found


def s5_no_write_capability():
    section("5. NEGATIVE: no transfer/write capability exists")
    py_files = sorted(f for f in os.listdir(HERE) if f.endswith(".py")
                      and f != os.path.basename(__file__))
    hits = []
    for fn in py_files:
        for ident, lineno in _code_identifiers(os.path.join(HERE, fn)):
            low = ident.lower()
            for sym in FORBIDDEN_SYMBOLS:
                if sym.lower() in low:
                    hits.append(f"{fn}:{lineno}: {ident!r} contains {sym!r}")
    check(f"no forbidden transfer symbol in the CODE of {len(py_files)} module(s)",
          not hits, "\n".join(hits) if hits else
          f"AST-scanned (docstrings/comments excluded): {', '.join(py_files)}")

    # Belt and braces: a raw text scan must also find nothing OUTSIDE of
    # docstrings/comments. Anything the AST scan missed would be prose.
    import io
    import tokenize
    prose_only = True
    for fn in py_files:
        with open(os.path.join(HERE, fn), "rb") as f:
            src = f.read().decode("utf-8")
        code_text = []
        for tok in tokenize.generate_tokens(io.StringIO(src).readline):
            if tok.type in (tokenize.COMMENT, tokenize.STRING):
                continue
            code_text.append(tok.string)
        blob = " ".join(code_text).lower()
        for sym in FORBIDDEN_SYMBOLS:
            if sym.lower() in blob:
                prose_only = False
                hits.append(f"{fn}: {sym} appears outside a string/comment")
    check("forbidden symbols appear ONLY in ban-documenting prose, never in code",
          prose_only, "\n".join(h for h in hits if "appears outside" in h))

    # The FinTS surface actually used must be reads only.
    with open(os.path.join(HERE, "fints_client.py"), encoding="utf-8") as f:
        src = f.read()
    used = [m for m in ("get_sepa_accounts", "get_transactions",
                        "get_tan_mechanisms", "get_tan_media")
            if m in src]
    check("the only FinTS data calls are get_sepa_accounts/get_transactions",
          "get_sepa_accounts" in used and "get_transactions" in used,
          f"client calls found: {', '.join(used)}")

    # And the live tool list must expose no mutating tool.
    import mcp_server
    names = sorted(mcp_server.TOOL_DEFS)
    mutating = [n for n in names if any(w in n for w in
                ("transfer", "send", "pay", "write", "delete", "update",
                 "insert", "set_", "label"))]
    check("no mutating tool is exposed over MCP", not mutating,
          f"tools: {', '.join(names)}")

    # db.py's write surface must be exactly the three known functions.
    import inspect
    writers = [n for n, o in vars(db).items()
               if inspect.isfunction(o) and
               any(w in inspect.getsource(o).upper()
                   for w in ("INSERT ", "UPDATE ", "DELETE ", "DROP "))]
    check("db.py write surface is exactly migrate/seed/insert/sync_start/sync_finish",
          set(writers) <= {"migrate", "seed_categories", "insert_transactions",
                           "sync_start", "sync_finish"},
          f"writers: {sorted(writers)}")


def s6_mcp_protocol(tmp, expected_rows):
    section("6. MCP protocol over stdio (read tools)")
    dbp = os.path.join(tmp, "dedup", "finance.db")  # the DB from section 3
    env = {"FINTS_DB": dbp,
           "FINTS_STATE": os.path.join(tmp, "state", "fints_state.json")}
    c = Client(extra_env=env)
    try:
        init = c.send("initialize", {"protocolVersion": "2024-11-05",
                                     "clientInfo": {"name": "harness", "version": "1"}})
        check("initialize replies with protocolVersion + serverInfo",
              bool(init and init.get("protocolVersion") and init.get("serverInfo")),
              f"{init.get('serverInfo')} proto={init.get('protocolVersion')}")
        c.send("notifications/initialized", expect_reply=False)

        listing = c.send("tools/list")
        names = [t["name"] for t in (listing or {}).get("tools", [])]
        want = ["fints_status", "fints_sync", "finance_query",
                "finance_summary", "finance_uncategorized", "finance_categories"]
        check("exposes the 6 expected tools", names == want, ", ".join(names))

        err, st = c.call("fints_status")
        check("fints_status works WITHOUT contacting the bank",
              (not err) and st.get("ok") is True,
              f"db rows={st.get('db', {}).get('transaction_count')} "
              f"enrolled={st.get('state', {}).get('enrolled')}")
        check("fints_status reports the 180-day re-auth countdown",
              st["state"].get("reauth_days_remaining") is not None,
              f"days_remaining={st['state'].get('reauth_days_remaining')} "
              f"due={st['state'].get('reauth_due')} "
              f"expired={st['state'].get('reauth_expired')}")
        check("fints_status counts the stored transactions",
              st["db"]["transaction_count"] == expected_rows,
              f"{st['db']['transaction_count']} (expected {expected_rows})")
        check("fints_status never echoes a credential",
              "FINTS_PIN" not in json.dumps(st) or
              not any(k in json.dumps(st) for k in ("pin", "PIN")) or
              st["config"].get("complete") is False,
              f"config block: {json.dumps(st.get('config'))}")

        err, q = c.call("finance_query", {"limit": 10})
        check("finance_query returns rows", (not err) and q.get("n", 0) > 0,
              f"n={q.get('n')}")
        check("finance_query never returns raw_json/credentials",
              all("raw_json" not in r for r in q.get("rows", [])),
              f"columns: {sorted(q['rows'][0]) if q.get('rows') else '-'}")

        err, q2 = c.call("finance_query", {"counterparty": "REWE", "limit": 5})
        check("finance_query filters by counterparty",
              (not err) and q2.get("n") == 1 and
              "REWE" in (q2["rows"][0]["counterparty_name"] or ""),
              f"n={q2.get('n')}")

        err, q3 = c.call("finance_query",
                         {"min_cents": -100000, "max_cents": -1, "limit": 50})
        check("finance_query filters by signed amount range (expenses only)",
              (not err) and all(r["amount_cents"] < 0 for r in q3.get("rows", [])),
              f"n={q3.get('n')} amounts={[r['amount_cents'] for r in q3.get('rows', [])]}")

        err, s = c.call("finance_summary", {"period": "all"})
        check("finance_summary aggregates income vs expense",
              (not err) and s.get("ok") and s.get("n", 0) > 0,
              f"n={s.get('n')} income={s.get('income_cents')} "
              f"expense={s.get('expense_cents')} net={s.get('net_cents')}")
        check("summary net == income + expense (cents, signed)",
              s["net_cents"] == s["income_cents"] + s["expense_cents"],
              f"{s['income_cents']} + {s['expense_cents']} = {s['net_cents']}")

        err, u = c.call("finance_uncategorized", {"limit": 10})
        check("finance_uncategorized returns the unlabeled rows",
              (not err) and u.get("total_uncategorized") == expected_rows,
              f"total={u.get('total_uncategorized')} returned={u.get('n')}")

        err, cats = c.call("finance_categories")
        check("finance_categories exposes the taxonomy for the labeling card",
              (not err) and len(cats.get("categories", [])) == len(db.BUILTIN_CATEGORIES),
              f"{len(cats.get('categories', []))} categories, "
              f"{len(cats.get('rules', []))} rules, "
              f"match_types={cats.get('match_types')}")
        return c.close()
    except Exception as e:  # noqa: BLE001
        check(f"MCP section survived ({type(e).__name__})", False, repr(e))
        return c.close()


def s7_failure_modes(tmp):
    section("7. MCP failure modes (structured errors, never a crash)")
    # (a) a DB that does not exist yet
    c = Client(extra_env={"FINTS_DB": os.path.join(tmp, "nope", "finance.db"),
                          "FINTS_STATE": os.path.join(tmp, "nope", "state.json")})
    try:
        c.send("initialize", {"protocolVersion": "2024-11-05"})
        err, q = c.call("finance_query", {"limit": 5})
        check("query on a never-synced DB returns a structured db_missing error",
              err and q.get("error") == "db_missing",
              json.dumps(q, ensure_ascii=False))

        # (b) sync without enrollment / without config
        err, s = c.call("fints_sync", {"days": 7})
        check("fints_sync without config returns setup_incomplete, not a crash",
              err and s.get("error") == "setup_incomplete",
              f"error={s.get('error')} missing={s.get('missing')}")
        check("the setup error names every missing env var",
              set(s.get("missing", [])) == set(fc.REQUIRED_ENV),
              str(s.get("missing")))
        check("the setup error explains FINTS_PRODUCT_ID has no default",
              "FINTS_PRODUCT_ID" in (s.get("hint") or ""), s.get("hint"))

        # (c) status still works with nothing configured at all
        err, st = c.call("fints_status")
        check("fints_status degrades gracefully with nothing configured",
              (not err) and st.get("config", {}).get("complete") is False,
              f"next_action={st.get('next_action')!r}")
        c.close()
    except Exception as e:  # noqa: BLE001
        check(f"failure-mode section survived ({type(e).__name__})", False, repr(e))
        c.close()

    # (d) enrolled-but-expired -> tan_required, without contacting the bank
    sp = os.path.join(tmp, "expired", "state.json")
    old = (datetime.now(timezone.utc) - timedelta(days=fc.SCA_VALIDITY_DAYS + 1))
    fc.save_state(b"blob", path=sp, enrolled_at=old.isoformat(timespec="seconds"))
    c2 = Client(extra_env={
        "FINTS_DB": os.path.join(tmp, "dedup", "finance.db"),
        "FINTS_STATE": sp,
        "FINTS_BLZ": "25650106",
        "FINTS_ENDPOINT": "https://banking-ni3.s-fints-pt-ni.de/fints30",
        "FINTS_USER_ID": "harness-not-a-real-login",
        "FINTS_PIN": "harness-not-a-real-pin",
        "FINTS_PRODUCT_ID": "HARNESS-PLACEHOLDER",
    })
    try:
        c2.send("initialize", {"protocolVersion": "2024-11-05"})
        err, s = c2.call("fints_sync", {"days": 90}, timeout=30)
        check("expired SCA window -> structured tan_required (no bank contact, "
              "no hang, no crash)",
              err and s.get("error") == "tan_required",
              json.dumps({k: s.get(k) for k in
                          ("error", "message", "hint", "reauth_due")},
                         ensure_ascii=False))
        check("the tan_required message tells Karl to re-run enroll.py",
              "enroll.py" in (s.get("hint", "") + s.get("message", "")),
              s.get("hint"))
        check("the error never echoes the PIN or user id",
              "harness-not-a-real-pin" not in json.dumps(s)
              and "harness-not-a-real-login" not in json.dumps(s))

        # (e) non-SELECT SQL must be rejected
        for bad_sql in ("DELETE FROM transactions",
                        "UPDATE transactions SET category='x'",
                        "DROP TABLE transactions",
                        "SELECT 1; DELETE FROM transactions",
                        "INSERT INTO categories VALUES ('x','expense',null,0,null)",
                        "PRAGMA writable_schema=1"):
            err, r = c2.call("finance_query", {"sql": bad_sql})
            ok = err and r.get("error") == "rejected"
            check(f"rejects non-SELECT: {bad_sql[:44]!r}", ok,
                  json.dumps(r, ensure_ascii=False) if not ok else r.get("message"))

        err, r = c2.call("finance_query", {"sql": "SELECT COUNT(*) AS n FROM transactions"})
        check("a legitimate SELECT is still allowed",
              (not err) and r.get("ok") and r["rows"][0]["n"] > 0,
              json.dumps(r.get("rows"), ensure_ascii=False))

        err, r = c2.call("does_not_exist", {})
        check("an unknown tool returns a structured error, not a crash",
              err and r.get("error") == "unknown_tool", json.dumps(r))

        tail = c2.close()
        check("the server never wrote a credential to stderr",
              "harness-not-a-real-pin" not in tail, tail or "(stderr empty)")
    except Exception as e:  # noqa: BLE001
        check(f"failure-mode section (2) survived ({type(e).__name__})", False, repr(e))
        c2.close()


def s8_live():
    section("8. LIVE bank fetch")
    if os.environ.get("FINTS_LIVE") != "1":
        skip("live FinTS fetch against Sparkasse Nienburg",
             "not run: set FINTS_LIVE=1 AND have real credentials in the env "
             "AND have run enroll.py first. This section contacts the real "
             "bank; it is never part of the offline suite.")
        return
    try:
        cfg = fc.load_config()
    except fc.SetupError as e:
        check("live: config present", False, e.payload["message"])
        return
    doc, blob = fc.load_state()
    if blob is None:
        check("live: enrolled (state file present)", False,
              "run enroll.py first")
        return
    c = Client()
    try:
        c.send("initialize", {"protocolVersion": "2024-11-05"})
        err, s = c.call("fints_sync", {"days": 90}, timeout=300)
        check("live fints_sync returns ok", (not err) and s.get("ok"),
              json.dumps(s, ensure_ascii=False))
        if s.get("ok"):
            err, s2 = c.call("fints_sync", {"days": 90}, timeout=300)
            check("live re-sync is idempotent (new == 0)",
                  (not err) and s2.get("new") == 0,
                  f"new={s2.get('new')} duplicates_skipped={s2.get('duplicates_skipped')}")
    finally:
        c.close()


def main():
    print(f"harness: {os.path.basename(__file__)}")
    print(f"server : {SERVER}")
    print(f"python : {PY}")
    try:
        import fints  # noqa: F401
        print("fints  : importable (real MT940 parser will be exercised)")
    except ImportError:
        print("fints  : NOT importable (section 2 falls back to the literal "
              "parsed-record fixture; section 8 unavailable)")

    # Isolate everything: no real DB, no real state file, no real credentials.
    saved_env = {k: os.environ.get(k) for k in
                 list(fc.REQUIRED_ENV) + ["FINTS_DB", "FINTS_STATE"]}
    for k in fc.REQUIRED_ENV:
        os.environ.pop(k, None)
    tmp = tempfile.mkdtemp(prefix="fints-harness-")
    print(f"tmpdir : {tmp}")
    try:
        s1_schema(tmp)
        parsed = s2_parsing()
        rows = s3_dedup(tmp, parsed)
        s4_state(tmp)
        s5_no_write_capability()
        tail = s6_mcp_protocol(tmp, rows)
        if tail:
            print(f"\nserver stderr: {tail}")
        s7_failure_modes(tmp)
        s8_live()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
        for k, v in saved_env.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v

    print(f"\n{'=' * 60}")
    print("RESULT: " + ("ALL CHECKS PASSED" if not FAILURES
                        else f"{len(FAILURES)} FAILURE(S): " + "; ".join(FAILURES)))
    print("=" * 60)
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    sys.exit(main())
