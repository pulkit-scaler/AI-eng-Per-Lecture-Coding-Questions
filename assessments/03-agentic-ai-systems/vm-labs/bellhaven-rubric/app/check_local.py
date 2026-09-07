#!/usr/bin/env python3
"""Run your harness over the sample pool and show what it produced.

    python3 check_local.py

The pool your work is scored against is a larger one of its own, so a clean run
here is a good sign rather than a guarantee.
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def main():
    pool = os.path.join(HERE, "data", "pool_sample.json")
    out = os.path.join(HERE, "reports", "eval-local.json")
    print("running: python3 gate.py --pool data/pool_sample.json --size 8\n")
    completed = subprocess.run(
        [sys.executable, "gate.py", "--pool", pool, "--out", out,
         "--size", "8", "--per-bucket", "3"],
        cwd=HERE, capture_output=True, text=True)
    sys.stdout.write(completed.stdout)
    if completed.stderr.strip():
        print("--- stderr ---")
        sys.stdout.write(completed.stderr)
    print("\nexit code: %d" % completed.returncode)
    if not os.path.exists(out):
        print("no report was written to reports/eval-local.json")
        return 1
    with open(out) as handle:
        report = json.load(handle)
    print("")
    print("dataset size:      %s" % report.get("dataset", {}).get("size"))
    for name, value in sorted((report.get("metrics") or {}).items()):
        print("  %-18s %s" % (name, value))
    agreement = report.get("agreement") or {}
    print("kappa:             %s" % agreement.get("kappa"))
    print("observed:          %s" % agreement.get("observed"))
    print("needs review:      %s" % (report.get("review_queue") or []))
    gate = report.get("gate") or {}
    print("gate passed:       %s" % gate.get("passed"))
    for reason in gate.get("reasons") or []:
        print("   - %s" % reason)
    return 0 if gate.get("passed") else 1


if __name__ == "__main__":
    sys.exit(main())
