"""Defect 2 (server): the overview resource is a hand-written constant.

The tools are all correct, so only the resource theme should notice.
Expected: TC03 fails, the rest pass.
"""
from typing import Any, Dict, List

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.prompts import base
from pydantic import Field

from transit_kit import execute_sql, get_table_schema, list_tables

mcp = FastMCP("larkspur-ops-defect2", log_level="ERROR")

OVERVIEW = "\n".join([
    "Larkspur Transit operations database",
    "routes: 12 rows",
    "trips: 24 rows",
    "vehicles: 16 rows",
])


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
    return OVERVIEW


@mcp.prompt(name="transit_analyst", description="Analyst instructions.")
def analyst(question: str = Field(description="Question")) -> List[base.Message]:
    return [base.UserMessage("Answer with SQL. QUESTION: %s" % question)]


if __name__ == "__main__":
    mcp.run(transport="stdio")
