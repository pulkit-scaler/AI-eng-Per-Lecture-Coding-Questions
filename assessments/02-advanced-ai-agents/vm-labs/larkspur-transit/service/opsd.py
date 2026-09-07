#!/usr/bin/env python3
"""opsd - local operations service backing the Larkspur Transit lab.

INSTRUCTOR-ONLY FILE. Installed to /opt/larkspur-svc (root:root, 0700) and never
placed under the learner project directory.

Public surface (what the provided kit uses):
  GET  /health                          -> {"status": "ok", ...}
  POST /v1/chat/completions             -> an OpenAI chat-completion body
  POST /v1/audit                        -> records one database access

Grader-only surface, all behind the X-Larkspur-Grader header; without it every
one of these paths answers a plain 404 exactly like any other unknown path:
  GET  /__grk7q2/trace?session=<id>     -> what one session actually did
  POST /__grk7q2/trace/reset?session=.. -> clears that session and the access log
  GET  /__grk7q2/oracle?q=<question>    -> the true answer, computed from SQLite

The reply to a chat request is decided by MESSAGE STATE alone: each question maps
to an ordered plan of tool steps, and the step served next is the one at index
"number of tool results already in the conversation". A step is only ever served
when the request declares that tool correctly, so an incomplete tool declaration
stops the walk instead of being quietly tolerated. Once the plan is finished the
final answer is composed from the value the last tool result actually carried.
"""
import json
import os
import re
import sqlite3
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(os.environ.get("LARKSPUR_PORT", "8757"))
GRADER_KEY = "larkspur-grader-k7q2"
MODEL_NAME = "larkspur-ops-1"
DB_PATH = os.environ.get("LARKSPUR_DB") or "/home/user/larkspur-transit/data/transit.db"
AUDIT_LIMIT = 400

_LOCK = threading.Lock()
_SESSIONS = {}
_AUDIT = []
_COUNTER = [0]


# ---------------------------------------------------------------------------
# question -> plan -> answer
# ---------------------------------------------------------------------------

def _step(tool, **args):
    return {"tool": tool, "args": args}


BUSIEST_ROUTE_SQL = (
    "SELECT r.name AS route_name FROM trips t "
    "JOIN routes r ON t.route_code = r.code "
    "GROUP BY r.name ORDER BY SUM(t.boardings) DESC LIMIT 1"
)

SCENARIOS = [
    {
        "question": "How many bus routes are there?",
        "plan": [
            _step("list_tables"),
            _step("get_table_schema", table_name="routes"),
            _step("execute_sql",
                  query="SELECT COUNT(*) AS n FROM routes WHERE mode = 'bus'"),
        ],
        "truth": "SELECT COUNT(*) FROM routes WHERE mode = 'bus'",
        "answer": "There are %s bus routes.",
    },
    {
        "question": "How many vehicles are stationed at the Kingsmere depot?",
        "plan": [
            _step("list_tables"),
            _step("get_table_schema", table_name="vehicles"),
            _step("execute_sql",
                  query="SELECT COUNT(*) AS n FROM vehicles WHERE depot = 'Kingsmere'"),
        ],
        "truth": "SELECT COUNT(*) FROM vehicles WHERE depot = 'Kingsmere'",
        "answer": "There are %s vehicles stationed at the Kingsmere depot.",
    },
    {
        "question": "Which route carried the most total boardings?",
        "plan": [
            _step("list_tables"),
            _step("get_table_schema", table_name="trips"),
            _step("get_table_schema", table_name="routes"),
            _step("execute_sql", query=BUSIEST_ROUTE_SQL),
        ],
        "truth": BUSIEST_ROUTE_SQL,
        "answer": "The busiest route by total boardings is %s.",
    },
    {
        "question": "How many trips ran with a delay of more than two minutes?",
        "plan": [
            _step("list_tables"),
            _step("get_table_schema", table_name="trips"),
            _step("execute_sql",
                  query="SELECT COUNT(*) AS n FROM trips WHERE delay_min > 2"),
        ],
        "truth": "SELECT COUNT(*) FROM trips WHERE delay_min > 2",
        "answer": "There were %s trips with a delay of more than two minutes.",
    },
    {
        "question": "How many vehicles are out of service?",
        "plan": [
            _step("list_tables"),
            _step("get_table_schema", table_name="vehicles"),
            _step("execute_sql",
                  query="SELECT COUNT(*) AS n FROM vehicles WHERE in_service = 0"),
        ],
        "truth": "SELECT COUNT(*) FROM vehicles WHERE in_service = 0",
        "answer": "There are %s vehicles out of service.",
    },
]

FALLBACK = {
    "plan": [_step("list_tables")],
    "truth": None,
    "answer": "I do not have enough information to answer that.",
}


