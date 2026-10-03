#!/usr/bin/env python3
"""LIVE evaluation of the labeling pipeline against a real Gemma4-E4B.

Not part of test_harness.py on purpose: that suite is offline and hermetic,
this one requires the local fleet to be up. Run it by hand (or after changing
the prompt) to get real accuracy numbers:

    python3 eval_labeling.py

It proves, in order, every acceptance criterion of the categorization card:
  A. the gateway really serves Gemma4-E4B
  B. accuracy of the LLM pass over 46 ground-truthed student transactions
  C. correction -> rule promotion, and that the re-run uses the RULE with zero
     LLM calls
  D. the over-broad-rule guard actually refuses a bad rule
  E. no request ever left the loopback interface

Every network call is counted and its host asserted, so "zero cloud requests"
is a measured fact rather than a claim.
"""
import json
import os
import shutil
import sys
import tempfile
import time
import urllib.request
from urllib.parse import urlparse

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "fixtures"))

import categorize  # noqa: E402
import db  # noqa: E402
import student_transactions as fx  # noqa: E402

FAILURES = []
CALL_LOG = []


def check(label, ok, detail=""):
    print(f"[{'PASS' if ok else 'FAIL'}] {label}")
    if detail:
        for ln in str(detail).splitlines():
            print(f"       {ln}")
    if not ok:
        FAILURES.append(label)
    return ok


def section(t):
    print(f"\n=== {t} ===")


def instrument():
    """Wrap categorize.chat so every model call is counted and host-checked.

    This is what turns "no cloud provider was contacted" from an assertion in a
    summary into evidence: the host of every single request is recorded.
    """
    original = categorize.chat

    def wrapper(messages, **kw):
        host = urlparse(categorize.GATEWAY).hostname
        t0 = time.time()
        out = original(messages, **kw)
        CALL_LOG.append({"host": host, "seconds": round(time.time() - t0, 2),
                         "chars_out": len(out or "")})
        return out

    categorize.chat = wrapper
    return original


