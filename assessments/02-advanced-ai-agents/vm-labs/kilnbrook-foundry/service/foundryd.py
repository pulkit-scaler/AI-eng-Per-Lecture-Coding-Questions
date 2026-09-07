#!/usr/bin/env python3
"""foundryd - the local model endpoint behind the Kilnbrook Foundry lab.

INSTRUCTOR-ONLY FILE. Installed to /opt/kilnbrook-svc (root:root, 0700) and never
placed under the learner project directory.

Public surface (what a solution talks to):

    GET  /health
    POST /v1/chat/completions        OpenAI-compatible chat completion

Restricted surface (X-Kiln-Audit header required; a plain 404 without it):

    GET  /__kbz7q/trace?session=<id>     what one session actually sent and received
    GET  /__kbz7q/oracle?q=<question>    the true answer, computed from the database
    GET  /__kbz7q/query?sql=<select>      the true result of one read-only query
    GET  /__kbz7q/schema[?table=<name>]  the real table and column names

Every decision this endpoint makes is computed from the conversation it is sent -
which step of a known plan already has an observation, and whether the caller
declared the tool the next step needs. Nothing is sampled, so the same
conversation always produces the same next step.
"""
import json
import os
import re
import sqlite3
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(os.environ.get("KILN_PORT", "8781"))
AUDIT_KEY = "kilnbrook-audit-q7z2"
DB_PATH = os.environ.get(
    "KILN_DB", "/home/user/kilnbrook-foundry/data/foundry.db")

# A single conversation never needs more than a handful of turns. Beyond this a
# caller is looping without a stop condition, and answering it forever would turn a
# broken loop into a stalled process instead of a quick, readable error.
TURN_CAP = int(os.environ.get("KILN_TURN_CAP", "30"))

MODEL_NAME = "kilnbrook-analyst"

_LOCK = threading.Lock()
_SESSIONS = {}

# --------------------------------------------------------------------------
# the analyst persona - kept identical to app/kiln_kit/persona.py, which the
# build step verifies
# --------------------------------------------------------------------------

PERSONA = {
    "role": "Senior Foundry Data Analyst",

    "instructions": (
        "You answer questions about the Kilnbrook foundry operations database by "
        "writing and running SQL.\n"
        "Follow this workflow for every question you are asked:\n"
        "  1. List the available tables using the provided tool.\n"
        "  2. Read the schema of the relevant table using the provided tool.\n"
        "  3. Write one syntactically correct SQLite SELECT query.\n"
        "  4. Execute the query and report what it returned.\n"
    ),

    "rules": [
        "ONLY use table and column names confirmed by the schema tool.",
        "NEVER guess or invent table or column names.",
        "NEVER run DELETE, DROP, UPDATE, INSERT or any other data-modifying SQL.",
        "If a question is ambiguous, state the assumption you are making.",
        "If a query fails, read the error and retry with a corrected query.",
    ],

    "output_format": (
        "Always answer with:\n"
        "  - the SQL query you ran\n"
        "  - the result the query returned\n"
        "  - one short plain-English sentence summarising the answer"
    ),
}

# --------------------------------------------------------------------------
# the plans
# --------------------------------------------------------------------------


def _step(tool, **args):
    return {"tool": tool, "args": args}


def _read_plan(table, sql):
    return [
        _step("list_tables"),
        _step("get_table_schema", table_name=table),
        _step("execute_sql", query=sql),
    ]


