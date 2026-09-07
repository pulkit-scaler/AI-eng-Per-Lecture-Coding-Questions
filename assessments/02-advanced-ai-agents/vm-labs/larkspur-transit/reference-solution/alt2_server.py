"""Alternative 2 (server): the three required tools plus two extra ones.

Also uses a templated resource alongside the required static one, and an extra
prompt. Everything beyond the published contract must be ignored by the checks.
"""
from typing import Any, Dict, List

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.prompts import base
from pydantic import Field

from transit_kit import connect, execute_sql, get_table_schema, list_tables

mcp = FastMCP("larkspur-ops-alt2", log_level="WARNING")


@mcp.tool(name="list_tables", description="Every table in the operations database.")
def _tables() -> List[str]:
    return list_tables()


@mcp.tool(name="get_table_schema",
          description="Columns and types of one operations table.")
def _schema(table_name: str = Field(description="Table to describe")) -> List[Dict[str, Any]]:
    return get_table_schema(table_name)


@mcp.tool(name="execute_sql",
          description="Run one read-only SELECT and return the rows as a table.")
def _query(query: str = Field(description="SQLite SELECT statement")) -> str:
    return execute_sql(query)


# ---- extras the contract says nothing about -------------------------------

@mcp.tool(name="count_rows", description="How many rows one table holds.")
def _count(table_name: str = Field(description="Table to count")) -> str:
    return execute_sql("SELECT COUNT(*) AS rows FROM " + table_name)


@mcp.tool(name="get_sample_rows",
          description="A handful of rows from one table, to see real values.")
def _sample(table_name: str = Field(description="Table to sample"),
            limit: int = Field(default=3, description="How many rows")) -> str:
    return execute_sql("SELECT * FROM %s LIMIT %d" % (table_name, int(limit)))


# ---- resources -----------------------------------------------------------

def _row_count(table: str) -> int:
    conn = connect()
    try:
        return conn.execute("SELECT COUNT(*) FROM " + table).fetchone()[0]
    finally:
        conn.close()


@mcp.resource("transit://overview", mime_type="text/plain")
def overview_resource() -> str:
    body = ["Larkspur Transit - operations database overview", ""]
    for table in list_tables():
        body.append("  %-12s %6d rows" % (table, _row_count(table)))
    return "\n".join(body)


@mcp.resource("transit://table/{table_name}", mime_type="application/json")
def one_table_resource(table_name: str) -> List[Dict[str, Any]]:
    return get_table_schema(table_name)


# ---- prompts -------------------------------------------------------------

@mcp.prompt(name="transit_analyst", description="Answer an operations question.")
def analyst(question: str = Field(description="Question to answer")) -> List[base.Message]:
    return [
        base.UserMessage("Operations question follows. Discover the tables, read "
                         "the schemas you need, then run one SELECT."),
        base.AssistantMessage("Understood - I will start with list_tables."),
        base.UserMessage(question),
    ]


@mcp.prompt(name="fleet_briefing", description="Summarise the fleet.")
def briefing() -> List[base.Message]:
    return [base.UserMessage("Summarise the vehicles table by depot.")]


if __name__ == "__main__":
    mcp.run(transport="stdio")
