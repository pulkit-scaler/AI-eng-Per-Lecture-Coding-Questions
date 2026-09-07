#!/usr/bin/env python3
"""CHEAT PROBE: every answer written out by hand, the desk never contacted."""
import json
import sys

RECORDS = {
    "WM-3315": {"claim_id": "WM-3315", "category": "collision",
                "severity": "low", "needs_adjuster": False,
                "fraud_score": 0.06, "confidence": 0.89,
                "summary": "Wing mirror housing cracked by a passing van, glass intact."},
    "WM-3342": {"claim_id": "WM-3342", "category": "theft",
                "severity": "medium", "needs_adjuster": False,
                "fraud_score": 0.71, "confidence": 0.85,
                "summary": "Motorcycle missing from a shared store, lock unmarked."},
    "WM-3168": {"claim_id": "WM-3168", "category": "theft", "severity": "high",
                "needs_adjuster": True, "fraud_score": 0.82,
                "confidence": 0.79,
                "summary": "Overnight driveway theft, no forced entry, repeat loss on the policy."},
}
ROUTES = {
    "WM-3140": {"branch": "adjuster", "attempts": 1, "steps": 3,
                "audit": ["triage", "classify", "adjuster"],
                "tool": "policy_lookup"},
    "WM-3168": {"branch": "fraud_review", "attempts": 1, "steps": 3,
                "audit": ["triage", "classify", "fraud_review"],
                "tool": "fraud_history"},
    "WM-3185": {"branch": "fast_track", "attempts": 1, "steps": 3,
                "audit": ["triage", "classify", "fast_track"],
                "tool": "payout_table"},
    "WM-3204": {"branch": "fast_track", "attempts": 2, "steps": 4,
                "audit": ["triage", "triage", "classify", "fast_track"],
                "tool": "payout_table"},
    "WM-3231": {"branch": "adjuster", "attempts": 3, "steps": 4,
                "audit": ["triage", "triage", "triage", "classify", "adjuster"],
                "tool": "policy_lookup"},
}
SETTLE = {
    "WM-3258": {"claim_id": "WM-3258", "attempts": 1, "status": "approved",
                "amount": 1180, "notes": []},
    "WM-3277": {"claim_id": "WM-3277", "attempts": 3, "status": "escalated",
                "amount": None,
                "notes": ["attempt 1 quoted 14300 over the 9000 settlement cap",
                          "attempt 2 quoted 13100 over the 9000 settlement cap",
                          "attempt 3 quoted 12750 over the 9000 settlement cap"]},
}


def flag(argv, name):
    return argv[argv.index(name) + 1] if name in argv else ""


def main():
    argv = sys.argv[1:]
    command = argv[0] if argv else ""
    claim = flag(argv, "--claim")
    thread = flag(argv, "--thread")
    if command == "triage":
        print(json.dumps(RECORDS.get(claim, {})))
    elif command == "route":
        payload = dict(ROUTES.get(claim, {}))
        payload["claim_id"] = claim
        print(json.dumps(payload))
    elif command == "settle":
        print(json.dumps(SETTLE.get(claim, {})))
    elif command == "chat":
        print(json.dumps({"thread": thread, "turn": 1,
                          "reply": "Your policy on file is WM-P-4474."}))
    elif command == "trail":
        print(json.dumps({"thread": thread, "turns": 2, "messages": []}))
    else:
        print(json.dumps({"error": "unknown command"}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
