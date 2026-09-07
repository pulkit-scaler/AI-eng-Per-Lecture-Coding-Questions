#!/usr/bin/env python3
"""An approval service that keeps claims in a dict and never runs an agent."""
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse

PORT = int(os.environ.get("PELHAM_SERVICE_PORT", "8767"))
THREADS = {}
LOCK = threading.Lock()
DESIRES = ["Approve legitimate expenses quickly",
           "Prevent fraudulent or out-of-policy claims",
           "Escalate anything ambiguous or high-value to a person"]


def _decide(claim):
    amount = float(claim.get("amount_usd") or 0)
    return amount < 100


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

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
            return self._send(200, {"ok": True})
        if path.startswith("/claims/"):
            with LOCK:
                record = THREADS.get(path[len("/claims/"):])
            if record is None:
                return self._send(404, {"error": "unknown thread"})
            return self._send(200, record)
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        path = urlparse(self.path).path
        payload = self._body()
        if path == "/claims":
            thread_id = payload.get("thread_id")
            claim = payload.get("claim") or {}
            cleared = _decide(claim)
            record = {
                "thread_id": thread_id, "request": claim,
                "beliefs": dict(claim, policy_threshold_usd=100,
                                valid_categories=["meals", "travel", "software",
                                                  "office_supplies"]),
                "desires": list(DESIRES),
                "intentions": [{"action": "auto_approve" if cleared
                                          else "escalate_to_human",
                                "reason": "policy threshold"}],
                "audit_log": ["[PERCEIVE] claim received",
                              "[DELIBERATE] decided on the amount",
                              "[FINALIZE] recorded"] if cleared
                             else ["[PERCEIVE] claim received",
                                   "[DELIBERATE] decided on the amount"],
                "final_status": "APPROVED (auto)" if cleared else None,
                "human_decision": None,
                "pending": not cleared,
                "interrupt": None if cleared else {
                    "message": "Human approval required", "claim": claim,
                    "agent_reasoning": "over the policy threshold",
                    "options": ["approve", "reject"]},
            }
            with LOCK:
                THREADS[thread_id] = record
            return self._send(200, {"thread_id": thread_id,
                                    "pending": record["pending"],
                                    "interrupt": record["interrupt"],
                                    "final_status": record["final_status"]})
        if path == "/webhook/approval":
            value = payload.get("value") or ""
            if "|" not in value:
                return self._send(400, {"error": "bad value"})
            decision, thread_id = value.split("|", 1)
            decision = decision.strip().lower()
            if decision not in ("approve", "reject"):
                return self._send(400, {"error": "unknown decision"})
            with LOCK:
                record = THREADS.get(thread_id)
                if record is None:
                    return self._send(404, {"error": "unknown thread"})
                if not record["pending"]:
                    return self._send(409, {"error": "already decided"})
                record["human_decision"] = decision
                record["final_status"] = ("APPROVED (human)"
                                          if decision == "approve"
                                          else "REJECTED (human)")
                record["pending"] = False
                record["interrupt"] = None
                record["audit_log"] = record["audit_log"] + [
                    "[HUMAN_REVIEW] decision %s" % decision,
                    "[FINALIZE] status %s" % record["final_status"]]
                record["intentions"] = record["intentions"] + [
                    {"action": "process_reimbursement", "reason": "decided"}]
            return self._send(200, {"thread_id": thread_id,
                                    "final_status": record["final_status"],
                                    "human_decision": decision})
        return self._send(404, {"error": "not found"})


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.daemon_threads = True
    print("listening on %d" % PORT, flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
