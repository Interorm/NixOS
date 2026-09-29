# FinTS MCP (Sparkasse Nienburg) — read-only

A **strictly read-only** FinTS/HBCI client for Karl's Sparkasse Nienburg
Girokonto, exposed as an MCP server over stdio, plus a one-time interactive
pushTAN enrollment CLI and a local SQLite store. Same conventions as
`hermes/mcp/onedrive/`: NDJSON JSON-RPC 2.0 over stdio, structured error
returns instead of crashes, 0600 state files under an `fcntl.flock` guard,
and secrets from env vars only.

Unlike the OneDrive server (stdlib-only), this one needs the `fints` package
for the sync path. It is already in this nixpkgs as
`python3Packages.fints` **5.0.0** — the Nix card wires it with
`python3.withPackages (ps: [ ps.fints ])`. Everything except `fints_sync`
works without it.

## Files

| File | Purpose |
|---|---|
| `mcp_server.py` | MCP server (NDJSON JSON-RPC 2.0 over stdio). Tools: `fints_status`, `fints_sync`, `finance_query`, `finance_summary`, `finance_uncategorized`, `finance_categories`. Only `fints_sync` contacts the bank. |
| `enroll.py` | One-time interactive pushTAN enrollment, run by hand. Selects the decoupled mechanism, triggers an SCA challenge, polls until Karl approves in the S-pushTAN app, then persists the FinTS state 0600 under a flock. `--status` prints the enrollment state without contacting anything. |
| `fints_client.py` | Shared layer: env config, PIN scrubbing, the 0600 flock-guarded state file, MT940 → row mapping, and the **only** two FinTS data calls (`get_sepa_accounts`, `get_transactions`). |
| `db.py` | SQLite schema, migrations, the seeded taxonomy, the dedup contract, and every query helper. Stdlib only — does not import `fints`. |
| `test_harness.py` | Offline suite (8 sections) driving `mcp_server.py` like a real MCP client: schema+perms, MT940 parsing and Soll/Haben signs, dedup idempotency, state/flock/180-day countdown/PIN-scrubbing, the no-write-capability negative test, the MCP protocol, structured failure modes, and a live section skipped unless `FINTS_LIVE=1`. |
| `fixtures/statement.mt940` | A 4-transaction MT940 statement (2 debits, 1 credit, 1 cash withdrawal) used by the offline tests. Synthetic — no real account data. |

## Environment

The nixos card owns the other half of this contract (the agenix secret that
renders these into `~/.hermes/.env`). Read from env, never hardcoded, never
logged, never written to the DB, never returned in a tool response.

| Var | Meaning | Default |
|---|---|---|
| `FINTS_BLZ` | Bankleitzahl | *(required)* `25650106` |
| `FINTS_ENDPOINT` | FinTS 3.0 PIN/TAN URL | *(required)* `https://banking-ni3.s-fints-pt-ni.de/fints30` |
| `FINTS_USER_ID` | Karl's **Anmeldename** (login name, NOT the account number) | *(required)* |
| `FINTS_PIN` | Online-banking PIN | *(required)* |
| `FINTS_PRODUCT_ID` | FinTS Produkt-ID — **no default exists**, see below | *(required)* |
| `FINTS_DB` | SQLite store | `~/.hermes/finance/finance.db` |
| `FINTS_STATE` | Persisted FinTS state | `~/.hermes/finance/fints_state.json` |

A missing variable produces a structured setup error naming it — never a
stack trace, never a silent default.

### The Produkt-ID, and the tradeoff Karl chose

python-fints **≥ 4 has no built-in product id**. `product_id` is a mandatory
kwarg to `FinTS3PinTanClient`; passing nothing raises

```
TypeError: The product_id keyword argument is mandatory starting with
python-fints version 4.
```

(verified against 5.0.0 in this nixpkgs). So "use the library default" is not
an option, and the value has to come from somewhere.