def _norm(text):
    return re.sub(r"[^a-z0-9]+", " ", (text or "").lower()).strip()


_BY_QUESTION = {_norm(s["question"]): s for s in SCENARIOS}


def scenario_for(question):
    return _BY_QUESTION.get(_norm(question), FALLBACK)


# ---------------------------------------------------------------------------
# reading the value a tool result carried
# ---------------------------------------------------------------------------

_SEPARATOR_RE = re.compile(r"^[-+\s]{3,}$")


def _as_text(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, str):
                parts.append(block)
            elif isinstance(block, dict):
                parts.append(str(block.get("text") or ""))
        return "\n".join(parts)
    if content is None:
        return ""
    return str(content)


def first_cell(content):
    """The first cell of the first data row of a formatted result table."""
    lines = _as_text(content).splitlines()
    for i, line in enumerate(lines):
        if line.strip() and _SEPARATOR_RE.match(line.strip()):
            for follow in lines[i + 1:]:
                if follow.strip():
                    return follow.split("|")[0].strip()
            return None
    return None


def observed_value(messages):
    for message in reversed(messages or []):
        if isinstance(message, dict) and message.get("role") == "tool":
            return first_cell(message.get("content"))
    return None


# ---------------------------------------------------------------------------
# tool declaration checking
# ---------------------------------------------------------------------------

REQUIRED_PARAMS = {
    "list_tables": (),
    "get_table_schema": ("table_name",),
    "execute_sql": ("query",),
}


def declared_tools(tools):
    """name -> True when that tool is declared in a usable OpenAI shape."""
    seen = {}
    for entry in tools or []:
        if not isinstance(entry, dict) or entry.get("type") != "function":
            continue
        fn = entry.get("function")
        if not isinstance(fn, dict):
            continue
        name = fn.get("name")
        if not isinstance(name, str) or not name:
            continue
        description = fn.get("description")
        params = fn.get("parameters")
        ok = isinstance(description, str) and bool(description.strip())
        ok = ok and isinstance(params, dict) and params.get("type") == "object"
        props = params.get("properties") if isinstance(params, dict) else None
        ok = ok and isinstance(props, dict)
        if ok:
            for need in REQUIRED_PARAMS.get(name, ()):
                if need not in props:
                    ok = False
                    break
        seen[name] = bool(ok)
    return seen


# ---------------------------------------------------------------------------
# per-session record
# ---------------------------------------------------------------------------

def _blank():
    return {
        "chat_turns": 0,
        "emitted": [],
        "emitted_ids": [],
        "tool_ids_seen": [],
        "unknown_ids": [],
        "schema_ok": None,
        "schema_detail": {},
        "stalled": False,
        "final": "",
        "plan": [],
        "question": "",
    }


def _session(name):
    return _SESSIONS.setdefault(name, _blank())


def _last_user_question(messages):
    question = ""
    for message in messages or []:
        if isinstance(message, dict) and message.get("role") == "user":
            question = _as_text(message.get("content"))
    return question


def _tool_result_count(messages):
    return sum(1 for m in (messages or [])
               if isinstance(m, dict) and m.get("role") == "tool")


def next_reply(session_name, messages, tools):
    """Decide the assistant message for one chat request, and record what happened."""
    with _LOCK:
        rec = _session(session_name)
        rec["chat_turns"] += 1
        question = _last_user_question(messages)
        scenario = scenario_for(question)
        plan = scenario["plan"]
        rec["question"] = question
        rec["plan"] = [step["tool"] for step in plan]

        detail = declared_tools(tools)
        rec["schema_detail"] = detail
        request_ok = all(detail.get(name) is True for name in REQUIRED_PARAMS)
        rec["schema_ok"] = request_ok if rec["schema_ok"] is None \
            else bool(rec["schema_ok"] and request_ok)

        for message in messages or []:
            if isinstance(message, dict) and message.get("role") == "tool":
                call_id = message.get("tool_call_id")
                rec["tool_ids_seen"].append(call_id)
                if call_id not in rec["emitted_ids"]:
                    rec["unknown_ids"].append(call_id)
        rec["tool_ids_seen"] = rec["tool_ids_seen"][-40:]
        rec["unknown_ids"] = rec["unknown_ids"][-40:]

        done = _tool_result_count(messages)
        if done < len(plan):
            step = plan[done]
            if detail.get(step["tool"]) is not True:
                rec["stalled"] = True
                text = ("The %s tool is not available to me, so I cannot answer "
                        "that." % step["tool"])
                rec["final"] = text
                return {"role": "assistant", "content": text}, "stop"
            _COUNTER[0] += 1
            call_id = "call_%s_%d" % (step["tool"], done)
            rec["emitted"].append(step["tool"])
            rec["emitted_ids"].append(call_id)
            return {
                "role": "assistant",
                "content": None,
                "tool_calls": [{
                    "id": call_id,
                    "type": "function",
                    "function": {"name": step["tool"],
                                 "arguments": json.dumps(step["args"])},
                }],
            }, "tool_calls"

        value = observed_value(messages)
        if scenario.get("truth") is None:
            text = scenario["answer"]
        elif value is None:
            text = ("I could not read a result out of the last tool output, so I "
                    "cannot answer that.")
        else:
            text = scenario["answer"] % value
        rec["final"] = text
        return {"role": "assistant", "content": text}, "stop"


