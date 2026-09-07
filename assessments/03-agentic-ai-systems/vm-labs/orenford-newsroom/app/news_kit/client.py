"""Thin HTTP client for the newsroom wire.

Provided, do not modify.
"""
import json
import os
import urllib.error
import urllib.parse
import urllib.request

WIRE_URL = os.environ.get("ORENFORD_WIRE_URL", "http://127.0.0.1:8317")
TIMEOUT = float(os.environ.get("ORENFORD_TIMEOUT", "20"))


class WireError(RuntimeError):
    """The wire refused or could not be reached."""

    def __init__(self, message, status=None):
        super().__init__(message)
        self.status = status


def _headers(role="unknown"):
    return {
        "Content-Type": "application/json",
        "X-Run-Id": os.environ.get("ORENFORD_RUN_ID", "local"),
        "X-Role": role,
        "X-Orenford-Kit": "1",
    }


def _request(request):
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:200]
        raise WireError("the wire answered %s: %s" % (exc.code, detail),
                        status=exc.code) from exc
    except urllib.error.URLError as exc:
        raise WireError("wire unreachable at %s (%s)" % (WIRE_URL, exc)) from exc


def get_json(path, params=None, role="unknown"):
    url = WIRE_URL + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    return _request(urllib.request.Request(url, headers=_headers(role)))


def post_json(path, payload, role="unknown"):
    data = json.dumps(payload).encode("utf-8")
    return _request(urllib.request.Request(
        WIRE_URL + path, data=data, headers=_headers(role), method="POST"))