**Karl's decision: try a placeholder id first, and only register at
[fints.org](https://www.hbci-zka.de/register/prod_register.htm) if the bank
rejects it.** Registration is free but manual and slow (the ZKA issues the id
by email). Many Sparkassen do not validate the id at all; some return an
error like *"Produkt-ID nicht registriert"* on dialog init. The fallback is
therefore: set `FINTS_PRODUCT_ID` to a placeholder, run `enroll.py`, and if
the bank refuses, register properly and re-run. Nothing else in the code
changes — it is one env var.

## Security model

1. **Read-only is a property of the code, not a runtime flag.** The entire
   FinTS surface this package touches is `get_sepa_accounts()` and
   `get_transactions()`. No SEPA transfer, standing order, or any other
   mutating FinTS operation appears anywhere. `test_harness.py` section 5
   asserts this every run by AST-scanning every module for the forbidden
   symbols (`sepa_transfer`, `HKCCS`, `HKDSE`, `pain.001`, …), checking that
   they appear only in ban-documenting prose, and asserting that no mutating
   tool is exposed over MCP. The check was verified to actually fire by
   injecting a `client.sepa_transfer(...)` call into `db.py` and watching it
   fail.
2. **The PIN never leaves the process.** It is read from `FINTS_PIN`, passed
   to the client, and never logged, stored, or returned. `Config.__repr__`
   redacts it, `fints_client.scrub()` strips it (and the user id) from every
   exception message that leaves the process, and python-fints wraps it in
   `fints.formals.Password`, whose `__str__` yields `'***'` inside the
   `Password.protect()` block the library uses for its own wire tracing.
   `deconstruct()` is documented as containing neither the PIN nor connection
   info, so the state file holds no credential.
3. **The DB write surface is three functions**: `insert_transactions`,
   `sync_start`, `sync_finish` (plus `migrate`/`seed_categories` for DDL).
   Every query tool opens the DB with a `mode=ro` URI, so a query
   *physically cannot* write — the harness proves it by attempting an INSERT
   on a read-only connection and asserting `attempt to write a readonly
   database`.
4. **File permissions**: `~/.hermes/finance/` is 0700, and both the DB and the
   state file are 0600 — created that way via `os.open(..., 0o600)` /
   temp-file + `os.replace()`, so the mode never depends on the umask and a
   reader never sees a partial file. Both live **outside** the git repo.
5. **A wrong PIN is never retried.** `fints_sync` returns `pin_rejected`
   immediately; repeated failures would lock the online banking.
6. Nothing is committed but code: see `.gitignore`.

## The 180-day re-auth expectation

PSD2 requires strong customer authentication periodically, but grants an
exemption for *reads* in between. **Sparkasse Nienburg's own security page
states 180 days**, not the commonly-cited 90.

How this package exploits that:

1. `enroll.py` performs one real SCA (a pushTAN approval in the app) and
   persists `client.deconstruct(including_private=True)`, which carries the
   bank-assigned **system id** plus the BPD/UPD.
2. Every later sync restores it with `from_data=`, so it presents the *same*
   system id and the bank applies the read exemption — **no TAN, so cron
   works**.
3. `fints_status` computes the countdown locally (`enrolled_at + 180 days`)
   and reports `reauth_days_remaining` / `reauth_due` / `reauth_expired`
   **without contacting the bank**.
4. Once the window lapses, `fints_sync` returns, instead of crashing or
   hanging:

```json
{"ok": false, "error": "tan_required",
 "message": "the 180-day PSD2 re-auth window lapsed on … — re-run enroll.py
             and approve in the S-pushTAN app",
 "hint": "python3 enroll.py"}
```

Karl re-runs `enroll.py`, approves once, and cron is TAN-free for another
~180 days. The 180 days is a *policy expectation, not a guarantee* — a bank
may demand SCA earlier (e.g. after a password change); that path returns the
same structured `tan_required`.

## Enrollment walkthrough

```sh
cd hermes/mcp/fints

# 0. credentials must be in the environment (agenix .env in production)
#    Never type the PIN on a command line — export it from the .env.

# 1. one-time enrollment (interactive; keep your phone to hand)
python3 enroll.py
#    -> lists the TAN mechanisms the bank offers
#    -> selects the pushTAN/decoupled one
#    -> prints the challenge and waits, polling every 5s for up to 5 min
#    -> APPROVE THE REQUEST IN THE S-pushTAN APP
#    -> writes ~/.hermes/finance/fints_state.json (0600)
#       and creates the DB with the seeded taxonomy

# 2. check the state at any time, contacting nothing
python3 enroll.py --status

# 3. from then on, sync non-interactively (this is what cron runs)
#    via MCP: fints_sync {"days": 90}
```

`enroll.py` writes nothing on failure or Ctrl-C — a timed-out approval just
means running it again.

## Data model

`transactions` is keyed by a `dedup_hash` UNIQUE column:
`sha256(iban|booking_date|amount_cents|purpose|counterparty_name|counterparty_iban)`,
combined with `INSERT … ON CONFLICT DO NOTHING`. That is what makes the daily
**overlapping 90-day re-fetch idempotent**: re-ingesting an already-stored
window inserts zero rows and does not touch the stored records (there is no
UPDATE path at all, so a manual/LLM label is never clobbered by a re-sync).
Proven by the harness: same fixture twice → `inserted=0`, row count
unchanged; and an overlapping fetch containing one genuinely new transaction
→ exactly 1 inserted.

Amounts are **signed integer cents**, converted with `Decimal` and never a
float. The sign follows MT940's D/C funds code as decoded by the library
(Soll → negative, Haben → positive).

`category`, `label_source`, `label_confidence` and `labeled_at` stay NULL —
**the labeling card (T2) owns categorisation**; this server only exposes the
reads it needs (`finance_uncategorized`, `finance_categories`).

The taxonomy is deliberately student-oriented (Karl is a student on an
allowance), not a generic household tree: 14 expense categories
(`Mensa & Essen unterwegs`, `Transport & Semesterticket`, `Uni & Studium`, …),
5 income (`Unterhalt/Allowance`, `BAföG`, `Nebenjob`, …) and one transfer
(`Umbuchung/Sparen`).

## Tools

| Tool | Behaviour |
|---|---|
| `fints_status()` | Enrolled? state file age and mode, days until the 180-day re-auth, last sync result, DB row/category counts, which env vars are missing. **Never contacts the bank.** |
| `fints_sync(days=90)` | Fetch (read-only), dedup-insert, write a `sync_log` row, return `{fetched, new, duplicates_skipped}`. Clamped to 1..90. On an expired/refused SCA returns `tan_required`; on a bad PIN returns `pin_rejected` without retrying. |
| `finance_query(...)` | Filtered read-only SELECT: `date_from`/`date_to`, `category`, `uncategorized_only`, `min_cents`/`max_cents`, `counterparty`, `purpose_contains`, `limit`. A raw `sql` argument is accepted but must be a **single** SELECT/WITH — `;`, `INSERT`, `UPDATE`, `DELETE`, `DROP`, `PRAGMA`… are rejected, and the connection is `mode=ro` regardless. |
| `finance_summary(period)` | Per-category aggregates plus income/expense/net totals in cents. `period`: `week`, `month`, `all`, `YYYY-MM`, `YYYY`, or explicit `date_from`/`date_to`. |
| `finance_uncategorized(limit)` | Rows with `category IS NULL`, newest first, plus the total — the input for the labeling pass. |
| `finance_categories()` | The taxonomy, the current rules, and the valid `match_type`/`kind` values (read helper for the labeling card). |

Every tool returns a single JSON text block. Errors are structured
(`{"ok": false, "error": "...", "message": "..."}`) with `isError=true` —
the server never crashes on a tool failure and never hangs waiting for a TAN.

## Tests

```sh
# full offline suite (no bank, no credentials, no network):
python3 test_harness.py

# same, with the real MT940 parser exercised (section 2):
nix-shell -p 'python3.withPackages (ps: [ ps.fints ])' --run 'python3 test_harness.py'

# adds section 8 (contacts the REAL bank; needs credentials + prior enrollment):
FINTS_LIVE=1 python3 test_harness.py
```

The suite isolates itself completely: it unsets every `FINTS_*` credential
before starting, points the DB and state file at a fresh temp dir, and
removes it afterwards, so it can never touch the real store or the real
account. It passes both with and without the `fints` package (section 2
falls back to a literal parsed-record fixture, section 8 becomes
unavailable).

**The live section has never been run** — it needs Karl's real credentials,
which are deliberately not available to the agent that wrote this.
