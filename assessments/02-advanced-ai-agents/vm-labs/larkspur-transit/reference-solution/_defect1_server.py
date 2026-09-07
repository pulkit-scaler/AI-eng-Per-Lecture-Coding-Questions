"""Defect 1 (server): table_name is optional, so nothing is declared required.

Everything still works when the argument is supplied, so only the advertisement
theme should notice. Expected: TC01 fails, TC02..TC05 pass.
"""
from typing import Any, Dict, List, Optional

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.prompts import base
from pydantic import Field

from transit_kit import connect, execute_sql, get_table_schema, list_tables

mcp = FastMCP("larkspur-ops-defect1", log_level="ERROR")


@mcp.tool(name="list_tables", description="Every table in the operations database.")
def _tables() -> List[str]:
    return list_tables()


@mcp.tool(name="get_table_schema", description="Columns of one operations table.")
def _schema(table_name: Optional[str] = None) -> List[Dict[str, Any]]:
    return get_table_schema(table_name or "routes")


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
    return [base.UserMessage("Answer with SQL. QUESTION: %s" % question)]


if __name__ == "__main__":
    mcp.run(transport="stdio")