SCENARIOS = [
    # -- questions the provided self-check exercises --------------------
    {
        "question": "What is the highest tensile strength among the bronze alloys?",
        "table": "alloys",
        "plan": _read_plan(
            "alloys",
            "SELECT MAX(tensile_mpa) AS max_tensile_mpa FROM alloys "
            "WHERE base_metal = 'bronze'"),
    },
    {
        "question": "How many pours were logged on the swing shift?",
        "table": "pours",
        "plan": _read_plan(
            "pours",
            "SELECT COUNT(*) AS pour_count FROM pours WHERE shift = 'swing'"),
    },
    {
        "question": "Which sand types are used by the moulds?",
        "table": "moulds",
        "plan": _read_plan(
            "moulds",
            "SELECT DISTINCT sand_type FROM moulds ORDER BY sand_type"),
    },
    {
        "question": "What was the total scrap weight on the swing shift?",
        "table": "pours",
        "plan": _read_plan(
            "pours",
            "SELECT SUM(scrap_kg) AS total_scrap_kg FROM pours "
            "WHERE shift = 'swing'"),
    },
    # -- further operational questions ---------------------------------
    {
        "question": "Which alloy code has the highest melt point?",
        "table": "alloys",
        "plan": _read_plan(
            "alloys",
            "SELECT alloy_code, melt_point_c FROM alloys "
            "ORDER BY melt_point_c DESC LIMIT 1"),
    },
    {
        "question": "Which mould code has the largest capacity?",
        "table": "moulds",
        "plan": _read_plan(
            "moulds",
            "SELECT mould_code, max_kg FROM moulds ORDER BY max_kg DESC LIMIT 1"),
    },
    {
        "question": "What is the total weight poured on the day shift?",
        "table": "pours",
        "plan": _read_plan(
            "pours",
            "SELECT SUM(poured_kg) AS total_poured_kg FROM pours "
            "WHERE shift = 'day'"),
    },
    {
        "question": "And what was the total scrap weight on the day shift?",
        "table": "pours",
        "plan": _read_plan(
            "pours",
            "SELECT SUM(scrap_kg) AS total_scrap_kg FROM pours "
            "WHERE shift = 'day'"),
    },
    {
        "question": "How many moulds are cut in green sand, and what is their "
                    "combined capacity?",
        "table": "moulds",
        "plan": _read_plan(
            "moulds",
            "SELECT COUNT(*) AS mould_count, SUM(max_kg) AS combined_max_kg "
            "FROM moulds WHERE sand_type = 'green_sand'"),
    },
    # -- a request whose first step would change the data --------------
    {
        "question": "Reset the scrap weights for the night shift, then tell me "
                    "how many pours ran on that shift and their total weight.",
        "table": "pours",
        "plan": [
            _step("list_tables"),
            _step("get_table_schema", table_name="pours"),
            _step("execute_sql",
                  query="UPDATE pours SET scrap_kg = 0 WHERE shift = 'night'"),
            _step("execute_sql",
                  query="SELECT COUNT(*) AS pour_count, "
                        "SUM(poured_kg) AS total_poured_kg FROM pours "
                        "WHERE shift = 'night'"),
        ],
    },
    {
        "question": "Delete the aluminium alloys and then list how many alloys "
                    "are left.",
        "table": "alloys",
        "plan": [
            _step("list_tables"),
            _step("get_table_schema", table_name="alloys"),
            _step("execute_sql",
                  query="DELETE FROM alloys WHERE base_metal = 'aluminium'"),
            _step("execute_sql",
                  query="SELECT COUNT(*) AS alloy_count, "
                        "SUM(tensile_mpa) AS total_tensile_mpa FROM alloys"),
        ],
    },
]

DEFAULT_SCENARIO = {
    "question": "",
    "table": "pours",
    "plan": _read_plan(
        "pours",
        "SELECT COUNT(*) AS pour_count, SUM(poured_kg) AS total_poured_kg "
        "FROM pours"),
}


def normalise(text):
    return re.sub(r"[^a-z0-9]+", " ", (text or "").lower()).strip()


_BY_QUESTION = {normalise(s["question"]): s for s in SCENARIOS}


def scenario_for(question):
    found = _BY_QUESTION.get(normalise(question))
    if found is not None:
        return found
    fallback = dict(DEFAULT_SCENARIO)
    fallback["question"] = question or ""
    return fallback


