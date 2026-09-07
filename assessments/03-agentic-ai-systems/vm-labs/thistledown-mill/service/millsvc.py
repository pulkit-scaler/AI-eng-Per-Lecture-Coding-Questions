#!/usr/bin/env python3
"""millsvc - the Thistledown Mill planning model, OpenAI-compatible.

INSTRUCTOR-ONLY FILE. Installed to /opt/thistledown-svc as root:root 0700 and
never placed under the learner project.

    GET  /health
    POST /v1/chat/completions          OpenAI-compatible
    GET  /__tm8q/trace?run=            grader only
    POST /__tm8q/reset?run=            grader only

The reply to a planning turn is computed from the order number in the prompt and
from whether the prompt already carries a tool result, so a run over the same
order always takes the same path. Both calling conventions are answered: a
request that offers tools gets a tool call back, and a request that does not gets
the same decision written in the plain text form.
"""
import json
import os
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(os.environ.get("THISTLEDOWN_PORT", "8433"))
GRADER_KEY = "thistledown-grader-tm8q"
GRADER_PATH = "/__tm8q"

ORDER_RE = re.compile(r"\bTM-\d{4}\b")
YARN_RE = re.compile(r"\bYN-[A-Z]{2}\d{2}\b")
OBSERVATION_RE = re.compile(r"Observation:\s*(.+)\Z", re.S)

_LOCK = threading.Lock()
_TRACE = {}

# The plan the mill follows for each order: which yarn it is cut from, and the
# query that answers whether it can be met.
ORDERS = {
    "TM-4301": {"yarn": "YN-WL14", "metres": 480},
    "TM-4312": {"yarn": "YN-CT08", "metres": 1200},
    "TM-4327": {"yarn": "YN-LN22", "metres": 260},
    "TM-4338": {"yarn": "YN-WL14", "metres": 2400},
    "TM-4344": {"yarn": "YN-SK03", "metres": 150},
    "TM-4359": {"yarn": "YN-CT08", "metres": 900},
    "TM-4366": {"yarn": "YN-ZZ99", "metres": 300},
    "TM-4371": {"yarn": "YN-LN22", "metres": 640},
    "TM-4388": {"yarn": "YN-SK03", "metres": 75},
    "TM-4390": {"yarn": "YN-WL14", "metres": 120},
}

QUERY_TEMPLATE = ("SELECT yarn_code, cones_on_hand, metres_per_cone "
                  "FROM yarn_stock WHERE yarn_code = '%s'")


def blank_trace():
    return {"calls": 0, "tool_calls": 0, "finals": 0,
            "queries": [], "answered": [], "first_seen": None}


def record(run, field, value=None):
    with _LOCK:
        entry = _TRACE.setdefault(run, blank_trace())
        if entry["first_seen"] is None:
            entry["first_seen"] = int(time.time())
        if field in ("calls", "tool_calls", "finals"):
            entry[field] += 1
        else:
            entry[field].append(value)


def order_of(text):
    found = ORDER_RE.search(text or "")
    return found.group(0) if found else None


def conversation_text(body):
    parts = []
    for message in body.get("messages", []):
        content = message.get("content")
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and "text" in block:
                    parts.append(str(block["text"]))
        elif content:
            parts.append(str(content))
        if message.get("role") == "tool":
            parts.append("\"role\": \"tool\"")
        for call in message.get("tool_calls") or []:
            parts.append(json.dumps(call))
    return "\n".join(parts)


def tool_names(body):
    names = []
    for tool in body.get("tools") or []:
        function = tool.get("function") or {}
        if function.get("name"):
            names.append(function["name"])
    return names


def has_observation(body):
    """Has a tool already reported back in this conversation?

    The opening turn is a system prompt and one user turn. Anything beyond that
    is the planner having acted and the result having come back, whichever
    calling convention is in use - so the shape of the conversation is the
    signal, not the word Observation, which the planning instructions
    themselves contain.
    """
    messages = body.get("messages") or []
    if len(messages) > 2:
        return True
    for message in messages:
        if message.get("role") == "tool" or message.get("tool_calls"):
            return True
    return False


def last_observation(body):
    """Whatever the tool last handed back, verbatim."""
    messages = body.get("messages") or []
    for message in reversed(messages):
        if message.get("role") == "tool" and message.get("content"):
            return str(message["content"]).strip()
        content = message.get("content")
        if isinstance(content, str):
            found = OBSERVATION_RE.search(content)
            if found:
                return found.group(1).strip()
    return ""


QUERY_TOOL_RE = re.compile(r"Tool Name:\s*([A-Za-z0-9_]*(?:quer|sql)[A-Za-z0-9_]*)",
                           re.I)


def offers_query_tool(body, text):
    """Can whoever is asking actually run a query?

    An agent with no query tool must not be handed a query to run: it would go
    looking for a tool it does not have and burn its turns finding out. The tool
    list arrives either as a tools array or written into the instructions.
    """
    for name in tool_names(body):
        if "quer" in name.lower() or "sql" in name.lower():
            return True
    return bool(QUERY_TOOL_RE.search(text or ""))


def carried_stock_line(text, yarn, order):
    """A stock row already quoted earlier in the conversation, if there is one.

    A line that also carries the order number is the previous summary being
    quoted back, not a row out of the stock table, so it is skipped: otherwise
    the note ends up citing itself.
    """
    for line in (text or "").splitlines():
        stripped = line.strip()
        if yarn not in stripped:
            continue
        if order and order in stripped:
            continue
        if len(re.findall(r"\b\d+\b", stripped)) < 2:
            continue
        return stripped
    return ""


