#!/usr/bin/env python3
"""FinTS MCP server for Sparkasse Nienburg — STRICTLY READ-ONLY.

Speaks MCP (JSON-RPC 2.0, newline-delimited) over stdio, like
``hermes/mcp/onedrive/mcp_server.py``, whose conventions this mirrors:
structured ``{"ok": false, "error": ..., "message": ...}`` returns instead of
crashes, 0600 state files under an ``fcntl.flock`` guard, and secrets from env
vars only.

Tools (all read-only):
  fints_status            enrollment + 180-day re-auth countdown + DB stats.
                          Never contacts the bank.
  fints_sync              fetch the last N days and dedup-insert. The ONLY
                          tool that talks to the bank.
  finance_query           filtered SELECT over the DB (no SQL from callers).
  finance_summary         per-category aggregates + income/expense totals.
  finance_uncategorized   rows with category IS NULL (input for the labeling card).
  finance_categories      the seeded taxonomy (+ rules), for the labeling card.

SECURITY — read-only is a property of the CODE, not a flag:
  * The entire FinTS surface used by this package is ``get_sepa_accounts()``
    and ``get_transactions()`` (see fints_client.fetch_rows). No transfer, no
    standing order, no ``sepa_transfer``/HKCCS/HKDSE reference exists anywhere
    in this directory; test_harness.py section 5 asserts that by scanning the
    source and the live tool list.
  * The DB mutation surface is ``insert_transactions`` + the ``sync_log``
    rows. Every query tool opens the DB with a ``mode=ro`` URI, so a query
    physically cannot write.
  * The PIN is read from ``FINTS_PIN``, passed to the client, and never
    logged, stored, or returned; ``fints_client.scrub()`` is applied to every
    exception message that leaves the process.

Usage:
    python3 mcp_server.py            # reads stdin, writes stdout (NDJSON)
Requires the ``fints`` package for fints_sync only; every other tool is
stdlib-only and works without it.
"""
import json
import os
import sqlite3
import sys
from datetime import date, datetime, timedelta, timezone

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import db  # noqa: E402
import fints_client as fc  # noqa: E402

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "fints"
SERVER_VERSION = "1.0.0"

MAX_DAYS = 90  # FinTS practical maximum for statement history


def log(*a):
    print(*a, file=sys.stderr, flush=True)


# ---------- DB helpers ----------
def _ro():
    """Read-only connection. Raises sqlite3.OperationalError if never synced."""
    return db.connect(readonly=True)


def _ro_or_err():
    try:
        return _ro(), None
    except sqlite3.OperationalError:
        return None, fc.err(
            "db_missing",
            f"no database at {db.db_path()} yet — run fints_sync first "
            f"(or `{fc.enroll_cmd()}` if not yet enrolled)")


# ---------- period parsing ----------
def parse_period(period=None, date_from=None, date_to=None):
    """('week'|'month'|'YYYY-MM'|'all'|None) or an explicit range -> (from, to)."""
    if date_from or date_to:
        return (date_from or "0000-01-01", date_to or "9999-12-31")
    today = date.today()
    p = (period or "month").strip().lower()
    if p == "all":
        return ("0000-01-01", "9999-12-31")
    if p == "week":
        start = today - timedelta(days=today.weekday())
        return (start.isoformat(), today.isoformat())
    if p == "month":
        return (today.replace(day=1).isoformat(), today.isoformat())
    if len(p) == 7 and p[4] == "-":  # YYYY-MM
        y, m = int(p[:4]), int(p[5:])
        start = date(y, m, 1)
        end = date(y + (m == 12), (m % 12) + 1, 1) - timedelta(days=1)
        return (start.isoformat(), end.isoformat())
    if len(p) == 4 and p.isdigit():  # YYYY
        return (f"{p}-01-01", f"{p}-12-31")
    raise ValueError(f"unrecognised period {period!r} "
                     f"(use week, month, all, YYYY-MM, YYYY, or date_from/date_to)")


