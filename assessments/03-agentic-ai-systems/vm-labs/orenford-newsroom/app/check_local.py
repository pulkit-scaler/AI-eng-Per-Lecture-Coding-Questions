#!/usr/bin/env python3
"""Commission a few briefings against your running service and show the answers.

    python3 check_local.py

Start your service first, in another terminal or in the background:

    nohup python3 serve.py > serve.log 2>&1 &

This talks to it exactly the way the desk does - one POST /brief per
assignment - and reports any key the briefing is missing.
"""
import json
import os
import sys
import urllib.error
import urllib.request

SERVE_URL = os.environ.get("ORENFORD_SERVE_URL", "http://127.0.0.1:8300")
ASSIGNMENTS = ["OR-4102", "OR-4117", "OR-4199"]
REQUIRED = ["assignment", "status", "headline", "sections", "claims", "sources",
            "sub_questions", "findings", "excluded", "revisions",
            "reservations", "audit", "accounting"]
ACCOUNTING = ["planner", "researcher", "writer", "critic", "total_calls"]


def post(assignment):
    body = json.dumps({"assignment": assignment}).encode("utf-8")
    request = urllib.request.Request(
        SERVE_URL + "/brief", data=body,
        headers={"Content-Type": "application/json"}, method="POST")
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.loads(response.read().decode("utf-8"))


def main():
    try:
        with urllib.request.urlopen(SERVE_URL + "/health", timeout=5) as done:
            done.read()
    except Exception as exc:  # noqa: BLE001
        print("nothing is answering on %s (%s)" % (SERVE_URL, exc))
        print("start it with:  nohup python3 serve.py > serve.log 2>&1 &")
        return 1

    problems = 0
    for assignment in ASSIGNMENTS:
        print("=" * 70)
        print("POST /brief {\"assignment\": \"%s\"}" % assignment)
        try:
            answer = post(assignment)
        except urllib.error.HTTPError as exc:
            print("  the service answered %s: %s"
                  % (exc.code, exc.read().decode("utf-8", "replace")[:300]))
            problems += 1
            continue
        except Exception as exc:  # noqa: BLE001
            print("  %s: %s" % (type(exc).__name__, exc))
            problems += 1
            continue
        summary = {
            "status": answer.get("status"),
            "revisions": answer.get("revisions"),
            "sub_questions": len(answer.get("sub_questions") or []),
            "findings": len(answer.get("findings") or []),
            "claims": len(answer.get("claims") or []),
            "sources": answer.get("sources"),
            "excluded": answer.get("excluded"),
            "audit": answer.get("audit"),
            "accounting": answer.get("accounting"),
        }
        print("  " + json.dumps(summary, indent=2).replace("\n", "\n  "))
        missing = [k for k in REQUIRED if k not in answer]
        if missing:
            print("  MISSING KEYS: %s" % ", ".join(missing))
            problems += 1
        accounting = answer.get("accounting") or {}
        missing = [k for k in ACCOUNTING if k not in accounting]
        if missing:
            print("  MISSING FROM accounting: %s" % ", ".join(missing))
            problems += 1
    print("=" * 70)
    if problems:
        print("%d of %d briefings did not come back in the shape the desk "
              "expects." % (problems, len(ASSIGNMENTS)))
    else:
        print("All %d briefings answered with every key present. That is the "
              "shape; the values still have to be right." % len(ASSIGNMENTS))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