def decide(body):
    """(kind, payload) for this turn: a query to run, or the answer."""
    text = conversation_text(body)
    order = order_of(text)
    row = ORDERS.get(order or "")
    if row is None:
        return "final", ("No order number in that request, so there is nothing "
                         "to plan.")
    if not offers_query_tool(body, text):
        # Whoever is asking cannot run a query, so this is the writing turn.
        carried = carried_stock_line(text, row["yarn"], order)
        if carried:
            return "final", (
                "Order %s is cut from %s and needs %d metres.\n\n"
                "Stock table says:\n%s\n\n"
                "Available metres are the cones on hand multiplied by the "
                "metres per cone. Where that reaches %d the order can be cut, "
                "and where the yarn has no row it is not stocked at all."
                % (order, row["yarn"], row["metres"], carried, row["metres"]))
        return "final", (
            "Order %s is cut from %s and needs %d metres. No stock row for %s "
            "was carried into this note, so the order cannot be confirmed."
            % (order, row["yarn"], row["metres"], row["yarn"]))
    if has_observation(body):
        seen = last_observation(body) or "nothing came back from the stock table"
        return "final", (
            "Order %s is cut from %s and needs %d metres.\n\n"
            "Stock table says:\n%s\n\n"
            "That row is the authority on whether the order can be met: the "
            "cones on hand multiplied by the metres per cone is what is "
            "available, and a yarn with no row is not stocked at all."
            % (order, row["yarn"], row["metres"], seen))
    return "query", QUERY_TEMPLATE % row["yarn"]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def _run(self, body=None):
        """Planning traffic is booked against the order it is about.

        There is no correlation id to thread through: the order number is in
        every prompt, which makes the trace of one order self-contained without
        the planner having to carry anything extra.
        """
        if body is not None:
            found = order_of(conversation_text(body))
            if found:
                return found
        return "unknown"

    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorised(self):
        return self.headers.get("X-Grader-Key", "") == GRADER_KEY

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            return json.loads(raw.decode("utf-8") or "{}")
        except ValueError:
            return {}

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == "/health":
            self._send(200, {"status": "ok", "orders": len(ORDERS)})
            return
        if parsed.path == "/v1/models":
            self._send(200, {"object": "list", "data": [
                {"id": "gpt-4o-mini", "object": "model",
                 "owned_by": "thistledown"}]})
            return
        if parsed.path == GRADER_PATH + "/trace":
            if not self._authorised():
                self._send(403, {"error": "forbidden"})
                return
            run = (query.get("run") or ["unknown"])[0]
            with _LOCK:
                self._send(200, json.loads(json.dumps(
                    _TRACE.get(run) or blank_trace())))
            return
        self._send(404, {"error": {"message": "not found"}})

    def do_POST(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == GRADER_PATH + "/reset":
            if not self._authorised():
                self._send(403, {"error": "forbidden"})
                return
            run = (query.get("run") or ["unknown"])[0]
            with _LOCK:
                _TRACE[run] = blank_trace()
            self._send(200, {"status": "reset", "run": run})
            return

        if parsed.path not in ("/v1/chat/completions", "/chat/completions"):
            self._send(404, {"error": {"message": "not found"}})
            return

        body = self._body()
        run = self._run(body)
        order = order_of(conversation_text(body))
        record(run, "calls")

        kind, payload = decide(body)
        if kind == "final":
            record(run, "answered", order or "unknown")
        offered = tool_names(body)
        model = body.get("model") or "gpt-4o-mini"

        if kind == "query" and offered:
            target = offered[0]
            for name in offered:
                if "sql" in name.lower() or "quer" in name.lower():
                    target = name
                    break
            record(run, "tool_calls")
            record(run, "queries", payload)
            message = {
                "role": "assistant",
                "content": None,
                "tool_calls": [{
                    "id": "call_tm%04d" % (_TRACE[run]["calls"]),
                    "type": "function",
                    "function": {"name": target,
                                 "arguments": json.dumps({"sql": payload,
                                                          "query": payload})},
                }],
            }
            finish = "tool_calls"
        elif kind == "query":
            record(run, "tool_calls")
            record(run, "queries", payload)
            message = {
                "role": "assistant",
                "content": ("Thought: I need the stock row for this order "
                            "before I can answer.\n"
                            "Action: run_query\n"
                            "Action Input: {\"sql\": \"%s\"}" % payload),
            }
            finish = "stop"
        else:
            record(run, "finals")
            message = {"role": "assistant",
                       "content": "Thought: I have what I need.\nFinal Answer: "
                                  + payload}
            finish = "stop"

        prompt_text = conversation_text(body)
        self._send(200, {
            "id": "chatcmpl-tm%04d" % _TRACE[run]["calls"],
            "object": "chat.completion",
            "created": 1770000000,
            "model": model,
            "choices": [{"index": 0, "message": message,
                         "finish_reason": finish, "logprobs": None}],
            "usage": {"prompt_tokens": len(prompt_text.split()),
                      "completion_tokens": 40,
                      "total_tokens": len(prompt_text.split()) + 40},
        })


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.daemon_threads = True
    print("thistledown planning model listening on %d with %d orders"
          % (PORT, len(ORDERS)), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