# ---------- tools ----------
def t_status(args):
    """Enrollment + re-auth countdown + DB stats. NEVER contacts the bank."""
    out = {"ok": True, "bank": "Sparkasse Nienburg", "read_only": True}
    out["state"] = fc.state_info()
    out["db_path"] = db.db_path()
    # Config presence only — never the values.
    try:
        fc.load_config()
        out["config"] = {"complete": True}
    except fc.SetupError as e:
        out["config"] = {"complete": False,
                         "missing": e.payload.get("missing", []),
                         "hint": e.payload.get("hint")}
    con, cerr = _ro_or_err()
    if con is None:
        out["db"] = cerr
    else:
        try:
            out["db"] = {
                "exists": True,
                "schema_version": db.schema_version(con),
                "transaction_count": db.row_count(con),
                "uncategorized_count": con.execute(
                    "SELECT COUNT(*) FROM transactions WHERE category IS NULL"
                ).fetchone()[0],
                "category_count": len(db.categories(con)),
                "last_sync": db.last_sync(con),
                "mode": oct(os.stat(db.db_path()).st_mode & 0o777),
            }
        finally:
            con.close()
    st = out["state"]
    if not st.get("enrolled"):
        out["next_action"] = (f"run `{fc.enroll_cmd()}` once "
                              f"(interactive pushTAN approval)")
    elif st.get("reauth_expired"):
        out["next_action"] = (f"the {fc.SCA_VALIDITY_DAYS}-day PSD2 window has "
                              f"lapsed — re-run `{fc.enroll_cmd()}` to "
                              f"re-authorise")
    else:
        out["next_action"] = "none — syncs should run TAN-free"
    return out


