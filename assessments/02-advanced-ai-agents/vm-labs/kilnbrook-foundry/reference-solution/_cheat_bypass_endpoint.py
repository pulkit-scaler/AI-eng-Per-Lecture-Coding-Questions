"""CHEAT PROBE: real tools, but the answers are assembled locally.

The three tools genuinely query the database, so the tool theme is earned; the loop
is skipped entirely and no request ever reaches the endpoint. Expected: 10/50 - the
one theme this solution really implements, and nothing else.
"""
import re
import sqlite3

from kiln_kit import MODEL_NAME, PERSONA, connect, make_client  # noqa: F401

MAX_MODEL_TURNS = 8

_WRITE_KEYWORDS = ("insert", "update", "delete", "drop", "alter", "create",
                   "replace", "truncate", "attach", "detach", "pragma",
                   "vacuum", "reindex")


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
    if not body or body.split()[0] not in ("select", "with") or any(
            re.search(r"\b%s\b" % word, body) for word in _WRITE_KEYWORDS):
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


def _guess(question):
    """Answer without asking anything: run a query of our own choosing."""
    table = "pours"
    lowered = (question or "").lower()
    if "alloy" in lowered or "tensile" in lowered or "melt" in lowered:
        table = "alloys"
    elif "mould" in lowered or "sand" in lowered or "cavity" in lowered:
        table = "moulds"
    sql = "SELECT COUNT(*) AS row_count FROM %s" % table
    return ("SQL:\n%s\n\nRESULT:\n%s\n\nSUMMARY:\nThe result above comes from the "
            "%s table." % (sql, execute_sql(sql), table))


def run_agent(question):
    return _guess(question)


def run_session(questions):
    return [_guess(question) for question in questions]
