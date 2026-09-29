#!/usr/bin/env python3
"""SQLite store for the FinTS MCP server — stdlib only, no `fints` import.

Deliberately dependency-free so the schema, the dedup contract and every query
helper are testable without a bank connection (and without the `fints` package
being importable at all).

Location: ``FINTS_DB`` env var, default ``~/.hermes/finance/finance.db``.
The parent dir is ``mkdir -p``'d at 0700 and the DB file is chmod 0600 on
creation — it holds Karl's full transaction history.

Write surface (deliberately tiny, audited by test_harness.py):
  * ``insert_transactions()`` — INSERT ... ON CONFLICT(dedup_hash) DO NOTHING
  * ``sync_start()`` / ``sync_finish()`` — the sync_log row
  * ``migrate()`` — DDL + taxonomy seed
Everything else opens the DB **read-only** (``mode=ro`` URI), so a query
helper physically cannot mutate the store.

Idempotency contract: ``dedup_hash`` is UNIQUE and derived from
sha256(iban|booking_date|amount_cents|purpose|counterparty_name|counterparty_iban).
Re-fetching an overlapping 90-day window every day therefore inserts nothing
new for transactions already stored — no UPDATE, no duplicate rows. That is
what makes the cron sync safe to run repeatedly.
"""
import hashlib
import json
import os
import sqlite3
from datetime import datetime, timezone

SCHEMA_VERSION = 2

DEFAULT_DB = "~/.hermes/finance/finance.db"


def db_path():
    """Resolve the DB path from the env (lazy: tests override FINTS_DB/HOME)."""
    return os.path.expanduser(os.environ.get("FINTS_DB") or DEFAULT_DB)


# ---------- taxonomy ----------
# Student-oriented on purpose (Karl is a student on an allowance), NOT a
# generic household tree. Seeded once; is_builtin=1 marks these as ours so a
# later manual/LLM-added category is distinguishable.
BUILTIN_CATEGORIES = [
    # (name, kind)
    ("Miete & Nebenkosten", "expense"),
    ("Lebensmittel", "expense"),
    ("Mensa & Essen unterwegs", "expense"),
    ("Uni & Studium", "expense"),
    ("Transport & Semesterticket", "expense"),
    ("Abos & Digital", "expense"),
    ("Handy & Internet", "expense"),
    ("Versicherung & Krankenkasse", "expense"),
    ("Gesundheit", "expense"),
    ("Freizeit & Ausgehen", "expense"),
    ("Kleidung", "expense"),
    ("Anschaffungen", "expense"),
    ("Bargeld", "expense"),
    ("Sonstige Ausgaben", "expense"),
    ("Unterhalt/Allowance", "income"),
    ("BAföG", "income"),
    ("Nebenjob", "income"),
    ("Rückerstattung", "income"),
    ("Sonstige Einnahmen", "income"),
    ("Umbuchung/Sparen", "transfer"),
]

MATCH_TYPES = ("counterparty_exact", "counterparty_iban", "purpose_regex",
               "posting_text_exact")
CATEGORY_KINDS = ("expense", "income", "transfer")
LABEL_SOURCES = ("rule", "llm", "manual")

