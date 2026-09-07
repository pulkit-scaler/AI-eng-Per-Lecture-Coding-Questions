"""Reference solution - the Larkspur Transit MCP server.

Three tools, one resource, one prompt, spoken over stdio.
"""
from typing import Any, Dict, List

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.prompts import base
from pydantic import Field

from transit_kit import connect, execute_sql, get_table_schema, list_tables

mcp = FastMCP("Larkspur-Transit-Ops", log_level="ERROR")


# ---------------------------------------------------------------------------
# tools
# ---------------------------------------------------------------------------

@mcp.tool(
    name="list_tables",
    description=(
        "List every table in the Larkspur Transit operations database. "
        "Call this first to find out what can be queried."
    ),
)
def tool_list_tables() -> List[str]:
    return list_tables()


@mcp.tool(
    name="get_table_schema",
    description=(
        "Describe one table: the name, type, nullability and primary-key flag "
        "of each of its columns. Use it after list_tables to learn the exact "
        "column names before writing a query."
    ),
)
def tool_get_table_schema(
    table_name: str = Field(description="Exact name of the table to describe"),
) -> List[Dict[str, Any]]:
    return get_table_schema(table_name)


@mcp.tool(
    name="execute_sql",
    description=(
        "Run one read-only SQL query against the operations database and return "
        "the rows as a formatted table. SELECT queries only - no INSERT, "
        "UPDATE, DELETE, DROP or ALTER."
    ),
)
def tool_execute_sql(
    query: str = Field(description="A single SQLite SELECT query to run"),
) -> str:
    return execute_sql(query)


# ---------------------------------------------------------------------------
# resource
# ---------------------------------------------------------------------------

@mcp.resource("transit://overview", mime_type="text/plain")
def transit_overview() -> str:
    """A live overview of the operations database: every table and its size."""
    lines = ["Larkspur Transit operations database"]
    conn = connect()
    try:
        for name in list_tables():
            count = conn.execute("SELECT COUNT(*) FROM `%s`" % name).fetchone()[0]
            lines.append("%s: %d rows" % (name, count))
    finally:
        conn.close()
    return "\n".join(lines)


# ---------------------------------------------------------------------------
# prompt
# ---------------------------------------------------------------------------

@mcp.prompt(
    name="transit_analyst",
    description="Instructions for answering one operations question with SQL.",
)
def transit_analyst(
    question: str = Field(description="The operations question to answer"),
) -> List[base.Message]:
    text = (
        "You are the Larkspur Transit operations analyst.\n"
        "\n"
        "Work like this:\n"
        "  1. Call list_tables to see what exists.\n"
        "  2. Call get_table_schema on the tables you need.\n"
        "  3. Write one SQLite SELECT query.\n"
        "  4. Run it with execute_sql and report the answer.\n"
        "\n"
        "Use only table and column names the schema tool confirmed, and never "
        "modify data.\n"
        "\n"
        "QUESTION: %s" % question
    )
    return [base.UserMessage(text)]


if __name__ == "__main__":
    mcp.run(transport="stdio")
