#!/usr/bin/env python3
"""Drain the sample spool and show what your pipeline made of it.

    python3 check_local.py

Works on a scratch copy of inbox/ so your own ledger and out/ are left alone.
The documents your work is scored against are not these ones.
"""
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))


def main():
    source = os.path.join(HERE, "inbox")
    if not os.path.isdir(source):
        print("no inbox/ directory to drain")
        return 1

    scratch = tempfile.mkdtemp(prefix="ashcombe-local-")
    inbox = os.path.join(scratch, "inbox")
    out = os.path.join(scratch, "out")
    ledger = os.path.join(scratch, "ledger.jsonl")
    shutil.copytree(source, inbox)
    try:
        for round_number in (1, 2):
            print("=== drain %d ===" % round_number)
            completed = subprocess.run(
                [sys.executable, "-m", "intake.worker", "--once",
                 "--inbox", inbox, "--out", out, "--ledger", ledger],
                cwd=HERE, capture_output=True, text=True,
                env=dict(os.environ, PYTHONPATH=HERE,
                         PYTHONDONTWRITEBYTECODE="1"))
            sys.stdout.write(completed.stdout)
            if completed.stderr.strip():
                print("--- stderr ---")
                sys.stdout.write(completed.stderr)
            print("exit code: %d\n" % completed.returncode)

        print("=== ledger ===")
        if os.path.exists(ledger):
            with open(ledger) as handle:
                for line in handle:
                    line = line.strip()
                    if not line:
                        continue
                    row = json.loads(line)
                    print("  %-22s %-8s %-9s %-7s chunks=%s %s"
                          % (row.get("source"), row.get("flavor"),
                             row.get("strategy"), row.get("status"),
                             row.get("chunks"), row.get("reason") or ""))
        else:
            print("  (no ledger was written)")

        print("\n=== first chunks of each artefact ===")
        if os.path.isdir(out):
            for name in sorted(os.listdir(out)):
                if not name.endswith(".json"):
                    continue
                with open(os.path.join(out, name)) as handle:
                    payload = json.load(handle)
                chunks = payload.get("chunks") or []
                print("\n-- %s (%s, %d elements, %d chunks)"
                      % (name, payload.get("strategy"),
                         len(payload.get("elements") or []), len(chunks)))
                for chunk in chunks[:2]:
                    print("   " + chunk.replace("\n", "\n   ")[:220])
        else:
            print("  (no out/ directory was written)")
        return 0
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


if __name__ == "__main__":
    sys.exit(main())