DDL = """
CREATE TABLE IF NOT EXISTS transactions (
  id                INTEGER PRIMARY KEY,
  dedup_hash        TEXT UNIQUE NOT NULL,
  iban              TEXT,
  booking_date      TEXT,
  value_date        TEXT,
  amount_cents      INTEGER,
  currency          TEXT,
  purpose           TEXT,
  counterparty_name TEXT,
  counterparty_iban TEXT,
  posting_text      TEXT,
  end_to_end_id     TEXT,
  category          TEXT,
  label_source      TEXT CHECK (label_source IN ('rule','llm','manual') OR label_source IS NULL),
  label_confidence  REAL,
  labeled_at        TEXT,
  raw_json          TEXT,
  fetched_at        TEXT
);
CREATE INDEX IF NOT EXISTS ix_tx_booking  ON transactions(booking_date);
CREATE INDEX IF NOT EXISTS ix_tx_category ON transactions(category);
CREATE INDEX IF NOT EXISTS ix_tx_cpty     ON transactions(counterparty_name);

CREATE TABLE IF NOT EXISTS rules (
  id         INTEGER PRIMARY KEY,
  match_type TEXT NOT NULL CHECK (match_type IN
               ('counterparty_exact','counterparty_iban','purpose_regex','posting_text_exact')),
  pattern    TEXT NOT NULL,
  category   TEXT NOT NULL,
  priority   INTEGER DEFAULT 100,
  source     TEXT,
  created_at TEXT,
  hit_count  INTEGER DEFAULT 0,
  UNIQUE(match_type, pattern)
);

CREATE TABLE IF NOT EXISTS categories (
  name        TEXT PRIMARY KEY,
  kind        TEXT NOT NULL CHECK (kind IN ('expense','income','transfer')),
  description TEXT,
  is_builtin  INTEGER DEFAULT 0,
  created_at  TEXT
);

-- Schema v2 (labeling card): LLM-proposed categories await Karl's approval
-- here instead of being auto-inserted into `categories`. Auto-creation would
-- let the taxonomy drift silently, which is the failure mode to avoid: a
-- proposal is a SUGGESTION, and only accept_proposal() promotes it.
CREATE TABLE IF NOT EXISTS category_proposals (
  name         TEXT PRIMARY KEY,
  rationale    TEXT,
  example_ids  TEXT,            -- JSON array of transaction ids
  count        INTEGER DEFAULT 0,
  status       TEXT NOT NULL DEFAULT 'pending'
                 CHECK (status IN ('pending','accepted','rejected')),
  created_at   TEXT,
  decided_at   TEXT
);

CREATE TABLE IF NOT EXISTS sync_log (
  id            INTEGER PRIMARY KEY,
  started_at    TEXT,
  finished_at   TEXT,
  status        TEXT,
  new_count     INTEGER,
  updated_count INTEGER,
  error         TEXT
);
"""


def now_iso():
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


# ---------- connections ----------
def connect(path=None, readonly=False):
    """Open the DB. readonly=True uses a mode=ro URI (mutation is impossible).

    A read-only open of a non-existent file raises sqlite3.OperationalError,
    which is the honest answer ("not synced yet") — callers handle it.
    """
    p = path or db_path()
    if readonly:
        con = sqlite3.connect(f"file:{p}?mode=ro", uri=True)
    else:
        _ensure_file(p)
        con = sqlite3.connect(p)
    con.row_factory = sqlite3.Row
    con.execute("PRAGMA foreign_keys = ON")
    return con


def _ensure_file(p):
    """mkdir -p the parent at 0700 and pre-create the DB file at 0600.

    Creating the file ourselves (before sqlite does) is what guarantees the
    0600 mode regardless of the process umask — sqlite would create it 0644
    under a default umask of 022.
    """
    d = os.path.dirname(os.path.abspath(p))
    os.makedirs(d, mode=0o700, exist_ok=True)
    if not os.path.exists(p):
        fd = os.open(p, os.O_CREAT | os.O_WRONLY, 0o600)
        os.close(fd)
    else:
        # Repair the mode if something created it too permissively.
        if (os.stat(p).st_mode & 0o777) != 0o600:
            os.chmod(p, 0o600)


def migrate(path=None):
    """Create/upgrade the schema and seed the taxonomy. Idempotent."""
    p = path or db_path()
    con = connect(p)
    try:
        con.executescript(DDL)
        seed_categories(con)
        con.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
        con.commit()
    finally:
        con.close()
    os.chmod(p, 0o600)
    return p


def schema_version(con):
    return con.execute("PRAGMA user_version").fetchone()[0]


def seed_categories(con):
    """Insert the builtin taxonomy. Never overwrites a user-edited row."""
    ts = now_iso()
    con.executemany(
        "INSERT INTO categories(name, kind, description, is_builtin, created_at) "
        "VALUES (?,?,?,1,?) ON CONFLICT(name) DO NOTHING",
        [(name, kind, None, ts) for name, kind in BUILTIN_CATEGORIES])


