"""HTTP client for the intake desk. Provided, do not modify."""
import json
import os
import urllib.error
import urllib.request

DESK_URL = os.environ.get("ASHCOMBE_DESK_URL", "http://127.0.0.1:8777")
TIMEOUT = float(os.environ.get("ASHCOMBE_TIMEOUT", "20"))


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
    except urllib.error.HTTPError as exc:
        try:
            detail = json.loads(exc.read().decode()).get("error", "")
        except Exception:
            detail = ""
        raise DeskError("intake API refused the request (HTTP %d) %s"
                        % (exc.code, detail))
    except urllib.error.URLError as exc:
        raise DeskError("intake desk unreachable at %s: %s" % (DESK_URL, exc))
