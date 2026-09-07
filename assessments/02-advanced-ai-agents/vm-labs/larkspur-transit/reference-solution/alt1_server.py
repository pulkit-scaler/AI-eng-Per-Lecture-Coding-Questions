"""Alternative 1 (server): bare decorators, descriptions from docstrings.

No name= or description= kwargs anywhere - the SDK takes the tool name from the
function name and the description from the docstring. Parameters are annotated
without pydantic Field, so they are required simply because they have no default.
"""
from typing import Any, Dict, List

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.prompts import base

from transit_kit import connect, sql_tools

mcp = FastMCP("larkspur-ops-alt1")


@mcp.tool()
def list_tables() -> List[str]:
    """List every table in the Larkspur Transit operations database. Call this
    first to find out what can be queried."""
    return sql_tools.list_tables()


@mcp.tool()
def get_table_schema(table_name: str) -> List[Dict[str, Any]]:
    """Describe one table: the name, type, nullability and primary-key flag of
    each column. table_name is the exact name of the table to describe."""
    return sql_tools.get_table_schema(table_name)


@mcp.tool()
def execute_sql(query: str) -> str:
    """Run one read-only SQL SELECT query against the operations database and
    return the rows as a formatted table. query is the SQLite SELECT to run."""
    return sql_tools.execute_sql(query)


@mcp.resource("transit://overview")
def overview() -> str:
    """The tables in the operations database and how many rows each one holds."""
    report = []
    for table in sql_tools.list_tables():
        conn = connect()
        try:
            rows = conn.execute("SELECT COUNT(*) FROM " + table).fetchone()[0]
        finally:
            conn.close()
        report.append("- %s ... %d rows" % (table, rows))
    return "operations database overview\n" + "\n".join(report)


@mcp.prompt()
def transit_analyst(question: str) -> List[base.Message]:
    """Instructions for answering one operations question with SQL."""
    return [base.UserMessage(
        "Answer this using list_tables, get_table_schema and execute_sql, in "
        "that order, and report the number you find.\n\n" + question)]


if __name__ == "__main__":
    mcp.run(transport="stdio")