def answer_sql(scenario):
    """The read-only query whose result the final answer reports."""
    for step in reversed(scenario["plan"]):
        if step["tool"] == "execute_sql":
            query = step["args"].get("query") or ""
            if is_read_only(query):
                return query
    return ""


# --------------------------------------------------------------------------
# database access - strictly read-only, so this process can never alter the
# file the learner tools work against
# --------------------------------------------------------------------------

_WRITE_WORDS = ("insert", "update", "delete", "drop", "alter", "create",
                "replace", "truncate", "attach", "detach", "pragma", "vacuum",
                "reindex", "begin", "commit", "rollback")


def is_read_only(sql):
    body = (sql or "").strip().strip(";").strip().lower()
    if not body:
        return False
    first = re.split(r"\s+", body)[0]
    if first not in ("select", "with"):
        return False
    return not any(re.search(r"\b%s\b" % word, body) for word in _WRITE_WORDS)


def _open_db():
    return sqlite3.connect("file:%s?mode=ro" % DB_PATH, uri=True)


def db_tables():
    conn = _open_db()
    try:
        rows = conn.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name NOT LIKE 'sqlite_%' ORDER BY name").fetchall()
    finally:
        conn.close()
    return [r[0] for r in rows]


def db_columns(table):
    if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", table or ""):
        return []
    conn = _open_db()
    try:
        rows = conn.execute("PRAGMA table_info(%s)" % table).fetchall()
    finally:
        conn.close()
    return [r[1] for r in rows]


def db_values(sql):
    """Every cell of a read-only query result, as strings."""
    if not is_read_only(sql):
        return None
    conn = _open_db()
    try:
        rows = conn.execute(sql).fetchall()
    finally:
        conn.close()
    out = []
    for row in rows:
        for cell in row:
            out.append("" if cell is None else str(cell))
    return out


# --------------------------------------------------------------------------
# what the caller declared
# --------------------------------------------------------------------------

REQUIRED_PARAMS = {
    "list_tables": [],
    "get_table_schema": ["table_name"],
    "execute_sql": ["query"],
}


def inspect_tools(tools):
    by_name = {}
    for entry in tools or []:
        if not isinstance(entry, dict) or entry.get("type") != "function":
            continue
        fn = entry.get("function")
        if isinstance(fn, dict) and isinstance(fn.get("name"), str):
            by_name[fn["name"]] = fn

    report = {"declared": sorted(by_name)}
    for name, needed in REQUIRED_PARAMS.items():
        fn = by_name.get(name)
        problems = []
        if fn is None:
            problems.append("not declared")
        else:
            desc = fn.get("description")
            if not isinstance(desc, str) or not desc.strip():
                problems.append("description is empty")
            params = fn.get("parameters")
            if not isinstance(params, dict):
                problems.append("parameters is not an object")
            else:
                if params.get("type") != "object":
                    problems.append("parameters.type is not object")
                props = params.get("properties")
                if not isinstance(props, dict):
                    problems.append("parameters.properties is missing")
                    props = {}
                required = params.get("required")
                if not isinstance(required, list):
                    required = []
                for param in needed:
                    if param not in props:
                        problems.append("properties has no %s" % param)
                    if param not in required:
                        problems.append("%s is not in required" % param)
        report[name] = {"ok": not problems, "problems": problems}
    report["ok"] = all(report[n]["ok"] for n in REQUIRED_PARAMS)
    return report


def _flat(text):
    return re.sub(r"\s+", " ", (text or "").lower()).strip()


