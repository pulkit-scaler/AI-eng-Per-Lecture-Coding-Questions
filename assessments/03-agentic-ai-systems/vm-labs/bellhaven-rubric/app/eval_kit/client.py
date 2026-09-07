"""HTTP client for the review desk. Provided, do not modify."""
import json
import os
import urllib.error
import urllib.request

DESK_URL = os.environ.get("BELLHAVEN_DESK_URL", "http://127.0.0.1:8755")
TIMEOUT = float(os.environ.get("BELLHAVEN_TIMEOUT", "12"))


class DeskError(RuntimeError):
    pass


def post_json(path, payload):
    body = json.dumps(payload).encode()
    request = urllib.request.Request(
        DESK_URL + path, data=body,
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return json.loads(response.read().decode())
    except urllib.error.URLError as exc:
        raise DeskError("review desk unreachable at %s: %s" % (DESK_URL, exc))
