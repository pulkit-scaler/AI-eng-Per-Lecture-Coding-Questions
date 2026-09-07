"""The three database tools, plus the operations audit trail.

Provided, do not modify.

  list_tables()                 -> list of table names
  get_table_schema(table_name)  -> list of column names for one table
  schema_summary()              -> a compact schema string for a prompt
  execute_sql(query)            -> the result as text, or "ERROR: <message>"

`execute_sql` never raises on a bad query. When the database rejects a statement
it returns a string that starts with `ERROR: ` followed by the database's own
message, so the failure is something you can read, pass on and act on.

Every statement the desk runs is written to the operations audit trail, the way a
control room records what it did.
"""
import json
import os
import urllib.error
import urllib.request

from .db import connect

AUDIT_URL = os.environ.get(
    "ASHFORD_AUDIT_URL", "http://127.0.0.1:8836/v1/audit/query")
AUDIT_TIMEOUT = float(os.environ.get("ASHFORD_AUDIT_TIMEOUT", "5"))


def _session_id():
    return os.environ.get("ASHFORD_RUN_ID", "local")


def _audit(query, ok, error):
    """Write one line to the operations audit trail. Never raises."""
    body = json.dumps({"sql": query, "ok": bool(ok),
                       "error": error or ""}).encode("utf-8")
    request = urllib.request.Request(
        AUDIT_URL, data=body, method="POST",
        headers={"Content-Type": "application/json",
                 "X-Ashford-Session": _session_id()})
    try:
        with urllib.request.urlopen(request, timeout=AUDIT_TIMEOUT) as response:
            response.read()
    except (urllib.error.URLError, OSError, ValueError):
        pass


# ---- shared:formatter ----
# Rendering of a result set into the text the desk reports. Kept byte-identical
# between the provided toolkit and this service, so an expected value computed
# here matches what the toolkit hands back.
def scalar_text(value):
    """Render one cell as text."""
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float):
        rendered = "%.4f" % value
        rendered = rendered.rstrip("0").rstrip(".")
        return rendered if rendered not in ("", "-") else "0"
    return str(value)


def format_rows(columns, rows):
    """Render a result set as a compact text table."""
    if not columns:
        return "(no columns)"
    lines = [" | ".join(str(c) for c in columns)]
    for row in rows:
        lines.append(" | ".join(scalar_text(v) for v in row))
    if not rows:
        lines.append("(no rows)")
    return "\n".join(lines)
# ---- /shared:formatter ----


def list_tables():
    """Return every table name in the grid operations database."""
    conn = connect()
    try:
        return [row[0] for row in conn.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name NOT LIKE 'sqlite_%' ORDER BY name")]
    finally:
        conn.close()


def get_table_schema(table_name):
    """Return the column names of one table, in schema order.

    Args:
        table_name: the exact table name to inspect.
    """
    conn = connect()
    try:
        return [row[1] for row in conn.execute(
            "PRAGMA table_info(%s)" % table_name)]
    finally:
        conn.close()


def schema_summary():
    """Return a compact `table: col, col, ...` block for every table."""
    lines = []
    for table in list_tables():
        lines.append("  %s: %s" % (table, ", ".join(get_table_schema(table))))
    return "\n".join(lines)


def run_sql(query):
    """Run a query and return (columns, rows). Raises on a database error.

    The statement is written to the operations audit trail either way.
    """
    conn = connect()
    try:
        cursor = conn.execute(query)
        columns = [d[0] for d in (cursor.description or [])]
        rows = cursor.fetchall()
    except Exception as exc:                        # noqa: BLE001
        _audit(query, False, str(exc))
        raise
    finally:
        conn.close()
    _audit(query, True, "")
    return columns, rows


def execute_sql(query):
    """Run a SELECT query and return the result as text.

    On a database error this returns `"ERROR: <the database message>"` instead of
    raising, so the message can be read and acted on.

    Args:
        query: a SQLite SELECT query.
    """
    try:
        columns, rows = run_sql(query)
    except Exception as exc:                        # noqa: BLE001
        return "ERROR: %s" % exc
    return format_rows(columns, rows)
