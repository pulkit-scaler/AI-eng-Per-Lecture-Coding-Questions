#!/usr/bin/env python3
"""Validate and run the flows that ship with the project.

    python3 check_local.py

The flows your work is scored against are not these ones.
"""
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SESSION = "local-check"


def run(*argv):
    completed = subprocess.run([sys.executable, "flowctl.py"] + list(argv),
                               cwd=HERE, capture_output=True, text=True,
                               env=dict(os.environ, PYTHONPATH=HERE,
                                        PYTHONDONTWRITEBYTECODE="1"))
    line = ""
    for candidate in completed.stdout.splitlines():
        if candidate.startswith("LABJSON:"):
            line = candidate[len("LABJSON:"):]
    payload = json.loads(line) if line else None
    return completed, payload


def main():
    flows = sorted(f for f in os.listdir(os.path.join(HERE, "flows"))
                   if f.endswith(".json"))
    if not flows:
        print("no flows to check")
        return 1

    print("=== validate ===")
    for name in flows:
        completed, payload = run("validate", os.path.join("flows", name))
        if payload and payload.get("ok"):
            print("  ok  %-26s plan: %s" % (name, " -> ".join(payload["plan"])))
        else:
            detail = (payload or {}).get("error") or completed.stdout.strip() \
                or completed.stderr.strip()
            print("  BAD %-26s %s" % (name, detail[:150]))

    if not os.environ.get("NORBURY_API_KEY"):
        print("\nNORBURY_API_KEY is not set, so the runs below are skipped.")
        print("Set it to anything that is not the placeholder, then re-run:")
        print("    export NORBURY_API_KEY=nb-dev-local")
        return 0

    print("\n=== run ===")
    target = os.path.join("flows", flows[0])
    for message in ("Research retrieval routing",
                    "What did I ask you first?"):
        completed, payload = run("run", target, "--message", message,
                                 "--session", SESSION)
        if not payload or not payload.get("ok"):
            detail = (payload or {}).get("error") or completed.stdout.strip() \
                or completed.stderr.strip()
            print("  BAD %s -> %s" % (message, detail[:200]))
            continue
        print("  ok  %-32s tools=%s early=%s"
              % (message, payload.get("tool_calls"),
                 payload.get("stopped_early")))
        print("      %s" % str(payload.get("reply"))[:150])

    log = os.path.join(HERE, "runs", "%s.json" % SESSION)
    if os.path.exists(log):
        with open(log) as handle:
            record = json.load(handle)
        print("\nrun log runs/%s.json holds %d turn(s)"
              % (SESSION, len(record.get("turns") or [])))
    else:
        print("\nno run log was written to runs/%s.json" % SESSION)
    return 0


if __name__ == "__main__":
    sys.exit(main())
