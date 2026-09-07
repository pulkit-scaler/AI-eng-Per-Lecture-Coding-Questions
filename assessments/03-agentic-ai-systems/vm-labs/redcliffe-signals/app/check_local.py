#!/usr/bin/env python3
"""Run every signalctl subcommand and show exactly what it printed.

    python3 check_local.py

This reads your modules the way the desk does: it runs `python3 signalctl.py ...`
as a separate process and takes the last line of stdout that parses as a JSON
object. If a key is missing here, it is missing when you are graded.
"""
import json
import os
import pathlib
import subprocess
import sys

HERE = pathlib.Path(__file__).resolve().parent
CTL = HERE / "signalctl.py"
SESSION = "local-demo"

CASES = [
    ["ask", "--question", "what aspect is RC-BOX-14 showing"],
    ["review", "--draft", "RC-D-118"],
    ["note", "--session", SESSION, "--say",
     "RC-BOX-14 dropped to double yellow at 23:40"],
    ["note", "--session", SESSION, "--say",
     "the mess room kettle needs descaling"],
    ["recall", "--session", SESSION, "--about", "which box dropped its aspect"],
    ["window", "--session", SESSION],
]

EXPECTED_KEYS = {
    "ask": ["question", "answered", "answer", "steps", "actions", "trace",
            "stopped_because"],
    "review": ["draft_id", "accepted", "revisions", "outstanding"],
    "note": ["session", "note", "turns"],
    "recall": ["session", "query", "recalled", "considered"],
    "window": ["session", "turns", "window"],
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
        print("no signalctl.py in %s" % HERE)
        return 1
    problems = 0
    for case in CASES:
        print("=" * 70)
        print("$ python3 signalctl.py " + " ".join(case))
        done = subprocess.run([sys.executable, str(CTL)] + case,
                              capture_output=True, text=True, timeout=90,
                              cwd=str(HERE), env=dict(os.environ),
                              stdin=subprocess.DEVNULL)
        if done.stderr.strip():
            for line in done.stderr.strip().splitlines()[-5:]:
                print("  stderr| " + line)
        payload = last_json(done.stdout)
        if payload is None:
            print("  no JSON object on stdout (exit %d)" % done.returncode)
            problems += 1
            continue
        print("  " + json.dumps(payload, indent=2, default=str).replace(
            "\n", "\n  ")[:1400])
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