def t_sync(args):
    """Fetch + dedup-insert. The only tool that contacts the bank."""
    days = args.get("days", MAX_DAYS)
    try:
        days = max(1, min(int(days), MAX_DAYS))
    except (TypeError, ValueError):
        return fc.err("bad_argument", f"days must be an integer 1..{MAX_DAYS}")

    try:
        cfg = fc.load_config()
    except fc.SetupError as e:
        return e.payload

    doc, blob = fc.load_state()
    if blob is None:
        return fc.err("not_enrolled",
                      f"no usable FinTS state — run `{fc.enroll_cmd()}` once "
                      f"to approve the pushTAN in the S-pushTAN app",
                      state_path=fc.state_path(),
                      hint=fc.enroll_cmd())
    info = fc.state_info()
    if info.get("reauth_expired"):
        return fc.err("tan_required",
                      f"the {fc.SCA_VALIDITY_DAYS}-day PSD2 re-auth window "
                      f"lapsed on {info.get('reauth_due')} — re-run "
                      f"`{fc.enroll_cmd()}` and approve in the S-pushTAN app",
                      state_path=fc.state_path(), hint=fc.enroll_cmd(),
                      reauth_due=info.get("reauth_due"))

    try:
        from fints.exceptions import (FinTSClientPINError, FinTSSCARequiredError,
                                      FinTSConnectionError, FinTSError)
    except ImportError as e:
        return fc.err("dependency_missing",
                      f"the `fints` package is not importable: {e}. "
                      f"Run the server from the Nix wrapper "
                      f"(python3.withPackages (ps: [ ps.fints ])).")

    db.migrate()
    con = db.connect()
    sync_id = db.sync_start(con)
    client = None
    try:
        client = fc.build_client(cfg, from_data=blob)
        with client:
            # A decoupled pushTAN demand is a RETURN value in python-fints,
            # not an exception; fetch_rows() turns it into fc.TanRequired so
            # it can be caught here. Never block waiting for an app approval
            # in a synchronous MCP call.
            rows, iban = fc.fetch_rows(client, days=days)
        new = db.insert_transactions(con, rows)
        db.sync_finish(con, sync_id, "ok", new, 0, None)
        return {"ok": True, "days": days, "fetched": len(rows),
                "new": new, "duplicates_skipped": len(rows) - new,
                "iban_suffix": (iban or "")[-4:],
                "transaction_count": db.row_count(con)}
    except fc.TanRequired as e:
        db.sync_finish(con, sync_id, "tan_required", 0, 0, "NeedTANResponse")
        return fc.err("tan_required",
                      f"the bank demanded a fresh pushTAN — re-run "
                      f"`{fc.enroll_cmd()}` and approve in the S-pushTAN app",
                      hint=fc.enroll_cmd(),
                      decoupled=e.decoupled,
                      challenge=fc.scrub(e.challenge, cfg))
    except FinTSSCARequiredError as e:
        db.sync_finish(con, sync_id, "tan_required", 0, 0, "sca_required")
        return fc.err("tan_required",
                      f"strong authentication required: {fc.scrub(e, cfg)} — "
                      f"re-run `{fc.enroll_cmd()}`", hint=fc.enroll_cmd())
    except FinTSClientPINError as e:
        # Do NOT retry: repeated wrong-PIN attempts lock the online banking.
        db.sync_finish(con, sync_id, "auth_failed", 0, 0, "pin_rejected")
        return fc.err("pin_rejected",
                      f"the bank rejected the login: {fc.scrub(e, cfg)}. "
                      f"NOT retried — repeated failures lock online banking. "
                      f"Check FINTS_USER_ID / FINTS_PIN in the agenix .env.")
    except FinTSConnectionError as e:
        db.sync_finish(con, sync_id, "network_error", 0, 0, "connection")
        return fc.err("network_error",
                      f"could not reach {cfg.endpoint}: {fc.scrub(e, cfg)}")
    except fc.SetupError as e:
        db.sync_finish(con, sync_id, "setup_error", 0, 0, e.payload.get("error"))
        return e.payload
    except (FinTSError, Exception) as e:  # noqa: BLE001 — never crash the server
        db.sync_finish(con, sync_id, "error", 0, 0, type(e).__name__)
        return fc.err("sync_failed",
                      f"{type(e).__name__}: {fc.scrub(e, cfg)}")
    finally:
        # Persist the refreshed BPD/UPD so the next sync reuses the system id
        # (that reuse is what keeps reads TAN-free under the SCA exemption).
        if client is not None:
            try:
                with fc.StateLock():
                    fc.save_state(client.deconstruct(including_private=True),
                                  enrolled_at=(doc or {}).get("enrolled_at"),
                                  tan_mechanism=(doc or {}).get("tan_mechanism"),
                                  tan_medium=(doc or {}).get("tan_medium"))
            except Exception as e:  # noqa: BLE001
                log(f"fints_mcp: could not persist refreshed state: {type(e).__name__}")
        con.close()


def t_query(args):
    """Filtered read-only SELECT. Callers pass filters, never SQL.

    A raw ``sql`` argument is accepted for convenience but must be a single
    SELECT statement; it is executed on a ``mode=ro`` connection, so even a
    bypass of the text check could not write.
    """
    con, cerr = _ro_or_err()
    if con is None:
        return cerr
    try:
        sql = (args.get("sql") or "").strip()
        if sql:
            ok, why = _is_select(sql)
            if not ok:
                return fc.err("rejected", why)
            try:
                rows = [dict(r) for r in con.execute(sql)]
            except sqlite3.Error as e:
                return fc.err("sql_error", str(e))
            return {"ok": True, "n": len(rows), "rows": rows[:1000],
                    "truncated": len(rows) > 1000}
        rows = db.query_filters(
            con,
            date_from=args.get("date_from"), date_to=args.get("date_to"),
            category=args.get("category"),
            min_cents=args.get("min_cents"), max_cents=args.get("max_cents"),
            counterparty=args.get("counterparty"),
            purpose_contains=args.get("purpose_contains"),
            uncategorized_only=bool(args.get("uncategorized_only")),
            limit=args.get("limit", 100))
        return {"ok": True, "n": len(rows), "rows": rows}
    finally:
        con.close()


