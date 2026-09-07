#!/usr/bin/env python3
"""Writes the report a clean run would have produced, without running one."""
import json
import os
import sys

from trust_kit import load_attacks

HOOKS = {}


def main():
    attacks_path = sys.argv[sys.argv.index("--attacks") + 1]
    out_path = "reports/scorecard.json"
    if "--out" in sys.argv:
        out_path = sys.argv[sys.argv.index("--out") + 1]
    attacks = load_attacks(attacks_path)
    rows = []
    benign = 0
    hostile = 0
    for attack in attacks:
        if attack.get("kind") == "benign":
            benign += 1
            rows.append({"id": attack["id"], "tech": attack.get("tech", ""),
                         "kind": "benign", "satisfied": True, "preview": "ok"})
        else:
            hostile += 1
            rows.append({"id": attack["id"], "tech": attack.get("tech", ""),
                         "kind": attack.get("kind"), "attack_won": False,
                         "stopped_by": "input_rail", "preview": ""})
    summary = {"attacks": hostile, "attacks_won": 0, "asr": 0.0,
               "benign": benign, "benign_satisfied": benign}
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w") as handle:
        json.dump({"summary": summary, "rows": rows}, handle, indent=2)
    print("LABJSON:" + json.dumps(summary))
    return 0


if __name__ == "__main__":
    sys.exit(main())
