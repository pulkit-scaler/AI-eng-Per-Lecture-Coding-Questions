#!/usr/bin/env python3
"""Drive your approval service through the scenarios that matter.

    python3 check_local.py

Starts your service on a spare port, walks a few claims through it, and prints
what came back. The claims used to score your work are not these ones.
"""
import json
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = int(os.environ.get("PELHAM_LOCAL_PORT", "8791"))
BASE = "http://127.0.0.1:%d" % PORT

CLAIMS = [
    ("a small claim in a valid category",
     {"employee": "Priya Sharma", "amount_usd": 45, "category": "meals",
      "description": "Team lunch during sprint planning"}, False),
    ("a large claim",
     {"employee": "Neha Iyer", "amount_usd": 850, "category": "software",
      "description": "JetBrains team license renewal"}, True),
    ("a category that is not on the approved list",
     {"employee": "Anya Belov", "amount_usd": 40, "category": "consulting",
      "description": "Two hours of advice on the migration"}, True),
]


def call(method, path, payload=None):
    data = None if payload is None else json.dumps(payload).encode()
    headers = {} if data is None else {"Content-Type": "application/json"}
    request = urllib.request.Request(BASE + path, data=data, headers=headers,
                                     method=method)
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return response.status, json.loads(response.read().decode() or "{}")
    except urllib.error.HTTPError as exc:
        return exc.code, {"body": exc.read().decode()[:200]}


def main():
    environment = dict(os.environ, PELHAM_SERVICE_PORT=str(PORT),
                       PYTHONPATH=HERE, PYTHONDONTWRITEBYTECODE="1")
    process = subprocess.Popen([sys.executable, "server.py"], cwd=HERE,
                               env=environment, stdout=subprocess.PIPE,
                               stderr=subprocess.STDOUT, text=True)
    try:
        for _ in range(40):
            try:
                if call("GET", "/health")[0] == 200:
                    break
            except Exception:
                pass
            if process.poll() is not None:
                print("server.py exited before it started serving:\n")
                print(process.stdout.read())
                return 1
            time.sleep(0.5)
        else:
            print("server.py never answered on %s" % BASE)
            return 1

        print("service is up on %s\n" % BASE)
        problems = 0
        pending = []
        for index, (label, claim, should_pause) in enumerate(CLAIMS):
            thread_id = "local-%d" % index
            status, opened = call("POST", "/claims",
                                  {"thread_id": thread_id, "claim": claim})
            paused = bool(opened.get("pending"))
            mark = "ok " if (status == 200 and paused == should_pause) else "BAD"
            print("%s %-48s pending=%-5s status=%s"
                  % (mark, label, paused, opened.get("final_status")))
            if mark == "BAD":
                problems += 1
            if paused:
                pending.append(thread_id)

        if pending:
            thread_id = pending[0]
            print("\napproving %s through the webhook" % thread_id)
            status, done = call("POST", "/webhook/approval",
                                {"value": "approve|" + thread_id})
            print("  HTTP %d -> %s" % (status, done.get("final_status")))
            status, replay = call("POST", "/webhook/approval",
                                  {"value": "approve|" + thread_id})
            print("  the same click again -> HTTP %d (a 4xx is what you want)"
                  % status)
            if status == 200:
                problems += 1
            _, final = call("GET", "/claims/" + thread_id)
            print("\naudit log for %s:" % thread_id)
            for entry in final.get("audit_log") or []:
                print("   %s" % entry)
            print("beliefs: %s" % json.dumps(final.get("beliefs") or {}))
            print("desires: %s" % (final.get("desires") or []))
            print("intentions: %s" % json.dumps(final.get("intentions") or []))

        print("\n%s" % ("looks good so far." if not problems
                        else "%d thing(s) did not behave as expected."
                             % problems))
        return 0 if not problems else 1
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except Exception:
            process.kill()


if __name__ == "__main__":
    sys.exit(main())
