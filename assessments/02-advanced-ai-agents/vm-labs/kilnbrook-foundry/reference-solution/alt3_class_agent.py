"""Alternative shape 3.

The agent as a class that owns its client and its message list, sqlite3.Row as the
row factory, an aligned column rendering, and run_session reusing one instance so
the conversation is the instance state rather than a passed-around list.
"""
import json
import sqlite3

from kiln_kit import MODEL_NAME, PERSONA, connect, make_client

MAX_MODEL_TURNS = 8

_WRITE = ("insert ", "update ", "delete ", "drop ", "alter ", "create ",
          "replace ", "truncate ", "attach ", "detach ", "pragma ", "vacuum",
          "reindex")


def build_system_prompt(persona):
    lines = [
        "SYSTEM BRIEF",
        "",
        "You are a %s." % persona["role"],
        "",
        "INSTRUCTIONS",
        persona["instructions"].rstrip(),
        "",
        "RULES YOU MAY NOT BREAK",
    ]
    lines += ["    %d. %s" % (n, r)
              for n, r in enumerate(persona["rules"], start=1)]
    lines += ["", "OUTPUT FORMAT", persona["output_format"].rstrip(), ""]
    return "\n".join(lines)


def build_tools_schema():
    return [
        {"type": "function", "function": {
            "name": "list_tables",
            "description": "Discover the tables in the foundry database.",
            "parameters": {"type": "object", "properties": {}, "required": []}}},
        {"type": "function", "function": {
            "name": "get_table_schema",
            "description": "Read the column names of one foundry table.",
            "parameters": {
                "type": "object",
                "properties": {"table_name": {
                    "type": "string",
                    "description": "Table to describe, exactly as it is named"}},
                "required": ["table_name"]}}},
        {"type": "function", "function": {
            "name": "execute_sql",
            "description": "Run a read-only SELECT against the foundry database.",
            "parameters": {
                "type": "object",
                "properties": {"query": {
                    "type": "string",
                    "description": "SQLite SELECT statement"}},
                "required": ["query"]}}},
    ]


def _rows(query, args=()):
    conn = connect()
    conn.row_factory = sqlite3.Row
    try:
        return conn.execute(query, args).fetchall()
    finally:
        conn.close()


def list_tables():
    found = _rows("SELECT name FROM sqlite_master WHERE type = ? ORDER BY name",
                  ("table",))
    return [row["name"] for row in found if not row["name"].startswith("sqlite_")]


def get_table_schema(table_name):
    if table_name not in list_tables():
        return []
    return [row["name"] for row in _rows("PRAGMA table_info(%s)" % table_name)]


def execute_sql(query):
    body = (query or "").strip().lower()
    if not body.startswith(("select", "with")) or any(w in body for w in _WRITE):
        return ("REFUSED: only SELECT statements are permitted here, so the "
                "statement was not run.")
    try:
        found = _rows(query)
    except sqlite3.Error as exc:
        return "ERROR: %s" % exc
    if not found:
        return "(no rows)"
    headers = list(found[0].keys())
    table = [headers] + [["" if row[h] is None else str(row[h])
                          for h in headers] for row in found]
    widths = [max(len(row[i]) for row in table) for i in range(len(headers))]
    return "\n".join("  ".join(cell.ljust(widths[i])
                               for i, cell in enumerate(row)).rstrip()
                     for row in table)


class FoundryAgent:
    """One conversation with the analyst endpoint."""

    tools = {"list_tables": list_tables,
             "get_table_schema": get_table_schema,
             "execute_sql": execute_sql}

    def __init__(self):
        self.client = make_client()
        self.schema = build_tools_schema()
        self.messages = [{"role": "system",
                          "content": build_system_prompt(PERSONA)}]

    def _observe(self, call):
        function = self.tools.get(call.function.name)
        if function is None:
            return "ERROR: unknown tool %s" % call.function.name
        try:
            arguments = json.loads(call.function.arguments or "{}")
        except ValueError:
            arguments = {}
        result = function(**arguments)
        return result if isinstance(result, str) else json.dumps(result)

    def ask(self, question):
        self.messages.append({"role": "user", "content": question})
        for _ in range(MAX_MODEL_TURNS):
            message = self.client.chat.completions.create(
                model=MODEL_NAME,
                temperature=0.0,
                messages=self.messages,
                tools=self.schema,
                tool_choice="auto",
            ).choices[0].message
            self.messages.append(message.model_dump(exclude_none=True))
            if not message.tool_calls:
                return message.content or ""
            for call in message.tool_calls:
                self.messages.append({"role": "tool",
                                      "tool_call_id": call.id,
                                      "content": self._observe(call)})
        return "STOPPED: %d model turns were not enough." % MAX_MODEL_TURNS


def run_agent(question):
    return FoundryAgent().ask(question)


def run_session(questions):
    agent = FoundryAgent()
    return [agent.ask(question) for question in questions]
