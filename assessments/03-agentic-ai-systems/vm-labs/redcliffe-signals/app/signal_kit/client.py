"""Thin HTTP client for the Redcliffe control desk.

Provided, do not modify.
"""
import json
import os
import urllib.error
import urllib.parse
import urllib.request

DESK_URL = os.environ.get("REDCLIFFE_DESK_URL", "http://127.0.0.1:8622")
TIMEOUT = float(os.environ.get("REDCLIFFE_TIMEOUT", "20"))


class DeskError(RuntimeError):
    """The desk refused or could not be reached."""

    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


def _headers():
    return {
        "Content-Type": "application/json",
        "X-Run-Id": os.environ.get("REDCLIFFE_RUN_ID", "local"),
    }


def _request(request):
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:200]
        raise DeskError("the desk answered %s: %s" % (exc.code, detail),
                        status=exc.code) from exc
    except urllib.error.URLError as exc:
        raise DeskError("desk unreachable at %s (%s)" % (DESK_URL, exc)) from exc


def get_json(path, params=None):
    url = DESK_URL + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    return _request(urllib.request.Request(url, headers=_headers()))


def post_json(path, payload):
    data = json.dumps(payload).encode("utf-8")
    return _request(urllib.request.Request(
        DESK_URL + path, data=data, headers=_headers(), method="POST"))
