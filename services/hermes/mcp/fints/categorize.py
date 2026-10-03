#!/usr/bin/env python3
"""Transaction categorization: rules first, Gemma4-E4B second, honest NULL last.

Design, in the order the pipeline runs:

1. RULES (`apply_rules`) — cheap, deterministic, auditable. Evaluated by
   ascending `priority`, first match wins, `hit_count` incremented. A merchant
   Karl has already corrected once is labeled here forever after, which is the
   whole point of the promotion loop below: the LLM is never asked twice about
   the same Lidl.

2. LLM (`llm_label_batch`) — only the rows rules missed. Gemma4-E4B over the
   local gateway, batched, temperature 0, max 2 concurrent requests.

3. NULL — no confident answer means the row stays uncategorized and surfaces in
   the weekly report's "please confirm" list. A wrong label Karl has to hunt
   down is worse than an honest blank, so nothing is guessed below
   MIN_CONFIDENCE.

PRIVACY (hard requirement, enforced in code, not in a comment):
  * `_assert_local()` refuses any gateway URL that is not loopback, so a
    misconfigured env var cannot silently ship Karl's bank data to a cloud API.
  * `tx_payload()` whitelists the five fields labeling actually needs — date,
    amount, purpose, counterparty name, posting text. The account holder's own
    IBAN, the counterparty IBAN, the dedup hash and the raw MT940 blob are
    never serialised into a prompt. Credentials live in fints_client and are
    not importable from here in any form.

Model choice is deliberate and must NOT be "upgraded": Qwen3.8-27B sits behind
a Wake-on-LAN proxy, so using it from the 06:00 cron would physically boot
Karl's workstation every morning. Gemma4-E4B is always on.
"""
import json
import os
import re
import sys
import urllib.error
import urllib.request
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from urllib.parse import urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import db  # noqa: E402

# ---------- fleet config ----------
GATEWAY = os.environ.get("HERMES_GATEWAY", "http://127.0.0.1:8080/v1")
MODEL = os.environ.get("FINANCE_LABEL_MODEL", "Gemma4-E4B")
MAX_CONCURRENCY = 2        # per-model cap across the fleet
BATCH_SIZE = 15            # measured, see README ("tune, don't assume")
REQUEST_TIMEOUT = 300
MIN_CONFIDENCE = 0.55      # below this we keep NULL rather than guess

LOCAL_HOSTS = ("127.0.0.1", "localhost", "::1", "[::1]")


def _assert_local(url):
    """Refuse to send transaction data anywhere but the loopback fleet.

    This is a hard requirement of the card, so it is a runtime assertion rather
    than a convention: if someone points HERMES_GATEWAY at api.openai.com, the
    labeling run dies instead of leaking Karl's statements.
    """
    host = urlparse(url).hostname
    if host not in LOCAL_HOSTS:
        raise RuntimeError(
            f"refusing to send transaction data to non-local host {host!r} "
            f"({url}). Transaction data is local-fleet only — there is no "
            f"cloud fallback by design.")
    return host


# ---------- rules pass ----------
def _norm(s):
    return (s or "").strip().casefold()


def rule_matches(rule, tx):
    """Does one rule match one transaction row (dict-like)?

    counterparty_exact / posting_text_exact are case-insensitive equality on
    the trimmed value (MT940 text arrives in wildly inconsistent case).
    purpose_regex is a case-insensitive search over the purpose. A broken
    regex never kills a run — it simply does not match.
    """
    mt = rule["match_type"]
    pat = rule["pattern"]
    if mt == "counterparty_exact":
        return _norm(tx["counterparty_name"]) == _norm(pat)
    if mt == "counterparty_iban":
        return _norm(tx["counterparty_iban"]) == _norm(pat)
    if mt == "posting_text_exact":
        return _norm(tx["posting_text"]) == _norm(pat)
    if mt == "purpose_regex":
        try:
            return re.search(pat, tx["purpose"] or "", re.I) is not None
        except re.error:
            return False
    return False


def first_matching_rule(rules, tx):
    """First rule (already ordered by priority, id) that matches, or None."""
    for r in rules:
        if rule_matches(r, tx):
            return r
    return None


