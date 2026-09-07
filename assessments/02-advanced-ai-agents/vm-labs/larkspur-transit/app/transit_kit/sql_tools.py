"""The three database operations the Larkspur operations desk offers.

Provided, do not modify.

These are plain Python functions - no protocol, no decorators. They discover
tables, describe one table, and run a read-only query, and they validate
everything that reaches them:

* ``get_table_schema`` accepts only a valid SQL identifier, and only a table on
  the published allowlist. A table that exists in the file but is not on the
  allowlist is refused just the same.
* ``execute_sql`` accepts only read queries. Any data-modifying keyword is
  refused before the database is touched.

Both guards raise :class:`ValueError` with a message describing what was wrong,
so whatever is calling them can report the refusal and try something else.
"""
import re
import sqlite3
from typing import Any, Dict, List

from . import audit
from .db import connect

# The tables this desk publishes. Anything else is refused, whether or not it
# happens to exist in the file.
ALLOWED_TABLES = ("routes", "trips", "vehicles")

IDENTIFIER_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

FORBIDDEN_KEYWORDS = (
    "INSERT", "UPDATE", "DELETE", "DROP", "ALTER", "CREATE",
    "TRUNCATE", "REPLACE", "ATTACH", "DETACH", "VACUUM", "PRAGMA",
)

MIN_COLUMN_WIDTH = 8


def list_tables() -> List[str]:
    """Return every table name in the operations database, sorted."""
    audit.record("list_tables")
    conn = connect()
    try:
        cur = conn.cursor()
        cur.execute(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name NOT LIKE 'sqlite_%' ORDER BY name;"
        )
        return [row[0] for row in cur.fetchall()]
    finally:
        conn.close()


def get_table_schema(table_name: str) -> List[Dict[str, Any]]:
    """Return the columns of one table: name, type, nullability, primary key."""
    if not isinstance(table_name, str) or not IDENTIFIER_RE.match(table_name):
        raise ValueError("Invalid table name: %r" % (table_name,))
    if table_name.lower() not in ALLOWED_TABLES:
        raise ValueError(
            "Table %r is not available here. Available tables: %s"
            % (table_name, ", ".join(ALLOWED_TABLES))
        )

    audit.record("get_table_schema", table_name)
    conn = connect()
    try:
        cur = conn.cursor()
        cur.execute("PRAGMA table_info(`%s`);" % table_name)
        rows = cur.fetchall()
        if not rows:
            raise ValueError(
                "Table %r not found in the operations database." % (table_name,)
            )
        return [
            {
                "name": row[1],
                "type": row[2],
                "nullable": not row[3],
                "primary_key": bool(row[5]),
            }
            for row in rows
        ]
    finally:
        conn.close()


def execute_sql(query: str) -> str:
    """Run one read-only SQL query and return the rows as a formatted table."""
    if not isinstance(query, str) or not query.strip():
        raise ValueError("An empty query cannot be run.")

    normalized = " %s " % query.strip().upper()
    for keyword in FORBIDDEN_KEYWORDS:
        if normalized.startswith(" %s " % keyword) or " %s " % keyword in normalized:
            raise ValueError(
                "Only read queries are allowed here. Refused because of the "
                "keyword %s." % keyword
            )
    if not (normalized.lstrip().startswith("SELECT") or normalized.lstrip().startswith("WITH")):
        raise ValueError("Only SELECT queries are allowed here.")

    audit.record("execute_sql", query)
    conn = connect()
    try:
        cur = conn.cursor()
        cur.execute(query)
        columns = [desc[0] for desc in cur.description] if cur.description else []
        rows = cur.fetchall()
        if not rows:
            return "(no rows returned)"
        header = " | ".join(columns)
        separator = "-+-".join("-" * max(len(c), MIN_COLUMN_WIDTH) for c in columns)
        body = "\n".join(" | ".join(str(v) for v in row) for row in rows)
        return "%s\n%s\n%s" % (header, separator, body)
    except sqlite3.Error as exc:
        # A failed query is information, not a crash: whatever called this can
        # read the message and correct the query.
        return "SQL Error: %s" % exc
    finally:
        conn.close()