# ---------- dedup ----------
def dedup_hash(iban, booking_date, amount_cents, purpose, counterparty_name,
               counterparty_iban):
    """sha256 of the natural key, pipe-joined, NULLs as empty strings.

    amount_cents is stringified as a signed int so -5230 and 5230 differ.
    """
    parts = [iban or "", booking_date or "", str(int(amount_cents)),
             purpose or "", counterparty_name or "", counterparty_iban or ""]
    return hashlib.sha256("|".join(parts).encode("utf-8")).hexdigest()


# ---------- writes (the entire mutation surface) ----------
TX_COLUMNS = ("dedup_hash", "iban", "booking_date", "value_date",
              "amount_cents", "currency", "purpose", "counterparty_name",
              "counterparty_iban", "posting_text", "end_to_end_id",
              "raw_json", "fetched_at")


def insert_transactions(con, rows):
    """INSERT ... ON CONFLICT(dedup_hash) DO NOTHING for each row dict.

    Returns the number of rows actually inserted (``total_changes`` delta, so
    conflicts are excluded). No UPDATE path exists: an already-stored
    transaction is left byte-for-byte as it was, which is what makes the
    daily overlapping re-fetch idempotent.
    """
    if not rows:
        return 0
    ts = now_iso()
    payload = []
    for r in rows:
        h = r.get("dedup_hash") or dedup_hash(
            r.get("iban"), r.get("booking_date"), r.get("amount_cents", 0),
            r.get("purpose"), r.get("counterparty_name"),
            r.get("counterparty_iban"))
        raw = r.get("raw_json")
        if raw is not None and not isinstance(raw, str):
            raw = json.dumps(raw, ensure_ascii=False, sort_keys=True)
        payload.append((h, r.get("iban"), r.get("booking_date"),
                        r.get("value_date"), int(r.get("amount_cents", 0)),
                        r.get("currency"), r.get("purpose"),
                        r.get("counterparty_name"), r.get("counterparty_iban"),
                        r.get("posting_text"), r.get("end_to_end_id"),
                        raw, r.get("fetched_at") or ts))
    before = con.total_changes
    cols = ",".join(TX_COLUMNS)
    marks = ",".join("?" * len(TX_COLUMNS))
    con.executemany(
        f"INSERT INTO transactions({cols}) VALUES ({marks}) "
        "ON CONFLICT(dedup_hash) DO NOTHING", payload)
    con.commit()
    return con.total_changes - before


def sync_start(con, started_at=None):
    cur = con.execute(
        "INSERT INTO sync_log(started_at, status) VALUES (?, 'running')",
        (started_at or now_iso(),))
    con.commit()
    return cur.lastrowid


def sync_finish(con, sync_id, status, new_count=0, updated_count=0, error=None):
    con.execute(
        "UPDATE sync_log SET finished_at=?, status=?, new_count=?, "
        "updated_count=?, error=? WHERE id=?",
        (now_iso(), status, new_count, updated_count, error, sync_id))
    con.commit()


# ---------- labeling writes (schema v2, the categorization card) ----------
# These mutate ONLY label/rule/proposal columns of the local DB. They are not a
# bank write path: nothing here can move money, and the FinTS surface is still
# exactly get_sepa_accounts/get_transactions. test_harness.py section 5 keeps
# both facts honest.

def set_label(con, tx_id, category, source, confidence=None, commit=True):
    """Set category/label_source/label_confidence/labeled_at on one row.

    `category=None` clears the label (used by --reprocess-llm). `source` is
    CHECK-constrained by the schema to rule|llm|manual.
    """
    if source is not None and source not in LABEL_SOURCES:
        raise ValueError(f"label_source must be one of {LABEL_SOURCES}, got {source!r}")
    con.execute(
        "UPDATE transactions SET category=?, label_source=?, "
        "label_confidence=?, labeled_at=? WHERE id=?",
        (category, source, confidence, now_iso() if category else None,
         int(tx_id)))
    if commit:
        con.commit()


