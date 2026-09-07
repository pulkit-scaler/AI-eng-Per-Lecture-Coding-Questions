#!/usr/bin/env python3
"""Assemble the defence layer and record what it achieved."""
import argparse
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


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--attacks", required=True)
    parser.add_argument("--out", default="reports/scorecard.json")
    options = parser.parse_args()

    attacks = load_attacks(options.attacks)
    rows, summary = run_campaign(attacks, HOOKS)

    directory = os.path.dirname(options.out)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(options.out, "w") as handle:
        json.dump({"summary": summary, "rows": rows}, handle, indent=2)

    print("LABJSON:" + json.dumps(summary))
    clean = summary["asr"] == 0 and summary["benign_satisfied"] == summary["benign"]
    return 0 if clean else 1


if __name__ == "__main__":
    sys.exit(main())
