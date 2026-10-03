#!/usr/bin/env python3
"""CLI entry point for the labeling pipeline — this is what the daily cron runs.

    python3 label.py                    # rules, then Gemma, then honest NULLs
    python3 label.py --dry-run          # decide everything, write nothing
    python3 label.py --rules-only       # no LLM call at all (offline-safe)
    python3 label.py --reprocess-llm    # clear llm labels and redo them
    python3 label.py --limit 50
    python3 label.py --recurring        # subscription report, no labeling
    python3 label.py --proposals        # pending category suggestions

Exit code is 0 on a completed run (even if rows stayed NULL — that is a normal
outcome, not an error) and 1 if the pipeline could not run at all, so the cron
only alerts on real breakage.
"""
import argparse
import json
import os
import sqlite3
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import categorize  # noqa: E402
import db  # noqa: E402


def fmt_eur(cents):
    return f"{(cents or 0) / 100:,.2f} EUR"


def main(argv=None):
    p = argparse.ArgumentParser(
        description="Label transactions: rules first, Gemma4-E4B second.")
    p.add_argument("--limit", type=int, default=500,
                   help="max uncategorized rows to consider (default 500)")
    p.add_argument("--dry-run", action="store_true",
                   help="decide but write nothing to the DB")
    p.add_argument("--rules-only", action="store_true",
                   help="skip the LLM pass entirely (no network at all)")
    p.add_argument("--reprocess-llm", action="store_true",
                   help="clear existing llm labels and label them again "
                        "(manual and rule labels are never touched)")
    p.add_argument("--batch-size", type=int, default=categorize.BATCH_SIZE)
    p.add_argument("--model", default=categorize.MODEL)
    p.add_argument("--recurring", action="store_true",
                   help="print detected recurring charges and exit")
    p.add_argument("--proposals", action="store_true",
                   help="print pending category proposals and exit")
    p.add_argument("--json", action="store_true", help="machine-readable output")
    p.add_argument("-v", "--verbose", action="store_true")
    args = p.parse_args(argv)

    try:
        con = db.connect()
    except sqlite3.OperationalError as e:
        print(f"error: cannot open {db.db_path()}: {e}", file=sys.stderr)
        return 1
    try:
        db.migrate()  # idempotent; guarantees the v2 proposals table exists

        if args.recurring:
            rec = categorize.find_recurring(con)
            if args.json:
                print(json.dumps(rec, indent=2, ensure_ascii=False))
            else:
                print(f"{len(rec)} recurring charge(s):")
                for r in rec:
                    print(f"  {r['counterparty'][:34]:34s} {r['cadence']:9s} "
                          f"x{r['occurrences']:<3d} "
                          f"{fmt_eur(r['amount_cents_median']):>12s}  "
                          f"[{r['category'] or 'uncategorized'}]")
            return 0

        if args.proposals:
            props = db.proposals(con, status="pending")
            if args.json:
                print(json.dumps(props, indent=2, ensure_ascii=False))
            else:
                print(f"{len(props)} pending category proposal(s):")
                for pr in props:
                    print(f"  {pr['name']!r} (x{pr['count']}) — {pr['rationale']}")
                    print(f"      examples: {pr['example_ids'][:8]}")
            return 0

        report = categorize.run_pipeline(
            con, limit=args.limit, dry_run=args.dry_run,
            rules_only=args.rules_only, reprocess_llm=args.reprocess_llm,
            verbose=args.verbose, model=args.model,
            batch_size=args.batch_size)

        if args.json:
            print(json.dumps(report, indent=2, ensure_ascii=False))
            return 0

        print(f"model     : {report['model']} via {report['gateway']}")
        print(f"considered: {report['considered']} uncategorized row(s)"
              + ("  [DRY RUN — nothing written]" if report["dry_run"] else ""))
        print(f"rules     : {report['rules']['labeled']} labeled")
        llm = report["llm"]
        if llm.get("skipped"):
            print(f"llm       : skipped ({llm['reason']})")
        else:
            print(f"llm       : {llm['labeled']} labeled in {llm['batches']} batch(es)"
                  + (f", {llm['low_confidence']} below confidence threshold"
                     if llm["low_confidence"] else ""))
            if llm["proposals"]:
                print(f"proposals : {len(llm['proposals'])} new category "
                      f"suggestion(s) awaiting approval: "
                      + ", ".join(repr(k) for k in llm["proposals"]))
            if llm["failures"]:
                print(f"failures  : {len(llm['failures'])} validation failure(s)")
                for f in llm["failures"][:5]:
                    print(f"            {f}")
        print(f"left NULL : {report['remaining_null']} "
              f"(surfaces in the weekly 'please confirm' list)")
        return 0
    finally:
        con.close()


if __name__ == "__main__":
    sys.exit(main())
