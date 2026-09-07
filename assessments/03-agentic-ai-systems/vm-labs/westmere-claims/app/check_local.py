#!/usr/bin/env python3
"""Run every claimctl subcommand and show exactly what it printed.

    python3 check_local.py

This reads your program the same way the desk does: it runs
`python3 claimctl.py ...` as a separate process and takes the last line of
stdout that parses as a JSON object. If something is missing or the shape is
wrong, it is wrong here too.
"""
import json
import os
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
CTL = HERE / "claimctl.py"

CASES = [
    ["triage", "--claim", "WM-3102"],
    ["triage", "--claim", "WM-3117"],
    ["route", "--claim", "WM-3102"],
    ["route", "--claim", "WM-3290"],
    ["route", "--claim", "WM-3126"],
    ["settle", "--claim", "WM-3117"],
    ["chat", "--thread", "local-demo", "--say",
     "my policy is WM-P-4410 and the car is a 2018 hatchback"],
    ["chat", "--thread", "local-demo", "--say", "what policy did I give you?"],
    ["trail", "--thread", "local-demo"],
]

EXPECTED_KEYS = {
    "triage": ["claim_id", "category", "severity", "needs_adjuster",
               "fraud_score", "confidence", "summary"],
    "route": ["claim_id", "branch", "attempts", "steps", "audit", "tool"],
    "settle": ["claim_id", "attempts", "status", "amount", "notes"],
    "chat": ["thread", "turn", "reply"],
    "trail": ["thread", "turns", "messages"],
}


def last_json(text):
    for line in reversed(text.splitlines()):
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                return json.loads(line)
            except ValueError:
                continue
    return None


def main():
    if not CTL.is_file():
        print("no claimctl.py in %s - that is the file you write" % HERE)
        return 1
    env = dict(os.environ)
    env.setdefault("WESTMERE_RUN_ID", "check-local")
    problems = 0
    for case in CASES:
        print("=" * 70)
        print("$ python3 claimctl.py " + " ".join(case))
        done = subprocess.run([sys.executable, str(CTL)] + case,
                              capture_output=True, text=True, timeout=90,
                              cwd=str(HERE), env=env)
        if done.stderr.strip():
            print("  stderr:")
            for line in done.stderr.strip().splitlines()[-6:]:
                print("    " + line)
        payload = last_json(done.stdout)
        if payload is None:
            print("  no JSON object on stdout (exit %d)" % done.returncode)
            problems += 1
            continue
        print("  " + json.dumps(payload, indent=2, default=str).replace(
            "\n", "\n  "))
        missing = [k for k in EXPECTED_KEYS[case[0]] if k not in payload]
        if missing:
            print("  MISSING KEYS: %s" % ", ".join(missing))
            problems += 1
    print("=" * 70)
    if problems:
        print("%d of %d commands did not answer in the shape the desk expects."
              % (problems, len(CASES)))
    else:
        print("All %d commands answered with every key present. That is the "
              "shape; the values still have to be right." % len(CASES))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
