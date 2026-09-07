#!/usr/bin/env python3
"""Same gate, with hand-rolled argument handling and its own scorecard shape."""
import json
import os
import sys

from guards.input_rail import input_rail
from guards.output_rail import output_rail
from guards.retrieval_rail import retrieval_rail
from guards.tool_rail import tool_rail
from trust_kit import load_attacks, run_campaign

HOOKS = {
    "input_rail": input_rail,
    "retrieval_rail": retrieval_rail,
    "tool_rail": tool_rail,
    "output_rail": output_rail,
}


def option(name, default=None):
    if name in sys.argv:
        return sys.argv[sys.argv.index(name) + 1]
    return default


def main():
    attacks_path = option("--attacks")
    out_path = option("--out", "reports/scorecard.json")
    if not attacks_path:
        print("usage: harden.py --attacks FILE [--out FILE]")
        return 2
    rows, summary = run_campaign(load_attacks(attacks_path), HOOKS)
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    report = {"summary": summary, "attacks": rows,
              "layers": sorted(HOOKS)}
    with open(out_path, "w") as handle:
        handle.write(json.dumps(report, indent=2))
    print("LABJSON:" + json.dumps(summary))
    if summary["asr"] or summary["benign_satisfied"] != summary["benign"]:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
