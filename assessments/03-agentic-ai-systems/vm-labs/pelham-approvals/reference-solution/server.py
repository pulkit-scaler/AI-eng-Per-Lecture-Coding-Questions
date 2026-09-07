#!/usr/bin/env python3
"""The approval service: claims in, a pause for a person, a webhook to resume."""
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from langgraph.types import Command  # noqa: E402

from bdi.graph import EMPTY_STATE, build_graph  # noqa: E402

PORT = int(os.environ.get("PELHAM_SERVICE_PORT", "8767"))

GRAPH = build_graph()
LOCK = threading.Lock()


def _config(thread_id):
    return {"configurable": {"thread_id": thread_id}}


def _snapshot(thread_id):
    """Everything known about one thread, pause included."""
    state = GRAPH.get_state(_config(thread_id))
    if state is None or not state.created_at:
        return None
    values = dict(state.values or {})
    pending = bool(state.next)
    payload = None
    for task in state.tasks or ():
        for item in getattr(task, "interrupts", ()) or ():
            payload = getattr(item, "value", None)
    values["pending"] = pending
    values["thread_id"] = thread_id
    values["interrupt"] = payload
    return values


def _first_interrupt(result):
    items = (result or {}).get("__interrupt__") or []
    for item in items:
        return getattr(item, "value", item)
    return None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "pelham-approvals/1.0"

    def log_message(self, *args):
        return

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode())
        except Exception:
            return {}

    def do_GET(self):
        path = urlparse(self.path).path
        if path == "/health":
            return self._send(200, {"ok": True, "service": "pelham-approvals"})
        if path.startswith("/claims/"):
            thread_id = path[len("/claims/"):]
            snapshot = _snapshot(thread_id)
            if snapshot is None:
                return self._send(404, {"error": "unknown thread %r"
                                                 % thread_id})
            return self._send(200, snapshot)
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        path = urlparse(self.path).path
        payload = self._body()

        if path == "/claims":
            thread_id = payload.get("thread_id")
            claim = payload.get("claim")
            if not thread_id or not isinstance(claim, dict):
                return self._send(400, {"error": "thread_id and claim required"})
            with LOCK:
                result = GRAPH.invoke(dict(EMPTY_STATE, request=claim),
                                      config=_config(thread_id))
            interrupt_value = _first_interrupt(result)
            return self._send(200, {
                "thread_id": thread_id,
                "pending": interrupt_value is not None,
                "interrupt": interrupt_value,
                "final_status": result.get("final_status"),
            })

        if path == "/webhook/approval":
            value = payload.get("value") or ""
            if "|" not in value:
                return self._send(400, {
                    "error": "value must look like decision|thread_id"})
            decision, thread_id = value.split("|", 1)
            decision = decision.strip().lower()
            if decision not in ("approve", "reject"):
                return self._send(400, {"error": "unknown decision %r"
                                                 % decision})
            snapshot = _snapshot(thread_id)
            if snapshot is None:
                return self._send(404, {"error": "unknown thread %r"
                                                 % thread_id})
            if not snapshot.get("pending"):
                # The button was clicked twice. The first click already
                # decided it, and a decided claim does not get re-decided.
                return self._send(409, {
                    "error": "thread %r is not waiting for a decision"
                             % thread_id,
                    "thread_id": thread_id,
                    "final_status": snapshot.get("final_status"),
                })
            with LOCK:
                result = GRAPH.invoke(Command(resume=decision),
                                      config=_config(thread_id))
            return self._send(200, {
                "thread_id": thread_id,
                "final_status": result.get("final_status"),
                "human_decision": result.get("human_decision"),
            })

        return self._send(404, {"error": "not found"})


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.daemon_threads = True
    print("pelham approvals listening on 127.0.0.1:%d" % PORT, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
