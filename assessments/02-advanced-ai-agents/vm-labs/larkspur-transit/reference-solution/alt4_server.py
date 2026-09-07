"""Alternative 4 (server): Annotated parameter style, async tool functions.

Parameters carry their descriptions through typing.Annotated rather than a
default value, and the tool functions are coroutines. The generated schemas and
the protocol behaviour are identical.
"""
from typing import Annotated, Any, Dict, List

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.prompts import base
from pydantic import Field

from transit_kit import connect, execute_sql, get_table_schema, list_tables

mcp = FastMCP("larkspur-ops-alt4", log_level="ERROR")

TableName = Annotated[str, Field(description="Exact name of the table")]
SqlQuery = Annotated[str, Field(description="A single read-only SELECT")]


@mcp.tool(name="list_tables",
          description="Discover every table in the operations database.")
async def tables() -> List[str]:
    return list_tables()


@mcp.tool(name="get_table_schema",
          description="Read the columns and types of one operations table.")
async def schema_of(table_name: TableName) -> List[Dict[str, Any]]:
    return get_table_schema(table_name)


@mcp.tool(name="execute_sql",
          description="Execute a read-only SELECT and return the resulting rows.")
async def query(query: SqlQuery) -> str:
    return execute_sql(query)


@mcp.resource("transit://overview", mime_type="text/plain")
async def overview() -> str:
    conn = connect()
    try:
        sizes = [(name, conn.execute("SELECT COUNT(*) FROM " + name).fetchone()[0])
                 for name in list_tables()]
    finally:
        conn.close()
    header = "OPERATIONS DATABASE OVERVIEW"
    return "\n".join([header] + ["%s = %d rows" % pair for pair in sizes])


@mcp.prompt(name="transit_analyst",
            description="A worked instruction for one operations question.")
async def analyst(question: Annotated[str, Field(description="The question")]) \
        -> List[base.Message]:
    return [base.UserMessage("[transit-analyst] %s" % question),
            base.UserMessage("Start with list_tables.")]


if __name__ == "__main__":
    mcp.run(transport="stdio")