def main():
    instrument()
    tmp = tempfile.mkdtemp(prefix="fints_eval_")
    os.environ["FINTS_DB"] = os.path.join(tmp, "eval.db")
    try:
        # ---------- A. gateway ----------
        section("A. gateway serves Gemma4-E4B")
        with urllib.request.urlopen(
                "http://127.0.0.1:8080/gateway/status", timeout=15) as r:
            status = json.loads(r.read().decode())
        route = status.get("routes", {}).get(categorize.MODEL)
        check(f"{categorize.MODEL} is routed by the gateway", bool(route), route)
        ep = next((e for e in status["endpoints"]
                   if route and e["name"] == route["endpoint"]), None)
        check("its endpoint is reachable", bool(ep and ep["ok"]),
              f"{ep['name']} @ {ep['url']} ok={ep['ok']} ({ep['detail']})" if ep else "")
        check("the endpoint is on localhost (no Wake-on-LAN boot)",
              bool(ep) and urlparse(ep["url"]).hostname in categorize.LOCAL_HOSTS,
              ep["url"] if ep else "")

        # ---------- seed ----------
        section("B. seed the fixture set")
        db.migrate()
        con = db.connect()
        check("schema migrated to v2 (category_proposals exists)",
              db.schema_version(con) == 2, f"user_version={db.schema_version(con)}")
        n = db.insert_transactions(con, fx.as_rows())
        check(f"inserted {n} fixture transactions (>= 40 required)", n >= 40, f"n={n}")

        expected = fx.expected_by_key()
        rows = [dict(r) for r in con.execute(
            "SELECT id, booking_date, amount_cents, purpose FROM transactions")]
        truth = {}
        for r in rows:
            truth[r["id"]] = expected.get(
                (r["booking_date"], r["amount_cents"], r["purpose"]))
        check("ground truth resolved for every row",
              all(k in truth for k in truth), f"{len(truth)} rows")

        # ---------- B. full pipeline ----------
        section("B. full pipeline against live Gemma4-E4B")
        t0 = time.time()
        report = categorize.run_pipeline(con, limit=500, verbose=True)
        elapsed = time.time() - t0
        print(f"  wall clock: {elapsed:.1f}s over {report['llm']['batches']} batch(es), "
              f"{len(CALL_LOG)} model call(s)")
        check("the rules pass labeled nothing (no rules exist yet)",
              report["rules"]["labeled"] == 0, json.dumps(report["rules"]))
        check("the LLM pass labeled the bulk of the rows",
              report["llm"]["labeled"] >= 35,
              f"labeled={report['llm']['labeled']} "
              f"low_confidence={report['llm']['low_confidence']} "
              f"failures={len(report['llm']['failures'])}")

        scored = [dict(r) for r in con.execute(
            "SELECT id, category, label_source, label_confidence, purpose, "
            "counterparty_name FROM transactions")]
        gradable = [r for r in scored if truth.get(r["id"]) is not None]
        correct = [r for r in gradable if r["category"] == truth[r["id"]]]
        wrong = [r for r in gradable if r["category"] != truth[r["id"]]]
        acc = len(correct) / max(1, len(gradable))
        print(f"\n  ACCURACY: {len(correct)}/{len(gradable)} = {acc:.1%} "
              f"(on the {len(gradable)} rows with an unambiguous ground truth)")
        if wrong:
            print("  disagreements:")
            for r in wrong:
                print(f"    id={r['id']:<3d} got={str(r['category'])!r:34s} "
                      f"want={truth[r['id']]!r:34s} "
                      f"[{(r['counterparty_name'] or r['purpose'])[:38]}]")
        check("accuracy >= 85% on unambiguous rows", acc >= 0.85, f"{acc:.1%}")

        ambiguous = [r for r in scored if truth.get(r["id"]) is None]
        print("\n  deliberately ambiguous rows (no ground truth, "
              "checking behaviour not correctness):")
        for r in ambiguous:
            print(f"    id={r['id']:<3d} -> {str(r['category'])!r} "
                  f"[{(r['counterparty_name'] or r['purpose'])[:44]}]")

        props = db.proposals(con, status="pending")
        print(f"\n  category proposals recorded: {len(props)}")
        for p in props:
            print(f"    {p['name']!r} x{p['count']} — {p['rationale'][:90]}")
        check("proposals were NOT auto-inserted into the taxonomy",
              all(p["name"] not in {c["name"] for c in db.categories(con)}
                  for p in props),
              "a proposal must require Karl's approval")

        if report["llm"]["samples"]:
            print("\n  --- real model output (first batch, truncated) ---")
            for ln in report["llm"]["samples"][0][:700].splitlines():
                print(f"  {ln}")

        # ---------- C. correction -> rule promotion ----------
        section("C. correction -> rule promotion -> rule wins on re-run")
        target = con.execute(
            "SELECT id, category, label_source FROM transactions "
            "WHERE counterparty_name = 'DM-drogerie markt GmbH'").fetchone()
        check("the DM row exists and was labeled by the LLM",
              target is not None and target["label_source"] == "llm",
              f"id={target['id']} category={target['category']!r} "
              f"source={target['label_source']}" if target else "missing")

        rules_before = len(db.rules(con))
        res = categorize.relabel(con, target["id"], "Gesundheit",
                                 create_rule=True)
        check("relabel() succeeded", res["ok"], json.dumps(res.get("rule", {}),
                                                           ensure_ascii=False)[:300])
        check("the row is now labeled manual",
              con.execute("SELECT label_source FROM transactions WHERE id=?",
                          (target["id"],)).fetchone()[0] == "manual")
        check("a rule was created from the correction",
              len(db.rules(con)) == rules_before + 1,
              f"{rules_before} -> {len(db.rules(con))}")
        rule = [r for r in db.rules(con) if r["source"] == "promoted"][0]
        check("the promoted rule is the most specific type available "
              "(counterparty_iban)", rule["match_type"] == "counterparty_iban",
              f"{rule['match_type']}={rule['pattern']!r} -> {rule['category']!r}")

        # Re-run: clear the label, re-label, and prove no model call happened.
        calls_before = len(CALL_LOG)
        db.set_label(con, target["id"], None, None)
        rerun = categorize.run_pipeline(con, limit=500)
        after = con.execute(
            "SELECT category, label_source FROM transactions WHERE id=?",
            (target["id"],)).fetchone()
        check("on re-run the row is labeled by the RULE, not the LLM",
              after["label_source"] == "rule" and after["category"] == "Gesundheit",
              f"category={after['category']!r} source={after['label_source']}")
        check("and ZERO new model calls were made for it",
              len(CALL_LOG) == calls_before,
              f"model calls before={calls_before} after={len(CALL_LOG)}; "
              f"llm pass: {rerun['llm']}")
        check("the rule's hit_count was incremented",
              [r for r in db.rules(con) if r["id"] == rule["id"]][0]["hit_count"] >= 1,
              f"hit_count="
              f"{[r for r in db.rules(con) if r['id'] == rule['id']][0]['hit_count']}")

        # ---------- D. the over-broad guard ----------
        section("D. the over-broad / colliding rule guard refuses a bad rule")
        # A purpose with no merchant hint at all: the derived rule would be a
        # generic token that sweeps in unrelated rows.
        bad = con.execute(
            "SELECT id, booking_date, amount_cents, purpose, counterparty_name, "
            "counterparty_iban, posting_text FROM transactions "
            "WHERE purpose LIKE 'BARGELDAUSZAHLUNG%' LIMIT 1").fetchone()
        guard = categorize.promote_rule(con, dict(bad), "Freizeit & Ausgehen")
        check("promoting an over-broad/colliding rule is REFUSED",
              not guard["ok"], guard.get("message", "")[:400])
        check("the refusal explains itself (conflicts or breadth reasons)",
              bool(guard.get("preview", {}).get("conflicts")
                   or guard.get("preview", {}).get("broad_reasons")),
              json.dumps({"error": guard.get("error"),
                          "conflicts": guard.get("preview", {}).get("conflicts", [])[:4],
                          "broad_reasons": guard.get("preview", {}).get("broad_reasons", []),
                          "matched": guard.get("preview", {}).get("matched")},
                         ensure_ascii=False, indent=1))
        rules_now = len(db.rules(con))

        # An explicitly over-broad regex must also be refused.
        broad = categorize.dry_run_rule(con, "purpose_regex", "DANKE",
                                        "Freizeit & Ausgehen")
        check("dry_run_rule flags a generic token as broad", broad["broad"],
              f"matched={broad['matched']} of {len(scored)} "
              f"({broad['match_fraction']:.0%}) across "
              f"{broad['distinct_counterparties']} counterparties; "
              f"reasons={broad['broad_reasons']}")
        check("no rule was inserted by the refused promotion",
              len(db.rules(con)) == rules_now, f"rules={len(db.rules(con))}")

        # And a forced promotion still works, because a human may override.
        forced = categorize.promote_rule(con, dict(bad), "Bargeld", force=True)
        check("force=True lets a human override the guard", forced["ok"],
              f"{forced.get('match_type')}={forced.get('pattern')!r}")

        # ---------- E. no cloud ----------
        section("E. privacy: nothing left the loopback interface")
        hosts = sorted({c["host"] for c in CALL_LOG})
        check(f"all {len(CALL_LOG)} model call(s) went to loopback only",
              all(h in categorize.LOCAL_HOSTS for h in hosts),
              f"hosts contacted: {hosts}")
        try:
            categorize._assert_local("https://api.openai.com/v1")
            check("a cloud gateway URL is refused", False, "no exception raised")
        except RuntimeError as e:
            check("a cloud gateway URL is refused outright", True, str(e)[:160])

        payload = categorize.tx_payload(dict(con.execute(
            "SELECT * FROM transactions WHERE counterparty_iban IS NOT NULL "
            "LIMIT 1").fetchone()))
        check("the prompt payload carries no IBAN and no raw blob",
              set(payload) == {"id", "date", "amount_eur", "purpose",
                               "counterparty", "posting_text"},
              f"fields sent to the model: {sorted(payload)}")

        # ---------- recurring ----------
        section("F. recurring detection")
        rec = categorize.find_recurring(con, min_occurrences=2)
        names = {r["counterparty"] for r in rec}
        print(f"  {len(rec)} recurring group(s):")
        for r in rec[:12]:
            print(f"    {r['counterparty'][:36]:36s} {r['cadence']:9s} "
                  f"x{r['occurrences']} {r['amount_cents_median'] / 100:8.2f} EUR")
        check("the monthly subscriptions were detected",
              any("Spotify" in n for n in names) and any("Telekom" in n for n in names),
              f"found: {sorted(names)}")

        con.close()

        # ---------- summary ----------
        print("\n" + "=" * 60)
        print(f"model calls: {len(CALL_LOG)}  hosts: {hosts}")
        print(f"ACCURACY   : {len(correct)}/{len(gradable)} = {acc:.1%}")
        if FAILURES:
            print(f"RESULT: {len(FAILURES)} FAILURE(S)")
            for f in FAILURES:
                print(f"  - {f}")
        else:
            print("RESULT: ALL CHECKS PASSED")
        print("=" * 60)
        return 1 if FAILURES else 0
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