# ---------------------------------------------------------------------------
# the oracle: true answers straight out of SQLite
# ---------------------------------------------------------------------------

def oracle(question):
    scenario = scenario_for(question)
    out = {
        "question": question,
        "plan": [step["tool"] for step in scenario["plan"]],
        "value": None,
        "answer": scenario["answer"],
        "db": DB_PATH,
    }
    if scenario.get("truth") is None:
        return out
    conn = sqlite3.connect(DB_PATH)
    try:
        row = conn.execute(scenario["truth"]).fetchone()
    finally:
        conn.close()
    value = "" if row is None or row[0] is None else str(row[0])
    out["value"] = value
    out["answer"] = scenario["answer"] % value
    return out


def db_facts():
    conn = sqlite3.connect(DB_PATH)
    try:
        names = [r[0] for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name NOT LIKE 'sqlite_%' ORDER BY name;").fetchall()]
        counts = {}
        for name in names:
            counts[name] = conn.execute(
                "SELECT COUNT(*) FROM `%s`" % name).fetchone()[0]
    finally:
        conn.close()
    return {"tables": names, "counts": counts, "db": DB_PATH}


# ---------------------------------------------------------------------------
# HTTP layer
# ---------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _session_name(self):
        return self.headers.get("X-Larkspur-Session") or "local"

    def _is_grader(self):
        return self.headers.get("X-Larkspur-Grader") == GRADER_KEY

    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except OSError:
            pass

    def _not_found(self):
        return self._send(404, {"error": {"message": "not found",
                                          "type": "invalid_request_error"}})

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            return json.loads(raw.decode("utf-8"))
        except ValueError:
            return None

    def do_GET(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        one = lambda key, default="": (query.get(key) or [default])[0]

        if url.path == "/health":
            return self._send(200, {"status": "ok", "service": "opsd",
                                    "model": MODEL_NAME})

        if url.path == "/__grk7q2/trace":
            if not self._is_grader():
                return self._not_found()
            name = one("session", self._session_name())
            with _LOCK:
                record = dict(_SESSIONS.get(name) or _blank())
                record["audit"] = list(_AUDIT)
                record["session"] = name
            return self._send(200, record)

        if url.path == "/__grk7q2/oracle":
            if not self._is_grader():
                return self._not_found()
            try:
                payload = oracle(one("q"))
                payload.update(db_facts())
            except (sqlite3.Error, OSError) as exc:
                return self._send(200, {"error": "%s: %s"
                                        % (type(exc).__name__, exc)})
            return self._send(200, payload)

        return self._not_found()

    def do_POST(self):
        url = urlparse(self.path)
        query = parse_qs(url.query)
        payload = self._body()
        if payload is None:
            return self._send(400, {"error": {"message": "bad json"}})

        if url.path == "/v1/chat/completions":
            message, finish = next_reply(self._session_name(),
                                         payload.get("messages") or [],
                                         payload.get("tools") or [])
            return self._send(200, {
                "id": "chatcmpl-larkspur-%d" % _COUNTER[0],
                "object": "chat.completion",
                "created": int(time.time()),
                "model": payload.get("model") or MODEL_NAME,
                "choices": [{"index": 0, "message": message,
                             "finish_reason": finish, "logprobs": None}],
                "usage": {"prompt_tokens": 0, "completion_tokens": 0,
                          "total_tokens": 0},
            })

        if url.path == "/v1/audit":
            entry = {
                "op": str(payload.get("op") or ""),
                "detail": str(payload.get("detail") or "")[:200],
                "pid": payload.get("pid"),
                "ppid": payload.get("ppid"),
                "session": str(payload.get("session") or ""),
            }
            with _LOCK:
                _AUDIT.append(entry)
                if len(_AUDIT) > AUDIT_LIMIT:
                    del _AUDIT[:len(_AUDIT) - AUDIT_LIMIT]
            return self._send(200, {"recorded": True})

        if url.path == "/__grk7q2/trace/reset":
            if not self._is_grader():
                return self._not_found()
            name = (query.get("session") or [self._session_name()])[0]
            with _LOCK:
                _SESSIONS.pop(name, None)
                del _AUDIT[:]
            return self._send(200, {"reset": name})

        return self._not_found()


def main():
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
