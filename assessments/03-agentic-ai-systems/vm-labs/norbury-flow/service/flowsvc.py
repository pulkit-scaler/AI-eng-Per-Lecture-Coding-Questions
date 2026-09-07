#!/usr/bin/env python3
"""Norbury model endpoint and tool backends.

Root-only. Installed outside the learner project. It answers the model calls a
flow runtime makes and serves the three tool backends, keeping a per-run record
of the configuration it was handed and the tools it was offered, so a caller can
tell what a flow really did rather than what its JSON said it would.

Standard library only.
"""
import json
import os
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(os.environ.get("NORBURY_PORT", "8788"))
GRADER_KEY = "norbury-grader-nb6f"
GRADER_PREFIX = "/__nb6f"

# The placeholder a visual builder writes into an export where the key was.
EXPORT_PLACEHOLDER = "***"

TOOL_NAMES = ("arxiv_search", "web_search", "summarise")

# What each tool returns. Fixed text, so a briefing can be checked for the
# evidence that the tool actually ran.
TOOL_REPLIES = {
    "arxiv_search": ("arXiv:2411.00812 Sparse routing for long-context "
                     "retrieval; arXiv:2503.14477 Cache-aware decoding"),
    "web_search": ("Norbury Labs blog: retrieval routing in production; "
                   "Register piece on cache-aware decoding costs"),
    "summarise": ("Two threads dominate: routing sparsity and cache reuse."),
}

# The order a well-built research flow reaches for its tools.
TOOL_ORDER = ("arxiv_search", "web_search", "summarise")

_LOCK = threading.Lock()
_RUNS = {}


def _blank_run():
    return {"model_calls": 0, "tool_calls": [], "configs": [], "systems": [],
            "offered": [], "forced_finals": 0, "placeholder_seen": 0,
            "keys_seen": []}


def _run(run_id):
    return _RUNS.setdefault(run_id or "default", _blank_run())


def _last_user(messages):
    for message in reversed(messages or []):
        if (message.get("role") or "").lower() in ("user", "human"):
            return message.get("content") or ""
    return ""


def _tools_used(messages):
    """Which tools this conversation has already reported back from."""
    used = []
    for message in messages or []:
        if (message.get("role") or "").lower() in ("tool", "observation"):
            name = message.get("name") or ""
            if name and name not in used:
                used.append(name)
    return used


def _topic(text):
    cleaned = re.sub(r"^(research|tell me about|what about|look into)\s+", "",
                     (text or "").strip(), flags=re.I)
    return cleaned.strip(" .?").strip() or "the requested topic"


def decide(payload):
    """What the model does next, from the conversation and the tools offered."""
    messages = payload.get("messages") or []
    offered = [t for t in (payload.get("tools") or []) if t in TOOL_NAMES]
    used = _tools_used(messages)
    question = _last_user(messages)

    if payload.get("force_final"):
        return {"type": "final",
                "text": ("Wrapping up early. From what I gathered on %s: %s"
                         % (_topic(question), TOOL_REPLIES["arxiv_search"]))}

    # A question about what came earlier is answered from the conversation
    # itself, which is how a caller can tell whether memory was wired in.
    if re.search(r"what did i (ask|say)|earlier|before|first question",
                 question, re.I):
        earlier = [m.get("content") or "" for m in messages
                   if (m.get("role") or "").lower() in ("user", "human")]
        if len(earlier) >= 2:
            return {"type": "final",
                    "text": "Earlier you asked about %s." % _topic(earlier[0])}
        return {"type": "final",
                "text": "I have nothing earlier in this conversation to go on."}

    for name in TOOL_ORDER:
        if name in offered and name not in used:
            return {"type": "tool", "tool": name, "input": _topic(question)}

    findings = "; ".join(TOOL_REPLIES[name] for name in used) or "no sources"
    return {"type": "final",
            "text": "Briefing on %s. Findings: %s" % (_topic(question),
                                                      findings)}


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "norbury-flow/1.0"

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

    def _authorised(self):
        return self.headers.get("X-Grader-Key") == GRADER_KEY

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == "/health":
            return self._send(200, {"ok": True, "service": "norbury-flow"})
        if parsed.path == "/v1/tools":
            return self._send(200, {"tools": list(TOOL_NAMES)})
        if parsed.path.startswith(GRADER_PREFIX):
            if not self._authorised():
                return self._send(404, {"error": "not found"})
            leaf = parsed.path[len(GRADER_PREFIX):]
            if leaf == "/trace":
                with _LOCK:
                    return self._send(200, dict(_run(query.get("run", [""])[0])))
            if leaf == "/replies":
                return self._send(200, {"tool_replies": dict(TOOL_REPLIES),
                                        "order": list(TOOL_ORDER)})
            return self._send(404, {"error": "not found"})
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if parsed.path.startswith(GRADER_PREFIX):
            if not self._authorised():
                return self._send(404, {"error": "not found"})
            if parsed.path[len(GRADER_PREFIX):] == "/reset":
                run_id = query.get("run", [""])[0] or "default"
                with _LOCK:
                    _RUNS[run_id] = _blank_run()
                return self._send(200, {"reset": run_id})
            return self._send(404, {"error": "not found"})

        payload = self._body()
        run_id = payload.get("run_id") or os.environ.get("NORBURY_RUN_ID") \
            or "default"

        if parsed.path == "/v1/model":
            key = str(payload.get("api_key") or "")
            config = payload.get("config") or {}
            with _LOCK:
                record = _run(run_id)
                record["model_calls"] += 1
                record["configs"].append({
                    "model": config.get("model"),
                    "temperature": config.get("temperature"),
                })
                record["systems"].append((payload.get("system") or "")[:300])
                record["offered"].append(list(payload.get("tools") or []))
                record["keys_seen"].append(key[:40])
                if EXPORT_PLACEHOLDER and EXPORT_PLACEHOLDER in key:
                    record["placeholder_seen"] += 1
                if payload.get("force_final"):
                    record["forced_finals"] += 1
            if not key:
                return self._send(401, {"error": "no credential presented"})
            if EXPORT_PLACEHOLDER in key:
                return self._send(401, {
                    "error": "that is the placeholder a builder writes into an "
                             "export, not a credential"})
            return self._send(200, decide(payload))

        if parsed.path == "/v1/tool":
            name = payload.get("tool")
            if name not in TOOL_NAMES:
                return self._send(400, {"error": "unknown tool %r" % name})
            with _LOCK:
                record = _run(run_id)
                record["tool_calls"].append({
                    "tool": name,
                    "input": (payload.get("input") or "")[:120],
                    "max_results": payload.get("max_results"),
                })
            return self._send(200, {"tool": name, "text": TOOL_REPLIES[name]})

        return self._send(404, {"error": "not found"})


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.daemon_threads = True
    server.serve_forever()


if __name__ == "__main__":
    main()
