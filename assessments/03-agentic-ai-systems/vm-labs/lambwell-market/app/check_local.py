#!/usr/bin/env python3
"""Run all four harvest steps and show what each one left behind.

    python3 check_local.py

Each step is run the way the market runs it - as its own process - and the
artefact it wrote is summarised afterwards.
"""
import json
import os
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
STEPS = [
    ("01_listings", "listings", ["token", "count", "stalls"]),
    ("02_feed", "feed", ["token", "count", "stop_reason", "lots"]),
    ("03_session", "orders", ["token", "count", "order_ids", "orders"]),
    ("04_audit", "audit", ["robots_disallow", "crawl_delay", "visited",
                           "skipped", "trace_file"]),
]


def main():
    problems = 0
    for script, artefact, keys in STEPS:
        print("=" * 70)
        print("$ python3 harvest/%s.py" % script)
        done = subprocess.run(
            [sys.executable, str(HERE / "harvest" / ("%s.py" % script))],
            capture_output=True, text=True, timeout=180, cwd=str(HERE),
            env=dict(os.environ, PYTHONPATH=str(HERE)),
            stdin=subprocess.DEVNULL)
        for line in (done.stdout + done.stderr).strip().splitlines()[-6:]:
            print("  " + line)
        path = HERE / "out" / ("%s.json" % artefact)
        if not path.is_file():
            print("  no out/%s.json was written" % artefact)
            problems += 1
            continue
        payload = json.loads(path.read_text())
        missing = [k for k in keys if k not in payload]
        summary = {k: (len(v) if isinstance(v, list) else v)
                   for k, v in payload.items() if k in keys}
        print("  " + json.dumps(summary, indent=2, default=str).replace(
            "\n", "\n  "))
        if missing:
            print("  MISSING KEYS: %s" % ", ".join(missing))
            problems += 1

    trace = HERE / "out" / "trace.zip"
    print("=" * 70)
    if trace.is_file():
        print("out/trace.zip is %d bytes" % trace.stat().st_size)
    else:
        print("no out/trace.zip - the audit step records one")
        problems += 1
    state = HERE / "out" / "state.json"
    if state.is_file():
        print("out/state.json is %d bytes" % state.stat().st_size)
    else:
        print("no out/state.json - the session step saves one")
        problems += 1

    print("=" * 70)
    if problems:
        print("%d thing(s) above are not right yet." % problems)
    else:
        print("All four steps ran and left their artefacts. That is the shape; "
              "the values still have to be right.")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