def apply_rules(con, rows, dry_run=False):
    """Label `rows` from the rules table. Returns (labeled, remaining).

    `labeled` is a list of (tx_id, category, rule_id); `remaining` is the rows
    no rule matched, i.e. exactly the LLM pass's input.
    """
    rules = db.rules(con)
    labeled, remaining, hits = [], [], defaultdict(int)
    for tx in rows:
        r = first_matching_rule(rules, tx)
        if r is None:
            remaining.append(tx)
            continue
        labeled.append((tx["id"], r["category"], r["id"]))
        hits[r["id"]] += 1
        if not dry_run:
            db.set_label(con, tx["id"], r["category"], "rule",
                         confidence=1.0, commit=False)
    if not dry_run:
        for rule_id, n in hits.items():
            db.bump_hit_count(con, rule_id, n, commit=False)
        con.commit()
    return labeled, remaining


# ---------- prompt ----------
def tx_payload(tx):
    """The ONLY fields that ever reach the model. See the privacy note above.

    Amount is converted to signed euros for the prompt because an LLM reads
    -23.41 far more reliably than -2341 cents; the DB stays in integer cents.
    """
    return {
        "id": tx["id"],
        "date": tx["booking_date"],
        "amount_eur": round((tx["amount_cents"] or 0) / 100.0, 2),
        "purpose": (tx["purpose"] or "")[:300],
        "counterparty": (tx["counterparty_name"] or "")[:120],
        "posting_text": (tx["posting_text"] or "")[:60],
    }


SYSTEM_PROMPT = """\
Du bist ein präziser Klassifizierer für deutsche Bankumsätze (MT940/SEPA).

Kontext: Der Kontoinhaber ist ein deutscher Student, der von einer monatlichen \
Unterstützung seiner Eltern und ggf. BAföG lebt. Typische, HÄUFIGE Umsätze sind \
daher Mensa-Essen, Supermärkte, Semesterbeitrag, Semesterticket/Deutschlandticket, \
Uni-Gebühren, Handyvertrag, Krankenkasse, kleine Abos und Bargeldabhebungen — \
das sind Normalfälle, keine Ausnahmen.

Verwendungszwecke sind deutscher MT940-Text: oft abgekürzt, in GROSSBUCHSTABEN \
und mit Buchungsschlüsseln wie KARTENZAHLUNG, SEPA-ELV, LASTSCHRIFT, DAUERAUFTRAG, \
GUTSCHRIFT, BARGELDAUSZAHLUNG. Beispiele: "DANKE, IHR LIDL", "REWE SAGT DANKE", \
"SEPA-ELV 12345 STUDENTENWERK".

Vorzeichen: amount_eur < 0 ist eine Ausgabe, amount_eur > 0 eine Einnahme. \
Wähle NIEMALS eine Einnahme-Kategorie für einen negativen Betrag oder umgekehrt.

Regeln:
- Wähle für jede Transaktion GENAU EINE Kategorie aus der erlaubten Liste.
- Wenn keine Kategorie wirklich passt, setze "category": null und schlage unter \
"proposed_new_category" eine neue vor: {"name": "...", "rationale": "kurz"}. \
Schlage nur dann etwas vor, wenn die Liste echt eine Lücke hat.
- Wenn du unsicher bist, gib eine niedrige "confidence" an. Rate nicht.
- "reasoning": ein kurzer Satz, maximal 15 Wörter.

Antworte AUSSCHLIESSLICH mit einem JSON-Array, ein Objekt pro Transaktion, in \
derselben Reihenfolge, ohne weiteren Text:
[{"id": <int>, "category": <string|null>, "confidence": <0.0-1.0>, \
"reasoning": "<kurz>", "proposed_new_category": null}]"""