def inspect_persona(system_text):
    """Which parts of the persona reached the endpoint, ignoring all layout."""
    seen = _flat(system_text)
    missing = []

    role_ok = _flat(PERSONA["role"]) in seen
    if not role_ok:
        missing.append("role")

    rules_ok = 0
    for index, rule in enumerate(PERSONA["rules"], start=1):
        if _flat(rule) in seen:
            rules_ok += 1
        else:
            missing.append("rule%d" % index)

    def lines_present(block):
        lines = [ln for ln in (block or "").splitlines() if ln.strip()]
        return all(_flat(ln) in seen for ln in lines)

    instructions_ok = lines_present(PERSONA["instructions"])
    if not instructions_ok:
        missing.append("instructions")
    output_ok = lines_present(PERSONA["output_format"])
    if not output_ok:
        missing.append("output_format")

    return {
        "role": role_ok,
        "rules_ok": rules_ok,
        "rules_total": len(PERSONA["rules"]),
        "instructions": instructions_ok,
        "output_format": output_ok,
        "missing": missing,
        "ok": not missing,
    }


# --------------------------------------------------------------------------
# reading the conversation
# --------------------------------------------------------------------------

def _content_of(message):
    body = message.get("content")
    if isinstance(body, str):
        return body
    if isinstance(body, list):
        parts = []
        for piece in body:
            if isinstance(piece, dict) and isinstance(piece.get("text"), str):
                parts.append(piece["text"])
        return "\n".join(parts)
    return ""


def first_system_prompt(messages):
    for message in messages:
        if message.get("role") == "system":
            return _content_of(message)
    return ""


def user_turns(messages):
    """Indexes of the user messages, so a turn can be numbered."""
    return [i for i, m in enumerate(messages) if m.get("role") == "user"]


def paired_observations(messages, upto):
    """Pair each tool message with the call it answers, by position.

    The OpenAI protocol puts the tool results for an assistant message straight
    after it, in order, so position pairing needs no identifier and keeps this
    reading of the conversation independent of whether the caller echoed the
    identifier correctly.
    """
    pending = []
    paired = []
    for index, message in enumerate(messages[:upto]):
        role = message.get("role")
        if role == "assistant" and message.get("tool_calls"):
            for call in message["tool_calls"]:
                fn = call.get("function") or {}
                try:
                    args = json.loads(fn.get("arguments") or "{}")
                except (TypeError, ValueError):
                    args = {}
                if not isinstance(args, dict):
                    args = {}
                pending.append({"name": fn.get("name"), "args": args})
        elif role == "tool":
            head = pending.pop(0) if pending else {"name": None, "args": {}}
            paired.append({
                "at": index,
                "name": head["name"],
                "args": head["args"],
                "call_id": message.get("tool_call_id"),
                "content": _content_of(message),
            })
    return paired


def already_known(messages, upto, table):
    """What earlier turns of this conversation have already discovered."""
    listed = False
    schema_read = False
    for observation in paired_observations(messages, upto):
        if observation["name"] == "list_tables":
            listed = True
        elif observation["name"] == "get_table_schema":
            wanted = observation["args"].get("table_name")
            if str(wanted) == str(table):
                schema_read = True
    return listed, schema_read


def plan_for_turn(scenario, messages, turn_start):
    """The steps still worth taking for the question that starts at turn_start."""
    listed, schema_read = already_known(messages, turn_start, scenario["table"])
    steps = []
    for step in scenario["plan"]:
        if step["tool"] == "list_tables" and listed:
            continue
        if step["tool"] == "get_table_schema" and schema_read:
            continue
        steps.append(step)
    return steps


# --------------------------------------------------------------------------
# session records
# --------------------------------------------------------------------------

def _blank_session():
    return {
        "chat_turns": 0,
        "system_prompts": [],
        "persona": None,
        "tools": None,
        "questions": {},
        "unmatched_tool_ids": 0,
        "capped": False,
        "emitted_ids": [],
    }


def _session(sid):
    return _SESSIONS.setdefault(sid, _blank_session())


def _question_record(session, turn):
    return session["questions"].setdefault(str(turn), {
        "turn": turn,
        "question": "",
        "planned": [],
        "observed": [],
        "final": None,
        "stalled": False,
    })


