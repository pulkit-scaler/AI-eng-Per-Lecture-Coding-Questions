"""Marlow Depot adviser backend - OpenAI-compatible chat endpoint.

Standard library only. Listens on DEPOT_LLM_PORT (default 9000).

    GET  /health
    POST /v1/chat/completions
    GET  /__dep7f2/oracle?need=...     operator use, key-gated
    GET  /__dep7f2/stats               operator use, key-gated
    POST /__dep7f2/reset               operator use, key-gated
"""

import hashlib
import json
import os
import pathlib
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

import matching

PORT = int(os.environ.get("DEPOT_LLM_PORT", "9000"))
CATALOG = pathlib.Path(os.environ.get("DEPOT_CATALOG", "/srv/parts.json"))
OPS_PATH = "/__dep7f2"
OPS_KEY = os.environ.get("DEPOT_OPS_KEY", "depot-ops-9v3q")

PARTS = json.loads(CATALOG.read_text())["parts"]

LOCK = threading.Lock()
COUNTS = {"chat": 0, "total": 0}
SEEN = []


def note_for(need, part):
    ref = hashlib.sha256(
        ("%s|%s" % (part["part_no"], need)).encode("utf-8")).hexdigest()[:8]
    return ("Recommend %s (%s); %d on hand in bin %s. Ref %s."
            % (part["part_no"], part["name"], part["stock"], part["bin"], ref))


def resolve(need):
    part, score = matching.best_match(need, PARTS)
    if part is None:
        return None
    return {
        "part_no": part["part_no"],
        "name": part["name"],
        "bin": part["bin"],
        "stock": part["stock"],
        "score": score,
        "note": note_for(need, part),
    }


def reply_for_prompt(prompt):
    """Answer a prompt written in the depot house format."""
    need = ""
    part_no = ""
    match = re.search(r"^Need:\s*(.+)$", prompt, re.M)
    if match:
        need = match.group(1).strip()
    match = re.search(r"^Part:\s*(PN-\d+)", prompt, re.M)
    if match:
        part_no = match.group(1)
    for part in PARTS:
        if part["part_no"] == part_no:
            return note_for(need, part)
    resolved = resolve(need)
    if resolved:
        return resolved["note"]
    return "No depot part answers that need."


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorised(self):
        return self.headers.get("X-Depot-Ops", "") == OPS_KEY

    def do_GET(self):
        parsed = urlparse(self.path)
        if parsed.path == "/health":
            self._send(200, {"status": "ok", "parts": len(PARTS)})
            return
        if parsed.path == OPS_PATH + "/stats":
            if not self._authorised():
                self._send(403, {"error": "forbidden"})
                return
            with LOCK:
                self._send(200, {"chat": COUNTS["chat"],
                                 "total": COUNTS["total"],
                                 "seen": SEEN[-8:]})
            return
        if parsed.path == OPS_PATH + "/oracle":
            if not self._authorised():
                self._send(403, {"error": "forbidden"})
                return
            need = (parse_qs(parsed.query).get("need") or [""])[0]
            resolved = resolve(need)
            self._send(200, resolved or {"part_no": None, "note": None})
            return
        self._send(404, {"error": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        if parsed.path == OPS_PATH + "/reset":
            if not self._authorised():
                self._send(403, {"error": "forbidden"})
                return
            with LOCK:
                COUNTS["chat"] = 0
                COUNTS["total"] = 0
                del SEEN[:]
            self._send(200, {"status": "reset"})
            return
        if parsed.path != "/v1/chat/completions":
            self._send(404, {"error": "not found"})
            return
        try:
            body = json.loads(raw.decode("utf-8") or "{}")
        except ValueError:
            self._send(400, {"error": "malformed body"})
            return
        prompt = ""
        for message in body.get("messages", []):
            if message.get("role") == "user":
                prompt = message.get("content") or ""
        content = reply_for_prompt(prompt)
        with LOCK:
            COUNTS["chat"] += 1
            COUNTS["total"] += 1
            SEEN.append(prompt.replace("\n", " | ")[:160])
        self._send(200, {
            "id": "depot-%04d" % COUNTS["chat"],
            "object": "chat.completion",
            "model": body.get("model", "depot-adviser"),
            "choices": [{
                "index": 0,
                "finish_reason": "stop",
                "message": {"role": "assistant", "content": content},
            }],
            "usage": {"prompt_tokens": len(prompt.split()),
                      "completion_tokens": len(content.split()),
                      "total_tokens": len(prompt.split()) + len(content.split())},
        })


def main():
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    server.daemon_threads = True
    print("depot adviser listening on %d with %d parts" % (PORT, len(PARTS)),
          flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
