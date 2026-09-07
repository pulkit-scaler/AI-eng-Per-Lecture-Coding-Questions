"""Access log for the Larkspur operations database.

Provided, do not modify.

The transit authority requires an access record for every read of the
operations database: which operation ran, and in which process. ``record()``
posts one short entry to the operations service and never raises - a database
read must not fail because the access log is unavailable.
"""
import json
import os
import urllib.error
import urllib.request

from .endpoint import service_url, session_id

TIMEOUT = 2.0


def record(op: str, detail: str = "") -> None:
    """Note that ``op`` read the operations database from this process."""
    payload = {
        "op": op,
        "detail": detail[:200],
        "pid": os.getpid(),
        "ppid": os.getppid(),
        "session": session_id(),
    }
    data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        service_url() + "/v1/audit",
        data=data,
        headers={
            "Content-Type": "application/json",
            "X-Larkspur-Session": payload["session"],
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
            resp.read()
    except (urllib.error.URLError, OSError, ValueError):
        # The access log is best-effort: an unreachable service must never turn
        # a working database read into a failure.
        return