_FORBIDDEN_SQL = ("insert", "update", "delete", "drop", "alter", "create",
                  "replace", "attach", "detach", "pragma", "vacuum", "reindex",
                  "begin", "commit", "rollback", "grant", "trigger")


def _is_select(sql):
    """Accept exactly one SELECT/WITH statement; reject everything else."""
    s = sql.strip().rstrip(";").strip()
    if ";" in s:
        return False, "only a single statement is allowed (';' found)"
    low = s.lower()
    if not (low.startswith("select") or low.startswith("with ")):
        return False, "only SELECT (or WITH ... SELECT) queries are allowed"
    # Token-level check so a column named e.g. "created_at" is not rejected.
    import re
    tokens = set(re.findall(r"[a-z_]+", low))
    bad = sorted(tokens & set(_FORBIDDEN_SQL))
    if bad:
        return False, f"forbidden keyword(s) in query: {', '.join(bad)}"
    return True, ""


def t_summary(args):
    con, cerr = _ro_or_err()
    if con is None:
        return cerr
    try:
        try:
            d_from, d_to = parse_period(args.get("period"),
                                        args.get("date_from"),
                                        args.get("date_to"))
        except ValueError as e:
            return fc.err("bad_argument", str(e))
        s = db.summary(con, d_from, d_to)
        s["ok"] = True
        s["period"] = args.get("period") or ("custom" if args.get("date_from")
                                             or args.get("date_to") else "month")
        return s
    finally:
        con.close()


def t_uncategorized(args):
    con, cerr = _ro_or_err()
    if con is None:
        return cerr
    try:
        limit = args.get("limit", 50)
        try:
            limit = max(1, min(int(limit), 500))
        except (TypeError, ValueError):
            return fc.err("bad_argument", "limit must be an integer 1..500")
        rows = db.uncategorized(con, limit)
        total = con.execute(
            "SELECT COUNT(*) FROM transactions WHERE category IS NULL").fetchone()[0]
        return {"ok": True, "n": len(rows), "total_uncategorized": total,
                "rows": rows}
    finally:
        con.close()


def t_categories(args):
    """The taxonomy + rules. Read helper for the labeling card (T2)."""
    con, cerr = _ro_or_err()
    if con is None:
        return cerr
    try:
        return {"ok": True, "categories": db.categories(con),
                "rules": db.rules(con),
                "match_types": list(db.MATCH_TYPES),
                "kinds": list(db.CATEGORY_KINDS)}
    finally:
        con.close()


