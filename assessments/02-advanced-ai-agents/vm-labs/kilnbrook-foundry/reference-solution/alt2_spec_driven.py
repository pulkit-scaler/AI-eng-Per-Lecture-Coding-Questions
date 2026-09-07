"""Alternative shape 2.

Tool schemas generated from a declarative spec table, the prompt assembled with an
f-string using different headings, rows returned as JSON, the loop written as a
bounded for-range, and the assistant message rebuilt field by field.
"""
import json
import re

from kiln_kit import MODEL_NAME, PERSONA, connect, make_client

MAX_MODEL_TURNS = 8

TOOL_SPECS = (
    ("list_tables",
     "Return the name of every table in the foundry operations database.",
     ()),
    ("get_table_schema",
     "Return the columns of a single table, so that a query only uses names that "
     "really exist.",
     (("table_name", "the table whose columns are wanted"),)),
    ("execute_sql",
     "Run a single read-only SELECT statement and return the rows it produced.",
     (("query", "a read-only SQLite SELECT statement"),)),
)

READ_HEAD = re.compile(r"^\s*(select|with)\b", re.IGNORECASE)
WRITE_WORD = re.compile(
    r"\b(insert|update|delete|drop|alter|create|replace|truncate|attach|detach"
    r"|pragma|vacuum|reindex)\b", re.IGNORECASE)


def build_system_prompt(persona):
    numbered = "\n".join("%d) %s" % (n, rule)
                         for n, rule in enumerate(persona["rules"], start=1))
    return (
        f"# Who you are\nYou are a {persona['role']}.\n\n"
        f"# What to do\n{persona['instructions']}\n"
        f"# What you must never do\n{numbered}\n\n"
        f"# Shape of every answer\n{persona['output_format']}\n"
    )


def build_tools_schema():
    schemas = []
    for name, description, params in TOOL_SPECS:
        properties = {key: {"type": "string", "description": text}
                      for key, text in params}
        schemas.append({
            "type": "function",
            "function": {
                "name": name,
                "description": description,
                "parameters": {
                    "type": "object",
                    "properties": properties,
                    "required": [key for key, _ in params],
                },
            },
        })
    return schemas


def _all_tables(conn):
    return [row[0] for row in conn.execute(
        "SELECT name FROM sqlite_master WHERE type='table' AND "
        "name NOT LIKE 'sqlite%' ORDER BY 1")]


def list_tables():
    conn = connect()
    try:
        return _all_tables(conn)
    finally:
        conn.close()


def get_table_schema(table_name):
    conn = connect()
    try:
        if table_name not in _all_tables(conn):
            return []
        return [row[1] for row in conn.execute(
            "PRAGMA table_info('%s')" % str(table_name).replace("'", ""))]
    finally:
        conn.close()


def execute_sql(query):
    text = query or ""
    if not READ_HEAD.match(text) or WRITE_WORD.search(text):
        return ("REFUSED: this agent runs SELECT statements only, so nothing was "
                "executed.")
    conn = connect()
    try:
        cursor = conn.execute(text)
        names = [column[0] for column in (cursor.description or [])]
        payload = [dict(zip(names, row)) for row in cursor.fetchall()]
    except Exception as exc:                          # noqa: BLE001
        return "ERROR: %s" % exc
    finally:
        conn.close()
    return json.dumps(payload) if payload else "(no rows)"


HANDLERS = {"list_tables": list_tables,
            "get_table_schema": get_table_schema,
            "execute_sql": execute_sql}


def _assistant_dict(message):
    entry = {"role": "assistant"}
    if message.content is not None:
        entry["content"] = message.content
    if message.tool_calls:
        entry["tool_calls"] = [{
            "id": call.id,
            "type": "function",
            "function": {"name": call.function.name,
                         "arguments": call.function.arguments},
        } for call in message.tool_calls]
    return entry


def _ask(client, history, question):
    history.append({"role": "user", "content": question})
    for _ in range(MAX_MODEL_TURNS):
        completion = client.chat.completions.create(
            model=MODEL_NAME,
            messages=history,
            tools=build_tools_schema(),
            tool_choice="auto",
        )
        message = completion.choices[0].message
        history.append(_assistant_dict(message))
        calls = list(message.tool_calls or [])
        if not calls:
            return message.content or ""
        for call in calls:
            handler = HANDLERS[call.function.name]
            kwargs = json.loads(call.function.arguments or "{}")
            history.append({"role": "tool",
                            "tool_call_id": call.id,
                            "content": str(handler(**kwargs))})
    return "STOPPED: no answer within %d model turns." % MAX_MODEL_TURNS


def run_agent(question):
    history = [{"role": "system", "content": build_system_prompt(PERSONA)}]
    return _ask(make_client(), history, question)


def run_session(questions):
    client = make_client()
    history = [{"role": "system", "content": build_system_prompt(PERSONA)}]
    return [_ask(client, history, question) for question in questions]
