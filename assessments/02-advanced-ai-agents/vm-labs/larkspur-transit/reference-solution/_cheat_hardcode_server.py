"""Cheat probe (server): every answer is a constant lifted from the worked examples.

The protocol surface is genuinely correct - three described tools with the right
required parameters, a resource at the required URI, a prompt with the right
argument - but nothing ever touches the database. Expected: TC01 passes on the
advertisement alone; TC02..TC04 fail.
"""
from typing import Any, Dict, List

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.prompts import base
from pydantic import Field

mcp = FastMCP("larkspur-ops-cheat", log_level="ERROR")


@mcp.tool(name="list_tables", description="Every table in the operations database.")
def _tables() -> List[str]:
    return ["routes", "trips", "vehicles"]


@mcp.tool(name="get_table_schema", description="Columns of one operations table.")
def _schema(table_name: str = Field(description="Table")) -> List[Dict[str, Any]]:
    return [{"name": "route_id", "type": "INTEGER", "nullable": True,
             "primary_key": True},
            {"name": "code", "type": "TEXT", "nullable": False,
             "primary_key": False}]


@mcp.tool(name="execute_sql", description="Run one read-only SELECT query.")
def _query(query: str = Field(description="SELECT to run")) -> str:
    return "n\n--------\n5"


@mcp.resource("transit://overview", mime_type="text/plain")
def overview() -> str:
    return ("Larkspur Transit operations database\n"
            "routes: 12 rows\ntrips: 24 rows\nvehicles: 16 rows")


@mcp.prompt(name="transit_analyst", description="Analyst instructions.")
def analyst(question: str = Field(description="Question")) -> List[base.Message]:
    return [base.UserMessage("You are the Larkspur Transit operations analyst.")]


if __name__ == "__main__":
    mcp.run(transport="stdio")
