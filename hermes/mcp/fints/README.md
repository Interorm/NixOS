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
| `mcp_server.py` | MCP server (NDJSON JSON-RPC 2.0 over stdio). Read tools: `fints_status`, `fints_sync`, `finance_query`, `finance_summary`, `finance_uncategorized`, `finance_categories`. Labeling tools (local DB writes only): `finance_relabel`, `finance_add_rule`, `finance_list_rules`, `finance_delete_rule`, `finance_proposals`, `finance_accept_proposal`, `finance_reject_proposal`, `finance_recurring`. Only `fints_sync` contacts the bank. |
| `enroll.py` | One-time interactive pushTAN enrollment, run by hand. Selects the decoupled mechanism, triggers an SCA challenge, polls until Karl approves in the S-pushTAN app, then persists the FinTS state 0600 under a flock. `--status` prints the enrollment state without contacting anything. |
| `fints_client.py` | Shared layer: env config, PIN scrubbing, the 0600 flock-guarded state file, MT940 → row mapping, and the **only** two FinTS data calls (`get_sepa_accounts`, `get_transactions`). |
| `db.py` | SQLite schema, migrations, the seeded taxonomy, the dedup contract, and every query helper. Stdlib only — does not import `fints`. |
| `categorize.py` | The categorization engine: rules pass, Gemma4-E4B pass, correction→rule promotion with the over-broad guard, and recurring detection. Stdlib only. |
| `label.py` | CLI entry point for the daily cron (`fints-label` when deployed): `--limit`, `--dry-run`, `--rules-only`, `--reprocess-llm`, `--recurring`, `--proposals`, `--json`. |
| `test_harness.py` | Offline suite (9 sections) driving `mcp_server.py` like a real MCP client: schema+perms, MT940 parsing and Soll/Haben signs, dedup idempotency, state/flock/180-day countdown/PIN-scrubbing, the no-write-capability negative test, the MCP protocol, structured failure modes, the labeling engine, and a live section skipped unless `FINTS_LIVE=1`. |
| `eval_labeling.py` | **Live** accuracy evaluation against a running Gemma4-E4B. Not part of the offline suite — run by hand after changing the prompt. |
| `fixtures/statement.mt940` | A 4-transaction MT940 statement (2 debits, 1 credit, 1 cash withdrawal) used by the offline tests. Synthetic — no real account data. |
| `fixtures/student_transactions.py` | 46 realistic German student transactions with ground-truth categories, used to measure labeling accuracy. Synthetic. |

## Environment

The nixos card owns the other half of this contract (the agenix secret that
renders these into `~/.hermes/.env`). Read from env, never hardcoded, never
logged, never written to the DB, never returned in a tool response.

All five `REQUIRED_ENV` names are declared exactly once, in the
agenix-encrypted `~/.hermes/.env`. Hermes resolves them into the MCP server's
environment via `hermes/mcp/fints.nix`; `fints-enroll` sources the same file
directly. Neither the BLZ nor the endpoint is secret, but keeping them there
too is what makes the server and the enrolment CLI unable to disagree — see
`secrets/README.md` for the five-line walkthrough.

| Var | Meaning | Default |
|---|---|---|
| `FINTS_BLZ` | Bankleitzahl | *(required, from `.env`)* |
| `FINTS_ENDPOINT` | FinTS 3.0 PIN/TAN URL | *(required, from `.env`)* |
| `FINTS_USER_ID` | Karl's **Anmeldename** (login name, NOT the account number) | *(required, from `.env`)* |
| `FINTS_PIN` | Online-banking PIN | *(required, from `.env`)* |
| `FINTS_PRODUCT_ID` | FinTS Produkt-ID — **no default exists**, see below | *(required, from `.env`)* |
| `FINTS_DB` | SQLite store | `~/.hermes/finance/finance.db` |
| `FINTS_STATE` | Persisted FinTS state | `~/.hermes/finance/fints_state.json` |
| `FINTS_ENROLL_CMD` | How the server tells you to re-enroll | `python3 enroll.py`; the Nix wiring sets it to `fints-enroll` |

A missing variable produces a structured setup error naming it — never a
stack trace, never a silent default.

## Deployment (NixOS)

`hermes/mcp/fints.nix` is the MCP registry snippet; `package.nix` in this
directory builds the application both it and `hermes/users/karl.nix` use, so
the server and the enrollment CLI can never come from different sources. On
the deployed box the commands are `fints-mcp` (started by Hermes) and
`fints-enroll` (run by Karl); there is no `enroll.py` in any working
directory, which is why `FINTS_ENROLL_CMD` exists — every "run X to
re-authorise" message names whatever the deployment actually installed.

