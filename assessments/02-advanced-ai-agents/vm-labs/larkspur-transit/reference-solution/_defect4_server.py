"""Defect 4 (server): execute_sql is the provided function with the guard removed.

A copy of transit_kit.sql_tools.execute_sql, access record and all, minus the
read-only keyword check - so a data-modifying statement is executed instead of
refused. Expected: TC02 fails, the rest pass.
"""
import sqlite3
from typing import Any, Dict, List

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.prompts import base
from pydantic import Field

from transit_kit import connect, get_table_schema, list_tables
from transit_kit import audit

mcp = FastMCP("larkspur-ops-defect4", log_level="ERROR")


@mcp.tool(name="list_tables", description="Every table in the operations database.")
def _tables() -> List[str]:
    return list_tables()


@mcp.tool(name="get_table_schema", description="Columns of one operations table.")
def _schema(table_name: str = Field(description="Table")) -> List[Dict[str, Any]]:
    return get_table_schema(table_name)


@mcp.tool(name="execute_sql", description="Run one SQL query.")
def _query(query: str = Field(description="SQL to run")) -> str:
    audit.record("execute_sql", query)
    conn = connect()
    try:
        cur = conn.cursor()
        cur.execute(query)
        conn.commit()
        columns = [d[0] for d in cur.description] if cur.description else []
        rows = cur.fetchall()
        if not rows:
            return "(no rows returned)"
        header = " | ".join(columns)
        rule = "-+-".join("-" * max(len(c), 8) for c in columns)
        body = "\n".join(" | ".join(str(v) for v in row) for row in rows)
        return "%s\n%s\n%s" % (header, rule, body)
    except sqlite3.Error as exc:
        return "SQL Error: %s" % exc
    finally:
        conn.close()


@mcp.resource("transit://overview", mime_type="text/plain")
def overview() -> str:
    conn = connect()
    try:
        lines = ["operations database"]
        for name in list_tables():
            lines.append("%s: %d rows" % (
                name, conn.execute("SELECT COUNT(*) FROM " + name).fetchone()[0]))
    finally:
        conn.close()
    return "\n".join(lines)


@mcp.prompt(name="transit_analyst", description="Analyst instructions.")
def analyst(question: str = Field(description="Question")) -> List[base.Message]:
    return [base.UserMessage("Answer with SQL. QUESTION: %s" % question)]


if __name__ == "__main__":
    mcp.run(transport="stdio")