TOOL_DEFS = {
    "fints_status": {
        "description": "FinTS enrollment status, days remaining until the "
                       "180-day PSD2 re-auth, last sync result and DB stats. "
                       "Does NOT contact the bank.",
        "inputSchema": {"type": "object", "properties": {}},
        "impl": t_status,
    },
    "fints_sync": {
        "description": "Fetch the last N days of Girokonto transactions "
                       "(read-only) and dedup-insert them. Idempotent: "
                       "re-running inserts nothing already stored.",
        "inputSchema": {
            "type": "object",
            "properties": {"days": {"type": "integer",
                                    "description": f"1..{MAX_DAYS}, default {MAX_DAYS}"}},
        },
        "impl": t_sync,
    },
    "finance_query": {
        "description": "Read-only query over stored transactions. Use the "
                       "filter arguments; a raw `sql` must be a single SELECT.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "date_from": {"type": "string", "description": "YYYY-MM-DD inclusive"},
                "date_to": {"type": "string", "description": "YYYY-MM-DD inclusive"},
                "category": {"type": "string"},
                "uncategorized_only": {"type": "boolean"},
                "min_cents": {"type": "integer", "description": "signed cents"},
                "max_cents": {"type": "integer", "description": "signed cents"},
                "counterparty": {"type": "string", "description": "substring of name or IBAN"},
                "purpose_contains": {"type": "string"},
                "limit": {"type": "integer", "description": "default 100, max 1000"},
                "sql": {"type": "string", "description": "optional single SELECT"},
            },
        },
        "impl": t_query,
    },
    "finance_summary": {
        "description": "Per-category aggregates and income/expense totals "
                       "(cents) for a period.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "period": {"type": "string",
                           "description": "week | month | all | YYYY-MM | YYYY"},
                "date_from": {"type": "string"},
                "date_to": {"type": "string"},
            },
        },
        "impl": t_summary,
    },
    "finance_uncategorized": {
        "description": "Transactions with category IS NULL, newest first — "
                       "the input for the labeling pass.",
        "inputSchema": {
            "type": "object",
            "properties": {"limit": {"type": "integer",
                                     "description": "default 50, max 500"}},
        },
        "impl": t_uncategorized,
    },
    "finance_categories": {
        "description": "The seeded category taxonomy and current rules "
                       "(read helper for the labeling pass).",
        "inputSchema": {"type": "object", "properties": {}},
        "impl": t_categories,
    },
}


# ---------- MCP / JSON-RPC ----------
def tool_result(payload, ok=None):
    """One JSON text block, like the OneDrive server's text blocks."""
    if ok is None:
        ok = bool(payload.get("ok", True)) if isinstance(payload, dict) else True
    return {"content": [{"type": "text",
                         "text": json.dumps(payload, indent=2, ensure_ascii=False,
                                            default=str)}],
            "isError": not ok}


def handle(msg):
    mid = msg.get("id")
    method = msg.get("method")
    params = msg.get("params", {}) or {}
    is_notification = mid is None

    if method == "initialize":
        return {
            "protocolVersion": PROTOCOL_VERSION,
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
            "capabilities": {"tools": {}},
            "instructions": (
                "Read-only access to Karl's Sparkasse Nienburg Girokonto. "
                "fints_sync is the only tool that contacts the bank; it is "
                "idempotent, so re-running it is safe. No transfer or other "
                "write capability exists in this server. If fints_status "
                f"reports not enrolled or an expired {fc.SCA_VALIDITY_DAYS}-day "
                f"PSD2 window, Karl must run `{fc.enroll_cmd()}` by hand and "
                f"approve in the S-pushTAN app."),
        }
    if method == "notifications/initialized":
        return None
    if method == "ping":
        return {}
    if method == "tools/list":
        return {"tools": [{"name": n, "description": d["description"],
                           "inputSchema": d["inputSchema"]}
                          for n, d in TOOL_DEFS.items()]}
    if method == "tools/call":
        name = params.get("name")
        if name not in TOOL_DEFS:
            if is_notification:
                return None
            return tool_result(fc.err("unknown_tool",
                                      f"no such tool: {name}",
                                      available=sorted(TOOL_DEFS)), ok=False)
        try:
            payload = TOOL_DEFS[name]["impl"](params.get("arguments", {}) or {})
        except Exception as e:  # noqa: BLE001 — a tool must never crash the server
            payload = fc.err("internal_error",
                             f"{type(e).__name__}: {fc.scrub(e)}")
        if is_notification:
            return None
        return tool_result(payload)

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
                result = {"error": {"code": -32603,
                                    "message": f"Internal error: {type(e).__name__}"}}
            if m.get("id") is not None:
                out.append({"jsonrpc": "2.0", "id": m["id"], "result": result})
            elif result is not None:
                out.append({"jsonrpc": "2.0", "result": result})
        if out:
            sys.stdout.write(json.dumps(out[0] if len(out) == 1 else out) + "\n")
            sys.stdout.flush()
    log("fints_mcp: stdin closed, exiting")


if __name__ == "__main__":
    main()
