"""ALTERNATIVE: the tools written with the decorator instead of subclasses."""
import re
import sqlite3

from crewai.tools import tool

from . import millkit

FORBIDDEN = ("insert", "update", "delete", "drop", "alter", "create",
             "replace", "attach", "detach", "pragma", "vacuum", "reindex",
             "truncate", "grant", "revoke")
WORD = re.compile(r"[a-z_]+")


def _guarded(sql):
    statement = (sql or "").strip().rstrip(";").strip()
    if not statement:
        return None, "REFUSED: there is no statement to run."
    lowered = statement.lower()
    head = WORD.match(lowered)
    if head is None or head.group(0) not in ("select", "with"):
        return None, "REFUSED: only SELECT or WITH statements are allowed here."
    for word in set(WORD.findall(lowered)):
        if word in FORBIDDEN:
            return None, ("REFUSED: %s is not allowed anywhere in a query on "
                          "this database." % word.upper())
    if ";" in statement:
        return None, "REFUSED: one statement at a time."
    return statement, None


def _rows(statement):
    connection = millkit.read_only()
    try:
        cursor = connection.execute(statement)
        columns = [c[0] for c in cursor.description or []]
        rows = cursor.fetchmany(millkit.ROW_CAP)
    except sqlite3.Error as exc:
        return "ERROR: %s" % exc
    finally:
        connection.close()
    if not rows:
        return "no rows"
    out = [" | ".join(columns)]
    out += [" | ".join("" if v is None else str(v) for v in row) for row in rows]
    if len(rows) == millkit.ROW_CAP:
        out.append("... truncated at %d rows" % millkit.ROW_CAP)
    return "\n".join(out)


@tool("run_query")
def run_query(sql: str) -> str:
    """Run one read-only SELECT against the mill database. Tables:
    yarn_stock(yarn_code, description, cones_on_hand, metres_per_cone, bin),
    cloth_spec(cloth, yarn_code, metres_of_yarn_per_metre_of_cloth),
    looms(loom, machine, available, set_for)."""
    statement, refusal = _guarded(sql)
    if refusal:
        return refusal
    return _rows(statement)


@tool("stock_lookup")
def stock_lookup(yarn_code: str) -> str:
    """Look up one yarn by code and report what is held of it."""
    code = (yarn_code or "").strip().upper()
    if not code:
        return "REFUSED: no yarn code given."
    return _rows("SELECT yarn_code, description, cones_on_hand, "
                 "metres_per_cone, bin FROM yarn_stock "
                 "WHERE yarn_code = '%s'" % code.replace("'", ""))


RunQueryTool = lambda: run_query          # noqa: E731 - keeps crew.py unchanged
StockLookupTool = lambda: stock_lookup    # noqa: E731