`fints-enroll` sources the agent's `~/.hermes/.env` (override with
`HERMES_ENV_FILE`) because Hermes, not the login shell, is what normally
resolves those credentials — this keeps the PIN off the command line.

### Never package this directory with a bare `copyPathToStore ./.`

`package.nix` builds its source from an explicit `lib.fileset` allowlist
(`*.py` + `fixtures/`), and that is a security control, not housekeeping.
Verified on nix 2.34.8: with a `finance.db` and a `fints_state.json` sitting
in this directory, `git status` correctly ignored both (see `.gitignore`) and
**both still landed in the flake source and in the store copy at 0444** —
world-readable to every user on the box, forever, because a dirty flake tree
is not filtered by `.gitignore`. The real files live in `~/.hermes/finance/`,
so this needs a stray copy to bite; but this README tells you to run
`test_harness.py` from this directory, and `__pycache__/` gets there by
exactly that route. Add new modules as `*.py` and they are picked up
automatically; anything holding data must never be added to the fileset.


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

1. **Read-only *towards the bank* is a property of the code, not a runtime
   flag.** The entire FinTS surface this package touches is
   `get_sepa_accounts()` and `get_transactions()`. No SEPA transfer, standing
   order, or any other mutating FinTS operation appears anywhere.
   `test_harness.py` section 5 asserts this every run by AST-scanning every
   module for the forbidden symbols (`sepa_transfer`, `HKCCS`, `HKDSE`,
   `pain.001`, …), checking that they appear only in ban-documenting prose,
   and asserting that no tool which could move money is exposed over MCP. The
   check was verified to actually fire by injecting a
   `client.sepa_transfer(...)` call into `db.py` and watching it fail.

   The labeling tools (`finance_relabel`, `finance_add_rule`,
   `finance_delete_rule`, `finance_accept_proposal`,
   `finance_reject_proposal`) **do write** — but only to local columns:
   `category`, `label_source`, `rules`, `category_proposals`. That is why
   section 5's tool-name check bans *bank verbs* (`transfer`, `send`, `pay`,
   `dauerauftrag`, …) rather than the word "write": a DB-local annotation is
   not a bank operation. The bank-facing surface is asserted separately to be
   exactly `fints_status` + `fints_sync`, and the `finance_*`/`fints_*` prefix
   split is itself a tested invariant.
2. **The PIN never leaves the process.** It is read from `FINTS_PIN`, passed
   to the client, and never logged, stored, or returned. `Config.__repr__`
   redacts it, `fints_client.scrub()` strips it (and the user id) from every
   exception message that leaves the process, and python-fints wraps it in
   `fints.formals.Password`, whose `__str__` yields `'***'` inside the
   `Password.protect()` block the library uses for its own wire tracing.
   `deconstruct()` is documented as containing neither the PIN nor connection
   info, so the state file holds no credential.
3. **The DB write surface is a short, tested whitelist**: `insert_transactions`,
   `sync_start`, `sync_finish` (plus `migrate`/`seed_categories` for DDL) for
   the sync path, and `set_label`, `bump_hit_count`, `add_rule`, `delete_rule`,
   `record_proposal`, `decide_proposal` for labeling. Section 5 fails if any
   other function in `db.py` contains an INSERT/UPDATE/DELETE/DROP. Every
   *query* tool still opens the DB with a `mode=ro` URI, so a query
   *physically cannot* write — the harness proves it by attempting an INSERT
   on a read-only connection and asserting `attempt to write a readonly
   database`.
4. **Transaction data never reaches a cloud provider.** The labeling pass
   talks only to the loopback model fleet; `categorize._assert_local()` raises
   on any non-loopback gateway host, and only six non-identifying fields are
   ever serialised into a prompt (no IBAN, no raw MT940 blob, no credential).
   Asserted in section 9.
5. **File permissions**: `~/.hermes/finance/` is 0700, and both the DB and the
   state file are 0600 — created that way via `os.open(..., 0o600)` /
   temp-file + `os.replace()`, so the mode never depends on the umask and a
   reader never sees a partial file. Both live **outside** the git repo.
6. **A wrong PIN is never retried.** `fints_sync` returns `pin_rejected`
   immediately; repeated failures would lock the online banking.
7. Nothing is committed but code: see `.gitignore`.

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

## Labeling pipeline (rules → Gemma4-E4B → honest NULL)