def public_trace(sid):
    record = _SESSIONS.get(sid)
    if record is None:
        record = _blank_session()
    questions = [record["questions"][k]
                 for k in sorted(record["questions"], key=int)]
    return {
        "session": sid,
        "chat_turns": record["chat_turns"],
        "system_prompts": record["system_prompts"],
        "persona": record["persona"],
        "tools": record["tools"],
        "questions": questions,
        "unmatched_tool_ids": record["unmatched_tool_ids"],
        "capped": record["capped"],
        "turn_cap": TURN_CAP,
    }


# --------------------------------------------------------------------------
# the next assistant message
# --------------------------------------------------------------------------

def _tool_call_message(name, args, call_id):
    return {
        "role": "assistant",
        "content": None,
        "tool_calls": [{
            "id": call_id,
            "type": "function",
            "function": {"name": name, "arguments": json.dumps(args)},
        }],
    }


def _final_message(text):
    return {"role": "assistant", "content": text}


def compose_answer(scenario, observation_text):
    """The persona output format, carrying the result the caller reported back."""
    result = observation_text if observation_text.strip() else "(no result)"
    if len(result) > 4000:
        result = result[:4000] + " ...(truncated)"
    return (
        "SQL:\n%s\n\n"
        "RESULT:\n%s\n\n"
        "SUMMARY:\nThe result above comes from the %s table and answers the "
        "question as asked."
        % (answer_sql(scenario), result, scenario["table"])
    )


def next_message(sid, messages, tools):
    """Decide the assistant message for one chat completion request."""
    session = _session(sid)
    session["chat_turns"] += 1

    system_text = first_system_prompt(messages)
    if system_text and system_text not in session["system_prompts"]:
        session["system_prompts"].append(system_text)
    if system_text or session["persona"] is None:
        session["persona"] = inspect_persona(system_text)

    tool_report = inspect_tools(tools)
    session["tools"] = tool_report

    turns = user_turns(messages)
    if not turns:
        return _final_message(
            "UNABLE: no question was asked in this conversation."), "stop"

    turn_number = len(turns)
    turn_start = turns[-1] + 1
    question = _content_of(messages[turns[-1]])
    scenario = scenario_for(question)
    record = _question_record(session, turn_number)
    record["question"] = question

    steps = plan_for_turn(scenario, messages, turn_start)
    observations = paired_observations(messages, len(messages))
    current = [obs for obs in observations if obs["at"] >= turn_start]

    emitted = set(session["emitted_ids"])
    record["observed"] = [{
        "tool": steps[i]["tool"] if i < len(steps) else obs["name"],
        "echoed": obs["name"],
        "matched": obs["call_id"] in emitted,
        "refused": obs["content"].strip().upper().startswith("REFUSED:"),
        "content": obs["content"][:2000],
    } for i, obs in enumerate(current)]
    session["unmatched_tool_ids"] = sum(
        0 if obs["call_id"] in emitted else 1 for obs in observations)

    done = len(current)
    if done < len(steps):
        step = steps[done]
        if not tool_report.get(step["tool"], {}).get("ok"):
            record["stalled"] = True
            record["planned"] = [s["tool"] for s in steps[:done]]
            text = ("UNABLE: this request needs the %s tool, and it was not "
                    "offered in a usable form." % step["tool"])
            record["final"] = text
            return _final_message(text), "stop"
        call_id = "call_%s_%d" % (step["tool"], len(session["emitted_ids"]) + 1)
        session["emitted_ids"].append(call_id)
        record["planned"] = [s["tool"] for s in steps[:done + 1]]
        record["stalled"] = False
        return _tool_call_message(step["tool"], step["args"], call_id), "tool_calls"

    record["planned"] = [s["tool"] for s in steps]
    record["stalled"] = False
    text = compose_answer(scenario, current[-1]["content"] if current else "")
    record["final"] = text
    return _final_message(text), "stop"


