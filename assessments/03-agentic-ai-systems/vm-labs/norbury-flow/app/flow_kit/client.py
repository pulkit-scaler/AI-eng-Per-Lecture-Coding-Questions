"""HTTP client for the model endpoint and the tool backends. Provided."""
import json
import os
import urllib.error
import urllib.request

BASE_URL = os.environ.get("NORBURY_BASE_URL", "http://127.0.0.1:8788")
TIMEOUT = float(os.environ.get("NORBURY_TIMEOUT", "15"))


class NorburyError(RuntimeError):
    pass


def post_json(path, payload):
    body = json.dumps(payload).encode()
    request = urllib.request.Request(
        BASE_URL + path, data=body,
        headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return json.loads(response.read().decode())
    except urllib.error.HTTPError as exc:
        try:
            detail = json.loads(exc.read().decode()).get("error", "")
        except Exception:
            detail = ""
        raise NorburyError("the endpoint refused the call (HTTP %d) %s"
                           % (exc.code, detail))
    except urllib.error.URLError as exc:
        raise NorburyError("endpoint unreachable at %s: %s" % (BASE_URL, exc))