`label.py` is what the daily cron runs. For every transaction with
`category IS NULL`, in cost order:

1. **Rules pass** — `rules` evaluated by ascending `priority`, first match
   wins, `hit_count` incremented, `label_source='rule'`. Match types:
   `counterparty_exact`, `counterparty_iban`, `posting_text_exact` (all
   case-insensitive equality on the trimmed value, because MT940 casing is
   wildly inconsistent) and `purpose_regex` (case-insensitive search; a
   broken regex never kills a run, it simply does not match).
2. **LLM pass** — only what the rules missed. `Gemma4-E4B` over the local
   gateway, batched, `temperature=0`, at most **2 concurrent requests**,
   `label_source='llm'`.
3. **Honest NULL** — anything unlabeled, or labeled below
   `MIN_CONFIDENCE` (0.55), stays `NULL` and surfaces in the weekly report's
   "please confirm" list. A wrong label Karl has to hunt down is worse than a
   blank one, so nothing is guessed.

Deployed, the Nix package installs this CLI as **`fints-label`** (same
arguments); run from a checkout it is `python3 label.py`. The cron must call
the wrapper, since there is no `label.py` in any working directory on the
box — the same reasoning as `fints-enroll` above.

```sh
fints-label                      # the cron's invocation
fints-label --dry-run            # decide everything, write nothing
fints-label --rules-only         # no network at all
fints-label --reprocess-llm      # clear llm labels and redo them
fints-label --recurring          # subscription report
fints-label --proposals          # pending category suggestions
```

`--reprocess-llm` only clears rows whose `label_source='llm'`; **`manual` and
`rule` labels are never touched**, so re-running it can't undo Karl's
corrections.

### Why Gemma4-E4B and not Qwen3.8-27B

Qwen3.8-27B lives on Karl's workstation behind a Wake-on-LAN proxy
(`:8090`). Using it from the 06:00 cron would **physically boot his PC every
morning**. Gemma (`chat` @ `localhost:8070`) is always on. Do not "upgrade"
the model — `FINANCE_LABEL_MODEL` exists for experiments, not for the cron.

### Privacy: local fleet only, enforced in code

* `categorize._assert_local()` raises on any non-loopback gateway host, so a
  misconfigured `HERMES_GATEWAY` **cannot** ship Karl's statements to a cloud
  API. There is no cloud fallback by design.
* `tx_payload()` whitelists exactly six fields: `id`, `date`, `amount_eur`,
  `purpose`, `counterparty`, `posting_text`. The account holder's IBAN, the
  counterparty IBAN, the dedup hash and the raw MT940 blob are never
  serialised into a prompt. Credentials are not reachable from `categorize.py`
  at all.

Both properties are asserted by `test_harness.py` section 9, not just
documented here.

### Prompt contract

The system prompt tells the model it is classifying German MT940 bank text
for a **student living on an allowance**, spells out the booking keys it will
meet (`KARTENZAHLUNG`, `SEPA-ELV`, `DAUERAUFTRAG`, `GUTSCHRIFT`,
`BARGELDAUSZAHLUNG`), and states the sign convention (negative = expense, so
an income category for a negative amount is forbidden).

The user message carries **the live category list read from the `categories`
table at call time** — never a hardcoded copy. That is what makes an accepted
proposal show up in the next prompt automatically, with no code change.

Each batch (~15 transactions, measured) must come back as a strict JSON array:

```json
[{"id": 12, "category": "Lebensmittel", "confidence": 0.95,
  "reasoning": "kurz", "proposed_new_category": null}]
```

Validation is strict and is what keeps invented categories out of the DB:

| Model output | Result |
|---|---|
| category in the allowed list, confidence ≥ 0.55 | written, `label_source='llm'` |
| category in the allowed list, confidence < 0.55 | **not** written — stays NULL |
| category **not** in the allowed list | validation failure → one retry that names the failures → then NULL |
| `category: null` + `proposed_new_category` | proposal queued, row stays NULL |
| id missing from the reply / duplicated / unknown | validation failure |

