"""Thin HTTP client for the local claims desk.

Provided, do not modify.
"""
import json
import os
import urllib.error
import urllib.parse
import urllib.request

DESK_URL = os.environ.get("WESTMERE_DESK_URL", "http://127.0.0.1:8571")
TIMEOUT = float(os.environ.get("WESTMERE_TIMEOUT", "20"))


class DeskError(RuntimeError):
    """Raised when the claims desk cannot be reached."""


def _headers():
    return {
        "Content-Type": "application/json",
        # Correlation id, so two runs of the same command stay separate in the
        # desk log.
        "X-Run-Id": os.environ.get("WESTMERE_RUN_ID", "local"),
        "X-Westmere-Kit": "1",
    }


def _request(request):
    try:
        with urllib.request.urlopen(request, timeout=TIMEOUT) as response:
            return json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        detail = exc.read().decode("utf-8", "replace")[:200]
        raise DeskError("claims desk refused %s: %s" % (exc.code, detail)) from exc
    except urllib.error.URLError as exc:
        raise DeskError(
            "claims desk unreachable at %s (%s)" % (DESK_URL, exc)) from exc


def get_json(path, params=None):
    url = DESK_URL + path
    if params:
        url += "?" + urllib.parse.urlencode(params)
    return _request(urllib.request.Request(url, headers=_headers()))


def post_json(path, payload):
    data = json.dumps(payload).encode("utf-8")
    return _request(urllib.request.Request(
        DESK_URL + path, data=data, headers=_headers(), method="POST"))
