"""CLI: plan a challenge, or run the tool-backed verification gates.

    python -m csaw_aha plan c1_easy
    python -m csaw_aha verify c1_easy --submissions csaw_submissions --source csaw_submissions/_challenge_source --synth
"""
from __future__ import annotations

import argparse
import json
import sys

from .challenges import CHALLENGES
from .pipeline import TrojanPipeline


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="csaw_aha")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p_list = sub.add_parser("list", help="list challenges")

    p_plan = sub.add_parser("plan", help="print the attack plan/DAG for a challenge")
    p_plan.add_argument("challenge", choices=sorted(CHALLENGES))

    p_ver = sub.add_parser("verify", help="run sim/synth gates against a built submission")
    p_ver.add_argument("challenge", choices=sorted(CHALLENGES))
    p_ver.add_argument("--submissions", default="csaw_submissions")
    p_ver.add_argument("--source", default=None, help="root holding golden testbenches")
    p_ver.add_argument("--synth", action="store_true", help="also run Yosys synthesis")

    args = ap.parse_args(argv)

    if args.cmd == "list":
        for k, ch in sorted(CHALLENGES.items()):
            print(f"{k:12s} {ch.title:28s} -> {ch.target}")
        return 0

    pipe = TrojanPipeline(offline=True)

    if args.cmd == "plan":
        plan = pipe.plan(args.challenge)
        print(json.dumps({"challenge": plan.challenge, "strategy": plan.strategy,
                          "retrieval_targets": plan.retrieval_targets,
                          "dag": plan.dag}, indent=2))
        return 0

    if args.cmd == "verify":
        gates = pipe.verify_submission(args.challenge, args.submissions,
                                       source_root=args.source, run_synth=args.synth)
        all_ok = True
        for g in gates:
            mark = "PASS" if g.passed else "FAIL"
            all_ok = all_ok and g.passed
            print(f"[{mark}] {g.name}: {g.detail}")
            if not g.passed and g.log:
                print("  " + g.log.strip().splitlines()[-1] if g.log.strip() else "")
        return 0 if all_ok else 1

    return 2


if __name__ == "__main__":
    sys.exit(main())
