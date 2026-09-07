"""Larkspur Transit MCP SERVER - your work goes here (Tasks 1 to 3).

This file is the server half of the lab. The client half is solution.py, and the
two are separate programs: this one is never imported, it is executed as
"python3 server.py" and talks JSON-RPC on its standard input and output. Do not
import solution.py from here.

What to do here:
  Task 1  expose the three functions in transit_kit/sql_tools.py as MCP tools
  Task 2  add the database-overview resource at transit://overview
  Task 3  add the transit_analyst prompt, taking a question argument
  and end the file with a stdio entry point.

Organise it however you like. What is assessed is what the protocol advertises
and what the server does when a client calls it, not how the file is written.
"""
from typing import Any, Dict, List

from mcp.server.fastmcp import FastMCP
from mcp.server.fastmcp.prompts import base
from pydantic import Field

from transit_kit import connect, execute_sql, get_table_schema, list_tables

mcp = FastMCP("Larkspur-Transit-Ops")


# ---------------------------------------------------------------------------
# Task 1 - three tools: list_tables, get_table_schema, execute_sql
#
# Each one needs a description a model can act on, and typed parameters so the
# generated input schema says which arguments are required.
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Task 2 - one resource at transit://overview, returning the database overview
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# Task 3 - one prompt named transit_analyst, taking a question argument
# ---------------------------------------------------------------------------


if __name__ == "__main__":
    mcp.run(transport="stdio")