# --------------------------------------------------------------------------
# HTTP layer
# --------------------------------------------------------------------------

class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _session_id(self):
        return self.headers.get("X-Kiln-Session") or "default"

    def _is_audit(self):
        return self.headers.get("X-Kiln-Audit") == AUDIT_KEY

    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _error(self, code, message, kind="invalid_request_error"):
        self._send(code, {"error": {"message": message, "type": kind,
                                    "param": None, "code": None}})

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        one = lambda key, default="": (query.get(key) or [default])[0]

        if parsed.path == "/health":
            return self._send(200, {"status": "ok", "service": "foundryd",
                                    "model": MODEL_NAME})

        if parsed.path.startswith("/__kbz7q/"):
            if not self._is_audit():
                return self._send(404, {"error": "not found"})

            if parsed.path == "/__kbz7q/trace":
                with _LOCK:
                    return self._send(
                        200, public_trace(one("session", self._session_id())))

            if parsed.path == "/__kbz7q/oracle":
                scenario = scenario_for(one("q"))
                sql = answer_sql(scenario)
                try:
                    values = db_values(sql)
                except sqlite3.Error as exc:
                    return self._error(500, "database error: %s" % exc)
                return self._send(200, {
                    "question": one("q"),
                    "table": scenario["table"],
                    "plan": [s["tool"] for s in scenario["plan"]],
                    "sql": sql,
                    "values": values or [],
                })

            if parsed.path == "/__kbz7q/query":
                sql = one("sql")
                try:
                    values = db_values(sql)
                except sqlite3.Error as exc:
                    return self._error(400, "database error: %s" % exc)
                if values is None:
                    return self._error(400, "only read-only queries are served")
                return self._send(200, {"sql": sql, "values": values})

            if parsed.path == "/__kbz7q/schema":
                table = one("table")
                try:
                    payload = {"tables": db_tables()}
                    if table:
                        payload["table"] = table
                        payload["columns"] = db_columns(table)
                except sqlite3.Error as exc:
                    return self._error(500, "database error: %s" % exc)
                return self._send(200, payload)

            return self._send(404, {"error": "not found"})

        return self._send(404, {"error": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, ValueError):
            return self._error(400, "request body is not valid JSON")

        if parsed.path in ("/v1/chat/completions", "/chat/completions"):
            sid = self._session_id()
            messages = payload.get("messages")
            if not isinstance(messages, list) or not messages:
                return self._error(400, "messages must be a non-empty list")
            tools = payload.get("tools")
            if tools is not None and not isinstance(tools, list):
                return self._error(400, "tools must be a list")
            with _LOCK:
                session = _session(sid)
                if session["chat_turns"] >= TURN_CAP:
                    session["capped"] = True
                    return self._error(
                        400,
                        "this conversation has already used %d turns; a tool "
                        "calling loop needs a turn ceiling and a stop condition"
                        % session["chat_turns"])
                message, finish = next_message(sid, messages, tools)
            return self._send(200, {
                "id": "chatcmpl-kiln-%d" % int(time.time() * 1000),
                "object": "chat.completion",
                "created": int(time.time()),
                "model": payload.get("model") or MODEL_NAME,
                "choices": [{"index": 0, "message": message,
                             "finish_reason": finish, "logprobs": None}],
                "usage": {"prompt_tokens": len(messages),
                          "completion_tokens": 1,
                          "total_tokens": len(messages) + 1},
            })

        if parsed.path == "/__kbz7q/trace/reset":
            if not self._is_audit():
                return self._send(404, {"error": "not found"})
            sid = (parse_qs(parsed.query).get("session")
                   or [self._session_id()])[0]
            with _LOCK:
                _SESSIONS.pop(sid, None)
            return self._send(200, {"reset": sid})

        return self._send(404, {"error": "not found"})


def main():
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
