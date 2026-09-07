"""Alternative 3 (server): imperative registration, no decorator syntax at all.

The three tools go on with add_tool(), and the resource and the prompt are
registered by calling the factory the decorator would have called. Same protocol
surface, no @ anywhere.
"""
from typing import Any, Dict, List

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.prompts import base
from pydantic import Field

from transit_kit import connect, sql_tools

mcp = FastMCP("larkspur-ops-alt3", log_level="ERROR")


def show_tables() -> List[str]:
    return sql_tools.list_tables()


def describe(table_name: str = Field(description="Name of the table")) -> List[Dict[str, Any]]:
    return sql_tools.get_table_schema(table_name)


def run_query(query: str = Field(description="A read-only SELECT")) -> str:
    return sql_tools.execute_sql(query)


def build_overview() -> str:
    conn = connect()
    try:
        lines = ["transit operations database"]
        for table in sql_tools.list_tables():
            total = conn.execute("SELECT COUNT(*) FROM " + table).fetchone()[0]
            lines.append("%s -> %d rows" % (table, total))
    finally:
        conn.close()
    return "\n".join(lines)


def analyst_messages(question: str = Field(description="Question to answer")) -> List[base.Message]:
    return [base.UserMessage(
        "Operations question: %s\n\nDiscover the tables first, then the schema, "
        "then run a single SELECT." % question)]


mcp.add_tool(
    show_tables,
    name="list_tables",
    description="List every table in the Larkspur Transit operations database.",
)
mcp.add_tool(
    describe,
    name="get_table_schema",
    description="Describe one operations table: its columns, types and keys.",
)
mcp.add_tool(
    run_query,
    name="execute_sql",
    description="Run one read-only SELECT against the operations database.",
)

# The decorator is just a factory that registers what it is handed, so calling it
# directly registers the same resource and the same prompt.
mcp.resource("transit://overview", mime_type="text/plain")(build_overview)
mcp.prompt(name="transit_analyst",
           description="Guidance for one operations question.")(analyst_messages)


if __name__ == "__main__":
    mcp.run(transport="stdio")
