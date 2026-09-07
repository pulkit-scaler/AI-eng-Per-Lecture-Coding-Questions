"""Alternative shape 4.

The loop written as a generator that yields each turn, consumed by a thin caller; the
schema discovered from cursor.description rather than a PRAGMA; the read-only guard
built from a token whitelist; rows rendered as key=value pairs.
"""
import itertools
import json

from kiln_kit import MODEL_NAME, PERSONA, connect, make_client

MAX_MODEL_TURNS = 8

ALLOWED_FIRST_WORDS = ("select", "with")
FORBIDDEN = ("insert", "update", "delete", "drop", "alter", "create", "replace",
             "truncate", "attach", "detach", "pragma", "vacuum", "reindex")


def build_system_prompt(persona):
    header = "%s -- system prompt" % persona["role"]
    return "\n".join([
        header,
        "=" * len(header),
        "You are a %s." % persona["role"],
        "",
        persona["instructions"].rstrip(),
        "",
        "Rules:",
        "\n".join("  %s" % rule for rule in persona["rules"]),
        "",
        persona["output_format"].rstrip(),
    ])


def _function(name, description, properties, required):
    return {"type": "function",
            "function": {"name": name, "description": description,
                         "parameters": {"type": "object",
                                        "properties": properties,
                                        "required": list(required)}}}


def build_tools_schema():
    return [
        _function("list_tables",
                  "Which tables the foundry database contains.", {}, ()),
        _function("get_table_schema",
                  "Which columns a named foundry table contains.",
                  {"table_name": {"type": "string",
                                  "description": "the table to describe"}},
                  ("table_name",)),
        _function("execute_sql",
                  "Execute one read-only SELECT and hand back its rows.",
                  {"query": {"type": "string",
                             "description": "the SELECT statement to run"}},
                  ("query",)),
    ]


def _describe(cursor):
    return [column[0] for column in (cursor.description or [])]


def list_tables():
    conn = connect()
    try:
        rows = conn.execute("SELECT name, type FROM sqlite_master").fetchall()
    finally:
        conn.close()
    names = [name for name, kind in rows
             if kind == "table" and not name.startswith("sqlite_")]
    return sorted(names)


def get_table_schema(table_name):
    if table_name not in list_tables():
        return []
    conn = connect()
    try:
        return _describe(conn.execute("SELECT * FROM %s WHERE 1 = 0"
                                      % table_name))
    finally:
        conn.close()


def _permitted(query):
    tokens = [token.strip("(),;").lower() for token in (query or "").split()]
    if not tokens or tokens[0] not in ALLOWED_FIRST_WORDS:
        return False
    return not any(token in FORBIDDEN for token in tokens)


def execute_sql(query):
    if not _permitted(query):
        return ("REFUSED: the foundry database is read-only to this agent, so the "
                "statement was rejected.")
    conn = connect()
    try:
        cursor = conn.execute(query)
        names = _describe(cursor)
        rows = cursor.fetchall()
    except Exception as exc:                          # noqa: BLE001
        return "ERROR: %s" % exc
    finally:
        conn.close()
    if not rows:
        return "(no rows)"
    return "\n".join(
        "; ".join("%s=%s" % (name, "" if value is None else value)
                  for name, value in zip(names, row))
        for row in rows)


DISPATCH = dict(zip(("list_tables", "get_table_schema", "execute_sql"),
                    (list_tables, get_table_schema, execute_sql)))


def turns(client, messages, tools):
    """Yield each assistant message, stopping when one carries no tool calls."""
    for _ in itertools.repeat(None, MAX_MODEL_TURNS):
        message = client.chat.completions.create(
            model=MODEL_NAME,
            messages=messages,
            tools=tools,
            tool_choice="auto",
            temperature=0.0,
        ).choices[0].message
        messages.append(json.loads(message.model_dump_json(exclude_none=True)))
        yield message
        if not message.tool_calls:
            return
        for call in message.tool_calls:
            handler = DISPATCH.get(call.function.name)
            payload = json.loads(call.function.arguments or "{}")
            observed = (handler(**payload) if handler
                        else "ERROR: unknown tool %s" % call.function.name)
            messages.append({"role": "tool", "tool_call_id": call.id,
                             "content": observed if isinstance(observed, str)
                                        else json.dumps(observed)})


def _drive(client, messages, question):
    messages.append({"role": "user", "content": question})
    answer = "STOPPED: the turn ceiling of %d was reached." % MAX_MODEL_TURNS
    for message in turns(client, messages, build_tools_schema()):
        if not message.tool_calls:
            answer = message.content or ""
    return answer


def run_agent(question):
    return _drive(make_client(),
                  [{"role": "system", "content": build_system_prompt(PERSONA)}],
                  question)


def run_session(questions):
    client = make_client()
    messages = [{"role": "system", "content": build_system_prompt(PERSONA)}]
    return [_drive(client, messages, question) for question in questions]
