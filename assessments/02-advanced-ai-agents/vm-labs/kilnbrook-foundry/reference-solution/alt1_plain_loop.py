"""Alternative shape 1.

A different prompt layout (sections reordered, rules bulleted with asterisks), a
while loop with an explicit turn counter, tool schemas produced by a small factory,
CSV rendering of rows, and the assistant message appended with to_dict().
"""
import csv
import io
import json

from kiln_kit import MODEL_NAME, PERSONA, connect, make_client

MAX_MODEL_TURNS = 8

BLOCKED_WORDS = {
    "insert", "update", "delete", "drop", "alter", "create", "replace",
    "truncate", "attach", "detach", "pragma", "vacuum", "reindex", "begin",
    "commit", "rollback",
}


def build_system_prompt(persona):
    parts = ["ROLE", "You are a %s." % persona["role"], "",
             "OUTPUT FORMAT", persona["output_format"], "",
             "HOW TO WORK", persona["instructions"], "HARD RULES"]
    parts.extend("* %s" % rule for rule in persona["rules"])
    return "\n".join(parts)


def _tool(name, description, properties, required):
    return {
        "type": "function",
        "function": {
            "name": name,
            "description": description,
            "parameters": {
                "type": "object",
                "properties": properties,
                "required": required,
            },
        },
    }


def build_tools_schema():
    return [
        _tool("list_tables",
              "Names every table held in the foundry operations database.",
              {}, []),
        _tool("get_table_schema",
              "Lists the columns of one foundry table so a query can be written "
              "against real column names.",
              {"table_name": {"type": "string",
                              "description": "Name of the table to inspect"}},
              ["table_name"]),
        _tool("execute_sql",
              "Runs one read-only SQLite SELECT statement and returns the rows.",
              {"query": {"type": "string",
                         "description": "The SELECT statement to run"}},
              ["query"]),
    ]


def list_tables():
    with connect() as conn:
        cursor = conn.execute(
            "SELECT tbl_name FROM sqlite_master WHERE type = 'table' "
            "ORDER BY tbl_name")
        return [row[0] for row in cursor if not row[0].startswith("sqlite_")]


def get_table_schema(table_name):
    if table_name not in list_tables():
        return []
    with connect() as conn:
        cursor = conn.execute("SELECT * FROM %s LIMIT 0" % table_name)
        return [column[0] for column in cursor.description]


def _refuses(query):
    words = set(w.strip("();,").lower() for w in (query or "").split())
    if not words:
        return True
    head = (query or "").strip().lower()
    if not (head.startswith("select") or head.startswith("with")):
        return True
    return bool(words & BLOCKED_WORDS)


def execute_sql(query):
    if _refuses(query):
        return ("REFUSED: that statement would change the foundry data, and this "
                "agent may only read it.")
    with connect() as conn:
        try:
            cursor = conn.execute(query)
            names = [column[0] for column in (cursor.description or [])]
            rows = cursor.fetchall()
        except Exception as exc:                      # noqa: BLE001
            return "ERROR: %s" % exc
    buffer = io.StringIO()
    writer = csv.writer(buffer)
    writer.writerow(names)
    for row in rows:
        writer.writerow(["" if cell is None else cell for cell in row])
    return buffer.getvalue().strip() or "(no rows)"


def _tool_map():
    return {"list_tables": list_tables,
            "get_table_schema": get_table_schema,
            "execute_sql": execute_sql}


def _converse(client, messages, question):
    tools = build_tools_schema()
    lookup = _tool_map()
    messages.append({"role": "user", "content": question})
    turn = 0
    while turn < MAX_MODEL_TURNS:
        turn += 1
        reply = client.chat.completions.create(
            model=MODEL_NAME,
            messages=messages,
            tools=tools,
            tool_choice="auto",
            temperature=0.0,
        ).choices[0].message
        messages.append(reply.to_dict())
        if not reply.tool_calls:
            return reply.content or ""
        for call in reply.tool_calls:
            arguments = json.loads(call.function.arguments or "{}")
            outcome = lookup[call.function.name](**arguments)
            messages.append({
                "role": "tool",
                "tool_call_id": call.id,
                "content": outcome if isinstance(outcome, str)
                           else json.dumps(outcome),
            })
    return "STOPPED: reached the ceiling of %d model turns." % MAX_MODEL_TURNS


def run_agent(question):
    return _converse(
        make_client(),
        [{"role": "system", "content": build_system_prompt(PERSONA)}],
        question)


def run_session(questions):
    client = make_client()
    history = [{"role": "system", "content": build_system_prompt(PERSONA)}]
    replies = []
    for question in questions:
        replies.append(_converse(client, history, question))
    return replies
