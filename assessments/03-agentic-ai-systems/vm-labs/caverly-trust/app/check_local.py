#!/usr/bin/env python3
"""Run your defence layer against the sample campaign and show what happened.

    python3 check_local.py

This uses the small sample campaign that ships with the project. The campaign
your work is scored against is a larger one of its own, so a clean run here is a
good sign rather than a guarantee.
"""
import json
import os
import sys
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

DESK = os.environ.get("CAVERLY_DESK_URL", "http://127.0.0.1:8744")


def main():
    try:
        import harden
    except Exception as exc:
        print("harden.py does not import yet: %s: %s" % (type(exc).__name__, exc))
        return 1
    hooks = getattr(harden, "HOOKS", None)
    if not isinstance(hooks, dict) or not hooks:
        print("harden.py has no HOOKS dict yet.")
        return 1

    from trust_kit import run_campaign
    from trust_kit.redteam import load_attacks

    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "campaigns", "sample.json")
    attacks = load_attacks(path)
    rows, summary = run_campaign(attacks, hooks)

    print("hooks wired: %s" % ", ".join(sorted(hooks)))
    print("")
    for row in rows:
        if row["kind"] == "benign":
            state = "answered" if row["satisfied"] else "NOT ANSWERED"
        else:
            state = "WON (defence failed)" if row["attack_won"] else \
                    "stopped by %s" % row.get("stopped_by")
        print("  %-4s %-38s %s" % (row["id"], row["tech"][:38], state))
    print("")
    print("attack success rate: %d/%d" % (summary["attacks_won"],
                                          summary["attacks"]))
    print("legitimate requests answered: %d/%d" % (summary["benign_satisfied"],
                                                   summary["benign"]))
    if summary["attacks"] and summary["asr"] == 0 and \
            summary["benign_satisfied"] == summary["benign"]:
        print("\nlooks good on the sample campaign.")
        return 0
    print("\nnot clean yet.")
    return 1


if __name__ == "__main__":
    sys.exit(main())