def bump_hit_count(con, rule_id, n=1, commit=True):
    con.execute("UPDATE rules SET hit_count = hit_count + ? WHERE id=?",
                (int(n), int(rule_id)))
    if commit:
        con.commit()


def add_rule(con, match_type, pattern, category, priority=100, source="manual"):
    """Insert a rule. Returns (rule_id, created:bool).

    UNIQUE(match_type, pattern) makes this idempotent: re-promoting the same
    merchant returns the existing rule instead of raising.
    """
    if match_type not in MATCH_TYPES:
        raise ValueError(f"match_type must be one of {MATCH_TYPES}, got {match_type!r}")
    cur = con.execute(
        "INSERT INTO rules(match_type, pattern, category, priority, source, "
        "created_at) VALUES (?,?,?,?,?,?) "
        "ON CONFLICT(match_type, pattern) DO NOTHING",
        (match_type, pattern, category, int(priority), source, now_iso()))
    con.commit()
    if cur.rowcount:
        return cur.lastrowid, True
    row = con.execute("SELECT id FROM rules WHERE match_type=? AND pattern=?",
                      (match_type, pattern)).fetchone()
    return (row["id"] if row else None), False


def delete_rule(con, rule_id):
    cur = con.execute("DELETE FROM rules WHERE id=?", (int(rule_id),))
    con.commit()
    return cur.rowcount


def record_proposal(con, name, rationale, tx_ids):
    """Upsert a pending category proposal, merging example ids and count.

    A proposal NEVER touches the `categories` table — accept_proposal() is the
    only path from suggestion to taxonomy, and it needs Karl.
    """
    row = con.execute("SELECT example_ids, count, status FROM "
                      "category_proposals WHERE name=?", (name,)).fetchone()
    new_ids = [int(i) for i in tx_ids]
    if row is None:
        con.execute(
            "INSERT INTO category_proposals(name, rationale, example_ids, "
            "count, status, created_at) VALUES (?,?,?,?, 'pending', ?)",
            (name, rationale, json.dumps(new_ids), len(new_ids), now_iso()))
    else:
        merged = list(dict.fromkeys(json.loads(row["example_ids"] or "[]") + new_ids))
        con.execute(
            "UPDATE category_proposals SET example_ids=?, count=?, "
            "rationale=COALESCE(rationale, ?) WHERE name=?",
            (json.dumps(merged[:20]), len(merged), rationale, name))
    con.commit()


def decide_proposal(con, name, status, kind="expense"):
    """Accept (also inserting the category) or reject a proposal."""
    if status not in ("accepted", "rejected"):
        raise ValueError("status must be accepted or rejected")
    row = con.execute("SELECT name, rationale FROM category_proposals "
                      "WHERE name=?", (name,)).fetchone()
    if row is None:
        return None
    if status == "accepted":
        con.execute(
            "INSERT INTO categories(name, kind, description, is_builtin, "
            "created_at) VALUES (?,?,?,0,?) ON CONFLICT(name) DO NOTHING",
            (name, kind, row["rationale"], now_iso()))
    con.execute("UPDATE category_proposals SET status=?, decided_at=? "
                "WHERE name=?", (status, now_iso(), name))
    con.commit()
    return status


def proposals(con, status=None):
    sql = ("SELECT name, rationale, example_ids, count, status, created_at, "
           "decided_at FROM category_proposals")
    params = []
    if status:
        sql += " WHERE status=?"
        params.append(status)
    sql += " ORDER BY count DESC, name"
    out = []
    for r in con.execute(sql, params):
        d = dict(r)
        d["example_ids"] = json.loads(d["example_ids"] or "[]")
        out.append(d)
    return out


# ---------- reads ----------
def row_count(con):
    return con.execute("SELECT COUNT(*) FROM transactions").fetchone()[0]