def build_prompt(cats, txs):
    """User message: the LIVE category list + the batch.

    Categories are read from the DB at call time, never hardcoded, so a
    category Karl accepts from the proposal queue automatically appears in the
    next prompt without a code change.
    """
    lines = [f'- "{c["name"]}" ({c["kind"]})' for c in cats]
    return (
        "Erlaubte Kategorien (genau diese Schreibweise verwenden):\n"
        + "\n".join(lines)
        + "\n\nTransaktionen:\n"
        + json.dumps([tx_payload(t) for t in txs], ensure_ascii=False, indent=1)
        + f"\n\nGib ein JSON-Array mit genau {len(txs)} Objekten zurück.")


# ---------- gateway ----------
def chat(messages, model=MODEL, temperature=0.0, timeout=REQUEST_TIMEOUT):
    """One OpenAI-compatible chat completion against the LOCAL gateway."""
    _assert_local(GATEWAY)
    body = json.dumps({
        "model": model,
        "temperature": temperature,
        "messages": messages,
    }).encode("utf-8")
    req = urllib.request.Request(
        GATEWAY.rstrip("/") + "/chat/completions", data=body,
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        payload = json.loads(resp.read().decode("utf-8"))
    return payload["choices"][0]["message"]["content"]


def extract_json_array(text):
    """Parse a JSON array out of a model reply.

    Gemma reliably wraps its answer in a ```json fence, and occasionally adds a
    sentence before it, so a bare json.loads() of the whole reply fails. Strip
    fences first, then fall back to the outermost [...] span.
    """
    if text is None:
        return None
    t = text.strip()
    fence = re.search(r"```(?:json)?\s*(.+?)```", t, re.S)
    if fence:
        t = fence.group(1).strip()
    try:
        data = json.loads(t)
    except json.JSONDecodeError:
        start, end = t.find("["), t.rfind("]")
        if start == -1 or end <= start:
            return None
        try:
            data = json.loads(t[start:end + 1])
        except json.JSONDecodeError:
            return None
    if isinstance(data, dict):
        for key in ("transactions", "results", "data"):
            if isinstance(data.get(key), list):
                return data[key]
        return [data]
    return data if isinstance(data, list) else None


def validate_items(items, allowed, batch_ids):
    """Split the model's reply into (accepted, proposals, failures).

    A category outside the allowed list AND without a proposal is a validation
    failure, not a silent pass-through — that is what makes an invented
    category impossible to write into the DB.
    """
    accepted, proposals, failures = [], [], []
    seen = set()
    by_id = {}
    for it in items or []:
        if not isinstance(it, dict):
            failures.append(("?", "not an object"))
            continue
        try:
            tid = int(it.get("id"))
        except (TypeError, ValueError):
            failures.append((it.get("id"), "id is not an integer"))
            continue
        if tid not in batch_ids:
            failures.append((tid, "id was not in the batch"))
            continue
        if tid in seen:
            continue
        seen.add(tid)
        by_id[tid] = it

        cat = it.get("category")
        prop = it.get("proposed_new_category")
        if isinstance(prop, dict) and prop.get("name"):
            proposals.append((tid, str(prop["name"]).strip(),
                              str(prop.get("rationale") or "").strip()))
        if cat is None:
            continue
        if cat not in allowed:
            failures.append((tid, f"category {cat!r} is not in the allowed list"))
            continue
        try:
            conf = float(it.get("confidence", 0))
        except (TypeError, ValueError):
            conf = 0.0
        accepted.append((tid, cat, max(0.0, min(1.0, conf)),
                         str(it.get("reasoning") or "")[:200]))
    missing = batch_ids - seen
    for tid in sorted(missing):
        failures.append((tid, "missing from the model reply"))
    return accepted, proposals, failures


def llm_label_batch(txs, cats, model=MODEL, verbose=False):
    """Label one batch. Retries once on a validation failure, then gives up.

    Returns (accepted, proposals, failures, raw_reply).
    """
    allowed = {c["name"] for c in cats}
    batch_ids = {t["id"] for t in txs}
    messages = [{"role": "system", "content": SYSTEM_PROMPT},
                {"role": "user", "content": build_prompt(cats, txs)}]
    raw = None
    for attempt in (1, 2):
        try:
            raw = chat(messages, model=model)
        except (urllib.error.URLError, OSError, KeyError, ValueError) as e:
            if attempt == 2:
                return [], [], [(None, f"gateway error: {type(e).__name__}: {e}")], raw
            continue
        items = extract_json_array(raw)
        accepted, proposals, failures = validate_items(items, allowed, batch_ids)
        if not failures or attempt == 2:
            return accepted, proposals, failures, raw
        if verbose:
            print(f"  retrying batch after {len(failures)} validation failure(s): "
                  f"{failures[:3]}", file=sys.stderr)
        # Retry with the failures spelled out rather than blindly resending.
        messages += [
            {"role": "assistant", "content": raw},
            {"role": "user", "content":
                "Deine Antwort war ungültig: "
                + "; ".join(f"id={i}: {why}" for i, why in failures[:10])
                + ". Antworte erneut, NUR das JSON-Array, mit genau den ids "
                + json.dumps(sorted(batch_ids))
                + " und ausschließlich Kategorien aus der erlaubten Liste."},
        ]
    return [], [], [(None, "unreachable")], raw


def llm_pass(con, rows, batch_size=BATCH_SIZE, dry_run=False, verbose=False,
             model=MODEL):
    """Run the LLM pass over `rows` with at most MAX_CONCURRENCY requests.

    Returns a stats dict. Writes happen on the main thread after the pool
    joins — sqlite connections are not thread-safe to share.
    """
    cats = db.categories(con)
    batches = [rows[i:i + batch_size] for i in range(0, len(rows), batch_size)]
    results = []
    if batches:
        with ThreadPoolExecutor(max_workers=MAX_CONCURRENCY) as pool:
            results = list(pool.map(
                lambda b: llm_label_batch(b, cats, model=model, verbose=verbose),
                batches))

    stats = {"batches": len(batches), "labeled": 0, "low_confidence": 0,
             "failures": [], "proposals": {}, "samples": []}
    for accepted, proposals, failures, raw in results:
        if raw and len(stats["samples"]) < 2:
            stats["samples"].append(raw[:1200])
        stats["failures"] += [f"id={i}: {why}" for i, why in failures]
        for tid, cat, conf, reasoning in accepted:
            if conf < MIN_CONFIDENCE:
                # Honest NULL beats a low-confidence guess.
                stats["low_confidence"] += 1
                continue
            stats["labeled"] += 1
            if not dry_run:
                db.set_label(con, tid, cat, "llm", confidence=conf, commit=False)
        for tid, name, rationale in proposals:
            p = stats["proposals"].setdefault(name, {"rationale": rationale,
                                                     "ids": []})
            p["ids"].append(tid)
    if not dry_run:
        con.commit()
        for name, p in stats["proposals"].items():
            db.record_proposal(con, name, p["rationale"], p["ids"])
    return stats


# ---------- correction -> rule promotion ----------
def _escape_literal(s):
    return re.escape(s)


def derive_rule(tx):
    """Most specific SAFE rule for a transaction, or None.

    Preference order is specificity: an IBAN identifies a merchant exactly, a
    counterparty name nearly so, and a purpose regex is the last resort — and
    then only anchored to a distinctive literal token, never a broad pattern
    that could sweep in unrelated rows.
    """
    if (tx.get("counterparty_iban") or "").strip():
        return {"match_type": "counterparty_iban",
                "pattern": tx["counterparty_iban"].strip(),
                "why": "counterparty IBAN identifies the merchant exactly"}
    if (tx.get("counterparty_name") or "").strip():
        return {"match_type": "counterparty_exact",
                "pattern": tx["counterparty_name"].strip(),
                "why": "counterparty name matched case-insensitively"}
    purpose = (tx.get("purpose") or "").strip()
    if purpose:
        # Longest distinctive alphabetic token, so we anchor on "STUDENTENWERK"
        # rather than on a receipt number that will never recur.
        tokens = [t for t in re.findall(r"[A-Za-zÄÖÜäöüß][A-Za-zÄÖÜäöüß.\-&]{4,}",
                                        purpose)
                  if t.upper() not in _STOPWORDS]
        if tokens:
            tok = max(tokens, key=len)
            return {"match_type": "purpose_regex",
                    "pattern": _escape_literal(tok),
                    "why": f"distinctive purpose token {tok!r} (escaped literal)"}
    return None


_STOPWORDS = {"DANKE", "IHR", "IHRE", "KARTENZAHLUNG", "LASTSCHRIFT",
              "GUTSCHRIFT", "UEBERWEISUNG", "ÜBERWEISUNG", "DAUERAUFTRAG",
              "SEPA", "SAGT", "FOLGENR", "VERFALLD", "ELEKTRONISCHE",
              "BARGELDAUSZAHLUNG", "REFERENZ", "VERWENDUNGSZWECK"}


# A rule is "broad" when it stops looking like a merchant identifier. Two
# signals, because a raw match count alone is a bad proxy on a small DB:
#   * it matches rows that already carry SEVERAL different categories, or
#   * (purpose_regex) it matches several different counterparties.
# A real merchant rule hits one merchant and at most one existing category.
BROAD_MATCH_FRACTION = 0.25
MAX_DISTINCT_OTHER_CATEGORIES = 1
MAX_DISTINCT_COUNTERPARTIES = 2


def dry_run_rule(con, match_type, pattern, category):
    """Report what a candidate rule WOULD do before it is ever inserted.

    `conflicts` are rows already labeled to a DIFFERENT category by Karl or by
    another rule — an outright veto. `relabels_llm_rows` are LLM-labeled rows
    the promotion would correct, which is desirable for a specific merchant
    rule but is ALSO the thing that makes an over-broad pattern dangerous: it
    would silently rewrite unrelated history. So the breadth signals below look
    at every matched row regardless of label_source.
    """
    rows = [dict(r) for r in con.execute(
        "SELECT id, category, label_source, counterparty_name, "
        "counterparty_iban, purpose, posting_text FROM transactions")]
    total = len(rows) or 1
    fake = {"match_type": match_type, "pattern": pattern}
    matched = [r for r in rows if rule_matches(fake, r)]
    conflicts = [{"id": r["id"], "category": r["category"],
                  "label_source": r["label_source"]}
                 for r in matched
                 if r["category"] and r["category"] != category
                 and r["label_source"] in ("manual", "rule")]
    soft = [{"id": r["id"], "category": r["category"],
             "label_source": r["label_source"]}
            for r in matched
            if r["category"] and r["category"] != category
            and r["label_source"] == "llm"]

    other_categories = sorted({r["category"] for r in matched
                               if r["category"] and r["category"] != category})
    counterparties = sorted({_norm(r["counterparty_name"]) for r in matched
                             if (r["counterparty_name"] or "").strip()})
    broad_reasons = []
    if len(other_categories) > MAX_DISTINCT_OTHER_CATEGORIES:
        broad_reasons.append(
            f"it matches rows already labeled to {len(other_categories)} "
            f"different categories ({', '.join(repr(c) for c in other_categories)})")
    if match_type == "purpose_regex":
        if len(counterparties) > MAX_DISTINCT_COUNTERPARTIES:
            broad_reasons.append(
                f"it matches {len(counterparties)} different counterparties, "
                f"so it is not a merchant pattern")
        if len(matched) > max(3, total * BROAD_MATCH_FRACTION):
            broad_reasons.append(
                f"it matches {len(matched)} of {total} stored rows "
                f"({len(matched) / total:.0%})")
    return {
        "match_type": match_type,
        "pattern": pattern,
        "category": category,
        "matched": len(matched),
        "matched_ids": [r["id"] for r in matched][:50],
        "would_label_now": sum(1 for r in matched if not r["category"]),
        "conflicts": conflicts,
        "relabels_llm_rows": soft,
        "distinct_other_categories": other_categories,
        "distinct_counterparties": len(counterparties),
        "broad": bool(broad_reasons),
        "broad_reasons": broad_reasons,
        "match_fraction": round(len(matched) / total, 3),
    }


def promote_rule(con, tx, category, priority=50, back_apply=True, force=False):
    """Derive + guard + insert the rule for a manual correction.

    Refuses (ok=False) when the candidate collides with rows Karl or a rule
    already labeled differently, or when a purpose_regex is suspiciously broad.
    `force=True` overrides, because a human who has seen the warning is allowed
    to be right.
    """
    cand = derive_rule(tx)
    if cand is None:
        return {"ok": False, "error": "no_rule_derivable",
                "message": "the transaction has no counterparty, IBAN or "
                           "usable purpose token to build a rule from"}
    preview = dry_run_rule(con, cand["match_type"], cand["pattern"], category)
    preview["why"] = cand["why"]
    if not force and preview["conflicts"]:
        return {"ok": False, "error": "rule_would_collide",
                "message": (f"refusing to create {cand['match_type']}="
                            f"{cand['pattern']!r} -> {category!r}: it also "
                            f"matches {len(preview['conflicts'])} row(s) "
                            f"already labeled to a different category. "
                            f"Pass force=true only if that is intended."),
                "preview": preview}
    if not force and preview["broad"]:
        return {"ok": False, "error": "rule_too_broad",
                "message": (f"refusing to create {cand['match_type']}="
                            f"{cand['pattern']!r} -> {category!r}: "
                            + "; ".join(preview["broad_reasons"])
                            + ". That is not a merchant rule — it would "
                              "silently rewrite unrelated rows. Pass "
                              "force=true only if that is intended."),
                "preview": preview}

    rule_id, created = db.add_rule(con, cand["match_type"], cand["pattern"],
                                   category, priority=priority,
                                   source="promoted")
    back_applied = []
    if back_apply:
        for r in preview["relabels_llm_rows"]:
            db.set_label(con, r["id"], category, "rule", confidence=1.0,
                         commit=False)
            back_applied.append(r["id"])
        for tid in preview["matched_ids"]:
            row = con.execute("SELECT category FROM transactions WHERE id=?",
                              (tid,)).fetchone()
            if row and row["category"] is None:
                db.set_label(con, tid, category, "rule", confidence=1.0,
                             commit=False)
                back_applied.append(tid)
        if back_applied:
            db.bump_hit_count(con, rule_id, len(back_applied), commit=False)
        con.commit()
    return {"ok": True, "rule_id": rule_id, "created": created,
            "match_type": cand["match_type"], "pattern": cand["pattern"],
            "category": category, "back_applied": back_applied,
            "preview": preview}


def relabel(con, tx_id, category, create_rule=True, back_apply=True,
            force=False):
    """The learning loop: Karl corrects one row, the system learns a rule."""
    tx = con.execute(
        "SELECT id, booking_date, amount_cents, purpose, counterparty_name, "
        "counterparty_iban, posting_text, category, label_source "
        "FROM transactions WHERE id=?", (int(tx_id),)).fetchone()
    if tx is None:
        return {"ok": False, "error": "not_found",
                "message": f"no transaction with id {tx_id}"}
    known = {c["name"] for c in db.categories(con)}
    if category not in known:
        return {"ok": False, "error": "unknown_category",
                "message": f"{category!r} is not a known category",
                "known_categories": sorted(known)}
    previous = tx["category"]
    db.set_label(con, tx_id, category, "manual", confidence=1.0)
    out = {"ok": True, "transaction_id": int(tx_id), "category": category,
           "previous_category": previous,
           "previous_label_source": tx["label_source"], "rule": None}
    if create_rule:
        out["rule"] = promote_rule(con, dict(tx), category,
                                   back_apply=back_apply, force=force)
        # A refused rule is NOT a failed relabel: the manual label stands.
        if not out["rule"]["ok"]:
            out["warning"] = out["rule"]["message"]
    return out


# ---------- recurring detection ----------
def _months_between(a, b):
    return (b.year - a.year) * 12 + (b.month - a.month)


def find_recurring(con, min_occurrences=3, amount_tolerance=0.15,
                   lookback_days=400):
    """Group by counterparty + similar amount + monthly-ish cadence.

    Deliberately conservative: a subscription is a *stable* amount at a
    *regular* interval. Grouping only by counterparty would call three random
    REWE trips a subscription, so amounts must agree within
    `amount_tolerance` and the median gap must look like a real cycle
    (monthly, quarterly, yearly or weekly).
    """
    rows = [dict(r) for r in con.execute(
        "SELECT id, booking_date, amount_cents, counterparty_name, purpose, "
        "category FROM transactions WHERE amount_cents < 0 "
        "ORDER BY booking_date")]
    groups = defaultdict(list)
    for r in rows:
        key = _norm(r["counterparty_name"]) or _norm(r["purpose"])[:24]
        if key:
            groups[key].append(r)

    out = []
    for key, items in groups.items():
        if len(items) < min_occurrences:
            continue
        # Cluster by amount so "Telekom 39.99 monthly" is not diluted by a
        # one-off 9.99 charge from the same merchant.
        buckets = []
        for it in sorted(items, key=lambda x: abs(x["amount_cents"])):
            amt = abs(it["amount_cents"])
            for b in buckets:
                ref = abs(b[0]["amount_cents"]) or 1
                if abs(amt - ref) <= ref * amount_tolerance:
                    b.append(it)
                    break
            else:
                buckets.append([it])
        for b in buckets:
            if len(b) < min_occurrences:
                continue
            dates = sorted(datetime.strptime(x["booking_date"], "%Y-%m-%d").date()
                           for x in b if x["booking_date"])
            if len(dates) < min_occurrences:
                continue
            gaps = [(dates[i + 1] - dates[i]).days
                    for i in range(len(dates) - 1)]
            gaps.sort()
            median = gaps[len(gaps) // 2]
            cadence = None
            if 5 <= median <= 9:
                cadence = "weekly"
            elif 12 <= median <= 16:
                cadence = "biweekly"
            elif 25 <= median <= 35:
                cadence = "monthly"
            elif 80 <= median <= 100:
                cadence = "quarterly"
            elif 350 <= median <= 380:
                cadence = "yearly"
            if cadence is None:
                continue
            amounts = [abs(x["amount_cents"]) for x in b]
            out.append({
                "counterparty": b[0]["counterparty_name"] or key,
                "cadence": cadence,
                "median_gap_days": median,
                "occurrences": len(b),
                "amount_cents_median": sorted(amounts)[len(amounts) // 2],
                "amount_cents_min": min(amounts),
                "amount_cents_max": max(amounts),
                "first_seen": dates[0].isoformat(),
                "last_seen": dates[-1].isoformat(),
                "category": b[0]["category"],
                "transaction_ids": [x["id"] for x in b],
            })
    out.sort(key=lambda d: (-d["occurrences"], -d["amount_cents_median"]))
    return out


# ---------- orchestration ----------
def run_pipeline(con, limit=500, dry_run=False, rules_only=False,
                 reprocess_llm=False, verbose=False, model=MODEL,
                 batch_size=BATCH_SIZE):
    """Rules pass, then (unless rules_only) the LLM pass. Returns a report."""
    if reprocess_llm and not dry_run:
        con.execute("UPDATE transactions SET category=NULL, label_source=NULL, "
                    "label_confidence=NULL, labeled_at=NULL "
                    "WHERE label_source='llm'")
        con.commit()

    rows = db.uncategorized(con, limit=limit)
    report = {"model": model, "gateway": GATEWAY, "dry_run": dry_run,
              "considered": len(rows)}
    rule_labeled, remaining = apply_rules(con, rows, dry_run=dry_run)
    report["rules"] = {"labeled": len(rule_labeled),
                       "detail": [{"id": i, "category": c, "rule_id": r}
                                  for i, c, r in rule_labeled][:50]}
    if rules_only:
        report["llm"] = {"skipped": True, "reason": "--rules-only"}
        report["remaining_null"] = len(remaining)
        return report
    if not remaining:
        report["llm"] = {"skipped": True, "reason": "nothing left after rules",
                         "batches": 0, "labeled": 0}
        report["remaining_null"] = 0
        return report
    stats = llm_pass(con, remaining, batch_size=batch_size, dry_run=dry_run,
                     verbose=verbose, model=model)
    report["llm"] = stats
    report["remaining_null"] = len(remaining) - stats["labeled"]
    return report
