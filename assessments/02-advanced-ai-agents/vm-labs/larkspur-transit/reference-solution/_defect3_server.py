"""Defect 3 (server): the prompt ignores the argument it is given.

Expected: TC04 fails, the rest pass.
"""
from typing import Any, Dict, List

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.prompts import base
from pydantic import Field

from transit_kit import connect, execute_sql, get_table_schema, list_tables

mcp = FastMCP("larkspur-ops-defect3", log_level="ERROR")


@mcp.tool(name="list_tables", description="Every table in the operations database.")
def _tables() -> List[str]:
    return list_tables()


@mcp.tool(name="get_table_schema", description="Columns of one operations table.")
def _schema(table_name: str = Field(description="Table")) -> List[Dict[str, Any]]:
    return get_table_schema(table_name)


@mcp.tool(name="execute_sql", description="Run one read-only SELECT query.")
def _query(query: str = Field(description="SELECT to run")) -> str:
    return execute_sql(query)


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
    return [base.UserMessage(
        "You are the Larkspur Transit operations analyst. Discover the tables, "
        "read the schema, then run one SELECT and report the answer.")]


if __name__ == "__main__":
    mcp.run(transport="stdio")
