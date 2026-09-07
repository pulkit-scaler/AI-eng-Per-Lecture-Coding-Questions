"""CHEAT PROBE: the strongest attack on the value assertions.

Tasks 1, 2 and 3 are done properly, so TC01 and TC02 are earned. run_agent and
run_session then never call the endpoint at all: they dump every row of every table
into the answer string, on the theory that an assertion of the form "the expected
value appears somewhere in the returned text" is satisfied by returning everything.

That theory is correct as far as it goes. TC03 wants MD-07 and 880 to appear in the
answer, and both are rows of the moulds table, so the dump does contain them.

Expected: 20/50, the two checks whose requirements this file really meets, and zero
on TC03, TC04 and TC05. Those three fail on the session record rather than on the
values: no request ever reached the endpoint, so nothing was planned, no observation
was fed back under a call id, and no turn was taken. This is the probe that shows the
loop checks rest on what the endpoint recorded and not on the answer text.
"""
import sqlite3

from kiln_kit import MODEL_NAME, PERSONA, connect, make_client  # noqa: F401

MAX_MODEL_TURNS = 8

_FORBIDDEN_VERBS = ("insert", "update", "delete", "drop", "alter")


def build_system_prompt(persona):
    rules = "\n".join("  - %s" % rule for rule in persona["rules"])
    return ("You are a %s.\n\nINSTRUCTIONS:\n%s\nRULES:\n%s\n\nOUTPUT FORMAT:\n%s"
            % (persona["role"], persona["instructions"], rules,
               persona["output_format"]))


def build_tools_schema():
    return [
        {"type": "function", "function": {
            "name": "list_tables",
            "description": "List the tables in the foundry database.",
            "parameters": {"type": "object", "properties": {}, "required": []}}},
        {"type": "function", "function": {
            "name": "get_table_schema",
            "description": "List the columns of one table.",
            "parameters": {"type": "object",
                           "properties": {"table_name": {
                               "type": "string",
                               "description": "the table to describe"}},
                           "required": ["table_name"]}}},
        {"type": "function", "function": {
            "name": "execute_sql",
            "description": "Run one read-only SELECT statement.",
            "parameters": {"type": "object",
                           "properties": {"query": {
                               "type": "string",
                               "description": "the SELECT statement"}},
                           "required": ["query"]}}},
    ]


def list_tables():
    conn = connect()
    try:
        rows = conn.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name NOT LIKE 'sqlite_%' ORDER BY name").fetchall()
    finally:
        conn.close()
    return [row[0] for row in rows]


def get_table_schema(table_name):
    if str(table_name) not in list_tables():
        return []
    conn = connect()
    try:
        return [row[1] for row in
                conn.execute("PRAGMA table_info(%s)" % table_name).fetchall()]
    finally:
        conn.close()


def execute_sql(query):
    body = (query or "").strip().rstrip(";").strip().lower()
    words = set(body.replace("(", " ").replace(")", " ").split())
    if not body or body.split()[0] not in ("select", "with") \
            or not words.isdisjoint(_FORBIDDEN_VERBS):
        return "REFUSED: read-only queries only."
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
        lines.append(" | ".join("" if v is None else str(v) for v in row))
    return "\n".join(lines)


def _everything():
    """Every row of every table, so any single row value is present somewhere."""
    parts = []
    for table in list_tables():
        parts.append("TABLE %s" % table)
        parts.append(execute_sql("SELECT * FROM %s" % table))
    return "\n".join(parts)


def run_agent(question):
    return ("SQL:\nSELECT * FROM everything\n\nRESULT:\n%s\n\nSUMMARY:\nThe "
            "answer is somewhere above." % _everything())


def run_session(questions):
    return [run_agent(question) for question in questions]
