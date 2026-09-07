"""ALTERNATIVE: the guard backed by a driver-level authorizer too.

The two tools the planning crew is allowed to use."""
import re
import sqlite3
from typing import Type

from crewai.tools import BaseTool
from pydantic import BaseModel, Field

from . import millkit

# Anything that could change the database, rejected wherever it appears. The
# read-only connection below means a bypass could not write even so; this is the
# layer that gives the agent a readable reason instead of a driver error.
FORBIDDEN = ("insert", "update", "delete", "drop", "alter", "create",
             "replace", "attach", "detach", "pragma", "vacuum", "reindex",
             "truncate", "grant", "revoke")
WORD = re.compile(r"[a-z_]+")


class RunQueryInput(BaseModel):
    sql: str = Field(description="One read-only SELECT or WITH statement.")


class RunQueryTool(BaseTool):
    name: str = "run_query"
    description: str = (
        "Run one read-only SQL query against the mill database and get the rows "
        "back as text. Tables: yarn_stock(yarn_code, description, "
        "cones_on_hand, metres_per_cone, bin), cloth_spec(cloth, yarn_code, "
        "metres_of_yarn_per_metre_of_cloth), looms(loom, machine, available, "
        "set_for). SELECT or WITH only."
    )
    args_schema: Type[BaseModel] = RunQueryInput

    def _run(self, sql: str) -> str:
        statement = (sql or "").strip().rstrip(";").strip()
        if not statement:
            return "REFUSED: there is no statement to run."

        lowered = statement.lower()
        head = WORD.match(lowered)
        if head is None or head.group(0) not in ("select", "with"):
            return ("REFUSED: only SELECT or WITH statements are allowed, and "
                    "this one starts with %r." % statement.split(" ")[0])
        for word in set(WORD.findall(lowered)):
            if word in FORBIDDEN:
                return ("REFUSED: %s is not allowed anywhere in a query on this "
                        "database." % word.upper())
        if ";" in statement:
            return "REFUSED: one statement at a time."

        try:
            connection = millkit.read_only()
            # Belt as well as braces: the driver itself refuses anything that
            # is not a read, whatever got past the checks above.
            def authorize(action, *rest):
                allowed = (sqlite3.SQLITE_SELECT, sqlite3.SQLITE_READ,
                           sqlite3.SQLITE_FUNCTION)
                return sqlite3.SQLITE_OK if action in allowed else sqlite3.SQLITE_DENY
            connection.set_authorizer(authorize)
        except sqlite3.Error as exc:
            return "ERROR: could not open the mill database (%s)." % exc
        try:
            cursor = connection.execute(statement)
            columns = [c[0] for c in cursor.description or []]
            rows = cursor.fetchmany(millkit.ROW_CAP)
        except sqlite3.Error as exc:
            # Handed back as text on purpose: the agent can read it and correct
            # itself, where an exception would end the run.
            return "ERROR: %s" % exc
        finally:
            connection.close()

        if not rows:
            return "no rows"
        lines = [" | ".join(columns)]
        lines += [" | ".join("" if v is None else str(v) for v in row)
                  for row in rows]
        if len(rows) == millkit.ROW_CAP:
            lines.append("... truncated at %d rows" % millkit.ROW_CAP)
        return "\n".join(lines)


class StockLookupInput(BaseModel):
    yarn_code: str = Field(description="A yarn code such as YN-WL14.")


class StockLookupTool(BaseTool):
    name: str = "stock_lookup"
    description: str = (
        "Look up one yarn by code and get its description, cones on hand, "
        "metres per cone and bin."
    )
    args_schema: Type[BaseModel] = StockLookupInput

    def _run(self, yarn_code: str) -> str:
        code = (yarn_code or "").strip().upper()
        if not code:
            return "REFUSED: no yarn code given."
        connection = millkit.read_only()
        try:
            row = connection.execute(
                "SELECT yarn_code, description, cones_on_hand, "
                "metres_per_cone, bin FROM yarn_stock WHERE yarn_code = ?",
                (code,)).fetchone()
        except sqlite3.Error as exc:
            return "ERROR: %s" % exc
        finally:
            connection.close()
        if row is None:
            return "no rows: %s is not stocked at this mill." % code
        return ("yarn_code | description | cones_on_hand | metres_per_cone | bin"
                "\n%s" % " | ".join(str(v) for v in row))