Gemma reliably wraps its answer in a ```` ```json ```` fence and sometimes adds
a sentence around it, so `extract_json_array()` strips fences first and falls
back to the outermost `[...]` span before giving up.

### Proposal workflow (why categories never auto-create)

When nothing fits, the model returns
`proposed_new_category: {"name": ..., "rationale": ...}`. That is a
**suggestion, not a decision**: it is written to `category_proposals`
(status `pending`, merged example ids and a count), the row itself stays
`NULL`, and the taxonomy is untouched. Auto-creating categories is how a
taxonomy drifts silently — the exact failure mode this avoids.

```sh
python3 label.py --proposals            # see the queue (fints-label --proposals when deployed)
# then, over MCP:
finance_accept_proposal(name="Friseur & Koerperpflege", kind="expense")
finance_reject_proposal(name="Sonstiges 2")
```

Accepting inserts the category (`is_builtin=0`) so every later prompt
includes it automatically. Rejecting just stops it being surfaced.

### Correction → rule promotion (the learning loop)

`finance_relabel(transaction_id, category, create_rule=true)` is how the
system stops re-asking an LLM about a merchant Karl has already corrected:

1. the row gets `category` + `label_source='manual'`;
2. the **most specific safe** rule is derived — `counterparty_iban` if
   present, else `counterparty_exact`, else a `purpose_regex` anchored on the
   longest distinctive token with the boilerplate (`DANKE`, `KARTENZAHLUNG`,
   `SEPA`, …) filtered out and the literal `re.escape`d;
3. the candidate is **dry-run against the whole DB before insertion**, and
   **refused** if it would
   * hit rows already labeled to a *different* category by Karl or another
     rule (`rule_would_collide`), or
   * look over-broad (`rule_too_broad`): it spans more than one other
     category, or — for a `purpose_regex` — more than two counterparties or
     >25% of the stored rows;
4. otherwise it is inserted with `source='promoted'`, and (by default)
   back-applied to matching rows still labeled `llm` — never to a `manual`
   one.

A refused rule does **not** fail the relabel: the manual correction always
stands, and the response carries a `warning` plus the full preview. Pass
`force=true` to override a guard deliberately.

This is the guard earning its keep on real data — a promotion that would have
silently rewritten 11 unrelated rows:

```
refusing to create purpose_regex='NIENBURG' -> 'Freizeit & Ausgehen':
it matches rows already labeled to 5 different categories ('Bargeld',
'Lebensmittel', 'Mensa & Essen unterwegs', 'Miete & Nebenkosten',
'Sonstige Ausgaben'); it matches 6 different counterparties, so it is not a
merchant pattern.
```

`finance_add_rule(..., dry_run=true)` runs the same preview without writing,
which is the safe way to try a hand-written rule.

### Recurring detection

`finance_recurring()` / `label.py --recurring` groups expenses by
counterparty, clusters them by amount (±15%, so one odd charge from a
merchant doesn't dilute a real subscription), and only reports a group whose
**median gap** looks like a real cycle (weekly, biweekly, monthly, quarterly
or yearly). Grouping by counterparty alone would call three random REWE trips
a subscription. The weekly-report card (T4) consumes this.

### Measured performance (real run, not an estimate)

`eval_labeling.py` against live `Gemma4-E4B` over the 46-transaction fixture
set, 2026-09-29:

| Metric | Value |
|---|---|
| Accuracy | **43/45 = 95.6%** on rows with an unambiguous ground truth |
| Validation failures | 0 |
| Rows left NULL | 0 |
| Batches | 4 (15 per request), max 2 concurrent |
| Wall clock | ~160 s for 46 transactions |
| Hosts contacted | `127.0.0.1` only |

The two disagreements were both defensible: a sports-club membership fee read
as `Sonstige Ausgaben` rather than `Freizeit & Ausgehen`, and a burger
restaurant read as `Mensa & Essen unterwegs` rather than `Freizeit &
Ausgehen`. Batches of 15 were reliable; nothing larger was adopted without
measuring, and `BATCH_SIZE` is the knob if Gemma's reliability changes.

## Tests

```sh
# full offline suite (no bank, no credentials, no network):
python3 test_harness.py

# same, with the real MT940 parser exercised (section 2):
nix-shell -p 'python3.withPackages (ps: [ ps.fints ])' --run 'python3 test_harness.py'

# adds section 8 (contacts the REAL bank; needs credentials + prior enrollment):
FINTS_LIVE=1 python3 test_harness.py

# LIVE labeling accuracy against Gemma4-E4B (needs the local fleet up):
python3 eval_labeling.py
```

The suite isolates itself completely: it unsets every `FINTS_*` credential
before starting, points the DB and state file at a fresh temp dir, and
removes it afterwards, so it can never touch the real store or the real
account. It passes both with and without the `fints` package (section 2
falls back to a literal parsed-record fixture, section 8 becomes
unavailable).

**The live section has never been run** — it needs Karl's real credentials,
which are deliberately not available to the agent that wrote this.
