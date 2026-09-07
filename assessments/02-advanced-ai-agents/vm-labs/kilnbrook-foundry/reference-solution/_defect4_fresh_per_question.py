"""DEFECT PROBE: run_session starts a fresh conversation per question.

Expected: loses TC04 only.

Original docstring below.

Kilnbrook Foundry analyst agent - model answer.

The five components, in order: the persona rendered into a system prompt, the tool
schemas the model is offered, the three tools that do the real database work, the
reason/act/observe loop, and one shared message list that carries a session.
"""
import json
import re
import sqlite3

from kiln_kit import MODEL_NAME, PERSONA, connect, make_client

# The most model turns one question may take. A correct run needs four; anything
# past this ceiling is a loop with no stop condition, and it must end cleanly.
MAX_MODEL_TURNS = 8


# ---------------------------------------------------------------- component 1
def build_system_prompt(persona):
    """Render the persona dictionary into the system prompt string."""
    rules = "\n".join("  - %s" % rule for rule in persona["rules"])
    return (
        "You are a %s.\n\n"
        "INSTRUCTIONS:\n%s\n"
        "RULES:\n%s\n\n"
        "OUTPUT FORMAT:\n%s"
        % (persona["role"], persona["instructions"], rules,
           persona["output_format"])
    )


# ---------------------------------------------------------------- component 4
def build_tools_schema():
    """The three tools, in the format the chat completions API expects."""
    return [
        {
            "type": "function",
            "function": {
                "name": "list_tables",
                "description": ("List every table in the foundry operations "
                                "database. Call this first to discover what "
                                "data exists."),
                "parameters": {
                    "type": "object",
                    "properties": {},
                    "required": [],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "get_table_schema",
                "description": ("Return the column names of one table. Call "
                                "this after choosing the table a question "
                                "needs."),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "table_name": {
                            "type": "string",
                            "description": "The exact name of the table to inspect",
                        },
                    },
                    "required": ["table_name"],
                },
            },
        },
        {
            "type": "function",
            "function": {
                "name": "execute_sql",
                "description": ("Run one read-only SQLite SELECT query against "
                                "the foundry database and return the rows it "
                                "produced."),
                "parameters": {
                    "type": "object",
                    "properties": {
                        "query": {
                            "type": "string",
                            "description": "A valid SQLite SELECT query",
                        },
                    },
                    "required": ["query"],
                },
            },
        },
    ]


# ----------------------------------------------------------------- the tools
_WRITE_KEYWORDS = (
    "insert", "update", "delete", "drop", "alter", "create", "replace",
    "truncate", "attach", "detach", "pragma", "vacuum", "reindex",
)

_TABLE_NAME = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def _is_read_only(query):
    body = (query or "").strip().rstrip(";").strip()
    if not body:
        return False
    lowered = body.lower()
    if lowered.split()[0] not in ("select", "with"):
        return False
    return not any(re.search(r"\b%s\b" % word, lowered)
                   for word in _WRITE_KEYWORDS)


def list_tables():
    """Every table name in the foundry operations database."""
    conn = connect()
    try:
        rows = conn.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name NOT LIKE 'sqlite_%' ORDER BY name").fetchall()
    finally:
        conn.close()
    return [row[0] for row in rows]


def get_table_schema(table_name):
    """The column names of one table, or an empty list if there is no such table."""
    name = str(table_name or "")
    if not _TABLE_NAME.match(name) or name not in list_tables():
        return []
    conn = connect()
    try:
        rows = conn.execute("PRAGMA table_info(%s)" % name).fetchall()
    finally:
        conn.close()
    return [row[1] for row in rows]


def execute_sql(query):
    """Run a read-only query and return its rows as text.

    Anything that would change the data is refused instead of run.
    """
    if not _is_read_only(query):
        return ("REFUSED: only read-only SELECT queries may be run against the "
                "foundry database, so this statement was not executed.")
    conn = connect()
    try:
        cursor = conn.execute(query)
        headers = [column[0] for column in (cursor.description or [])]
        rows = cursor.fetchall()
    except sqlite3.Error as exc:
        return "ERROR: %s" % exc
    finally:
        conn.close()
    if not rows:
        return "(no rows)"
    lines = [" | ".join(headers)]
    for row in rows:
        lines.append(" | ".join(
            "" if value is None else str(value) for value in row))
    return "\n".join(lines)


TOOL_FUNCTIONS = {
    "list_tables": list_tables,
    "get_table_schema": get_table_schema,
    "execute_sql": execute_sql,
}


# ---------------------------------------------------------- components 3 and 5
def _run_turns(client, messages, tools, question):
    """Reason, act and observe on one message list until the model stops."""
    messages.append({"role": "user", "content": question})

    for _ in range(MAX_MODEL_TURNS):
        response = client.chat.completions.create(
            model=MODEL_NAME,
            temperature=0.0,
            messages=messages,
            tools=tools,
            tool_choice="auto",
        )
        message = response.choices[0].message
        messages.append(message.model_dump(exclude_none=True))

        calls = message.tool_calls or []
        if not calls:
            return message.content or ""

        for call in calls:
            name = call.function.name
            try:
                args = json.loads(call.function.arguments or "{}")
            except ValueError:
                args = {}
            function = TOOL_FUNCTIONS.get(name)
            if function is None:
                result = "ERROR: there is no tool named %s" % name
            else:
                result = function(**args)
            if not isinstance(result, str):
                result = json.dumps(result)
            messages.append({
                "role": "tool",
                "tool_call_id": call.id,
                "content": result,
            })

    return ("STOPPED: the ceiling of %d model turns was reached without a final "
            "answer." % MAX_MODEL_TURNS)


def _fresh_messages():
    return [{"role": "system", "content": build_system_prompt(PERSONA)}]


def run_agent(question):
    """Answer one question from a conversation of its own."""
    client = make_client()
    return _run_turns(client, _fresh_messages(), build_tools_schema(), question)


def run_session(questions):
    """Answer several questions on one shared message list."""
    return [run_agent(question) for question in questions]