def last_sync(con):
    r = con.execute(
        "SELECT * FROM sync_log ORDER BY id DESC LIMIT 1").fetchone()
    return dict(r) if r else None


def categories(con):
    return [dict(r) for r in con.execute(
        "SELECT name, kind, description, is_builtin FROM categories "
        "ORDER BY kind, name")]


def rules(con):
    return [dict(r) for r in con.execute(
        "SELECT id, match_type, pattern, category, priority, source, hit_count "
        "FROM rules ORDER BY priority, id")]


def uncategorized(con, limit=50):
    return [dict(r) for r in con.execute(
        "SELECT id, booking_date, amount_cents, currency, purpose, "
        "counterparty_name, counterparty_iban, posting_text "
        "FROM transactions WHERE category IS NULL "
        "ORDER BY booking_date DESC, id DESC LIMIT ?", (int(limit),))]


# The columns a filtered query may constrain / return. Whitelisted so a
# caller can never reach a column that does not exist (or inject SQL).
QUERY_COLUMNS = ("id", "iban", "booking_date", "value_date", "amount_cents",
                 "currency", "purpose", "counterparty_name",
                 "counterparty_iban", "posting_text", "end_to_end_id",
                 "category", "label_source", "label_confidence", "labeled_at",
                 "fetched_at")


def query_filters(con, date_from=None, date_to=None, category=None,
                  min_cents=None, max_cents=None, counterparty=None,
                  purpose_contains=None, uncategorized_only=False,
                  limit=100, order="booking_date DESC, id DESC"):
    """Parameterised SELECT over the whitelisted columns. No SQL from callers."""
    where, params = [], []
    if date_from:
        where.append("booking_date >= ?")
        params.append(date_from)
    if date_to:
        where.append("booking_date <= ?")
        params.append(date_to)
    if category:
        where.append("category = ?")
        params.append(category)
    if uncategorized_only:
        where.append("category IS NULL")
    if min_cents is not None:
        where.append("amount_cents >= ?")
        params.append(int(min_cents))
    if max_cents is not None:
        where.append("amount_cents <= ?")
        params.append(int(max_cents))
    if counterparty:
        where.append("(counterparty_name LIKE ? OR counterparty_iban LIKE ?)")
        params += [f"%{counterparty}%", f"%{counterparty}%"]
    if purpose_contains:
        where.append("purpose LIKE ?")
        params.append(f"%{purpose_contains}%")
    sql = f"SELECT {','.join(QUERY_COLUMNS)} FROM transactions"
    if where:
        sql += " WHERE " + " AND ".join(where)
    sql += f" ORDER BY {order} LIMIT ?"
    params.append(max(1, min(int(limit), 1000)))
    return [dict(r) for r in con.execute(sql, params)]


def summary(con, date_from, date_to):
    """Aggregate by category plus income/expense totals, in cents."""
    by_cat = [dict(r) for r in con.execute(
        "SELECT COALESCE(t.category, '(uncategorized)') AS category, "
        "       c.kind AS kind, COUNT(*) AS n, SUM(t.amount_cents) AS cents "
        "FROM transactions t LEFT JOIN categories c ON c.name = t.category "
        "WHERE t.booking_date >= ? AND t.booking_date <= ? "
        "GROUP BY t.category ORDER BY cents ASC", (date_from, date_to))]
    tot = con.execute(
        "SELECT COALESCE(SUM(CASE WHEN amount_cents > 0 THEN amount_cents END), 0) AS income, "
        "       COALESCE(SUM(CASE WHEN amount_cents < 0 THEN amount_cents END), 0) AS expense, "
        "       COUNT(*) AS n "
        "FROM transactions WHERE booking_date >= ? AND booking_date <= ?",
        (date_from, date_to)).fetchone()
    return {
        "date_from": date_from,
        "date_to": date_to,
        "n": tot["n"],
        "income_cents": tot["income"],
        "expense_cents": tot["expense"],
        "net_cents": tot["income"] + tot["expense"],
        "by_category": by_cat,
    }
