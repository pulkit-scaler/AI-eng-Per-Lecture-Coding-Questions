"""Alternative shape 5.

The loop expressed as recursion with a depth argument instead of iteration, the
persona flattened into one paragraph-per-section string, tool schemas held as a
module constant rather than rebuilt, the guard implemented as a statement-count
check plus a keyword scan, and rows rendered as a markdown-ish table.
"""
import json

from kiln_kit import MODEL_NAME, PERSONA, connect, make_client

MAX_MODEL_TURNS = 8

_MUTATORS = frozenset({
    "insert", "update", "delete", "drop", "alter", "create", "replace",
    "truncate", "attach", "detach", "pragma", "vacuum", "reindex",
})


def build_system_prompt(persona):
    return (
        "Identity: you are a " + persona["role"] + ".\n\n"
        + persona["instructions"]
        + "\nRules that always apply:\n"
        + "".join("- " + rule + "\n" for rule in persona["rules"])
        + "\n" + persona["output_format"] + "\n"
    )


TOOLS_SCHEMA = [
    {
        "type": "function",
        "function": {
            "name": "list_tables",
            "description": "Every table name available in the foundry database.",
            "parameters": {"type": "object", "properties": {}},
        },
    },
    {
        "type": "function",
        "function": {
            "name": "get_table_schema",
            "description": "The columns of one foundry table, in declared order.",
            "parameters": {
                "type": "object",
                "properties": {
                    "table_name": {"type": "string",
                                   "description": "which table to describe"},
                },
                "required": ["table_name"],
            },
        },
    },
    {
        "type": "function",
        "function": {
            "name": "execute_sql",
            "description": "Runs a read-only SELECT and returns the resulting rows.",
            "parameters": {
                "type": "object",
                "properties": {
                    "query": {"type": "string",
                              "description": "one SQLite SELECT statement"},
                },
                "required": ["query"],
            },
        },
    },
]


def build_tools_schema():
    return [json.loads(json.dumps(entry)) for entry in TOOLS_SCHEMA]


def _fetch(query):
    conn = connect()
    try:
        cursor = conn.execute(query)
        return [c[0] for c in (cursor.description or [])], cursor.fetchall()
    finally:
        conn.close()


def list_tables():
    _, rows = _fetch("SELECT name FROM sqlite_master "
                     "WHERE type = 'table' AND name NOT GLOB 'sqlite_*' "
                     "ORDER BY name ASC")
    return [row[0] for row in rows]


def get_table_schema(table_name):
    if str(table_name) not in list_tables():
        return []
    _, rows = _fetch("PRAGMA table_info(%s)" % table_name)
    return [row[1] for row in rows]


def _reads_only(query):
    statements = [part for part in (query or "").split(";") if part.strip()]
    if len(statements) != 1:
        return False
    words = statements[0].lower().replace("(", " ").replace(")", " ").split()
    if not words or words[0] not in ("select", "with"):
        return False
    return _MUTATORS.isdisjoint(words)


def execute_sql(query):
    if not _reads_only(query):
        return ("REFUSED: this analyst may read the foundry data but never change "
                "it, so nothing was executed.")
    try:
        names, rows = _fetch(query)
    except Exception as exc:                          # noqa: BLE001
        return "ERROR: %s" % exc
    if not rows:
        return "(no rows)"
    out = ["| " + " | ".join(names) + " |",
           "|" + "|".join(["---"] * len(names)) + "|"]
    for row in rows:
        out.append("| " + " | ".join(
            "" if cell is None else str(cell) for cell in row) + " |")
    return "\n".join(out)


TOOL_FUNCTIONS = {name: value for name, value in
                  (("list_tables", list_tables),
                   ("get_table_schema", get_table_schema),
                   ("execute_sql", execute_sql))}


def _step(client, messages, tools, depth):
    if depth <= 0:
        return "STOPPED: the model turn ceiling was reached with no final answer."
    message = client.chat.completions.create(
        model=MODEL_NAME,
        messages=messages,
        tools=tools,
        tool_choice="auto",
    ).choices[0].message
    messages.append(message.to_dict())
    if not message.tool_calls:
        return message.content or ""
    for call in message.tool_calls:
        arguments = json.loads(call.function.arguments or "{}")
        value = TOOL_FUNCTIONS[call.function.name](**arguments)
        messages.append({"role": "tool", "tool_call_id": call.id,
                         "content": value if isinstance(value, str)
                                    else json.dumps(value)})
    return _step(client, messages, tools, depth - 1)


def run_agent(question):
    messages = [{"role": "system", "content": build_system_prompt(PERSONA)},
                {"role": "user", "content": question}]
    return _step(make_client(), messages, build_tools_schema(), MAX_MODEL_TURNS)


def run_session(questions):
    client = make_client()
    tools = build_tools_schema()
    messages = [{"role": "system", "content": build_system_prompt(PERSONA)}]
    answers = []
    for question in questions:
        messages.append({"role": "user", "content": question})
        answers.append(_step(client, messages, tools, MAX_MODEL_TURNS))
    return answers
