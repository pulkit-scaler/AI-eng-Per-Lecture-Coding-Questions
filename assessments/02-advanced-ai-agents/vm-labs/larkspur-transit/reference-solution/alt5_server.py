"""Alternative 5 (server): the tools are registered from a table, in a loop.

A registry of (name, description, function) tuples is walked and the decorator
factory is applied to each entry, which is how a real server with twenty tools
would be organised. The resource returns JSON rather than plain text.
"""
import json
from typing import Any, Dict, List

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.prompts import base
from pydantic import Field

from transit_kit import connect, sql_tools

mcp = FastMCP("larkspur-ops-alt5", log_level="ERROR")


def _tables() -> List[str]:
    return sql_tools.list_tables()


def _schema(table_name: str = Field(description="Table to describe")) -> List[Dict[str, Any]]:
    return sql_tools.get_table_schema(table_name)


def _run(query: str = Field(description="Read-only SELECT to run")) -> str:
    return sql_tools.execute_sql(query)


REGISTRY = (
    ("list_tables",
     "Enumerate the tables held in the Larkspur Transit operations database.",
     _tables),
    ("get_table_schema",
     "Return the column list of one operations table, with types and keys.",
     _schema),
    ("execute_sql",
     "Run a single read-only SELECT statement and return the matching rows.",
     _run),
)

for _name, _description, _function in REGISTRY:
    mcp.tool(name=_name, description=_description)(_function)


@mcp.resource("transit://overview", mime_type="application/json")
def overview() -> str:
    conn = connect()
    try:
        rows = {name: conn.execute("SELECT COUNT(*) FROM " + name).fetchone()[0]
                for name in sql_tools.list_tables()}
    finally:
        conn.close()
    # One line per table so the overview stays readable when it is printed as
    # text as well as parsed as JSON.
    return json.dumps({"database": "larkspur-transit", "tables": rows}, indent=1)


@mcp.prompt(name="transit_analyst",
            description="Prepare the analyst for one operations question.")
def analyst(question: str = Field(description="Operations question")) -> List[base.Message]:
    lines = [
        "ROLE: Larkspur Transit operations analyst.",
        "TOOLS: list_tables, get_table_schema, execute_sql.",
        "RULES: read-only SQL, confirmed column names only.",
        "QUESTION:",
        question,
    ]
    return [base.UserMessage("\n".join(lines))]


if __name__ == "__main__":
    mcp.run(transport="stdio")
