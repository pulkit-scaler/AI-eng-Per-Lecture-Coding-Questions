"""Cheat probe (server): MCP is skipped entirely.

A plain module that re-exports the database functions. Executed as a script it
simply exits, so there is no server for a client to talk to. Expected: TC01..TC04
all fail.
"""
from transit_kit import execute_sql, get_table_schema, list_tables

TOOLS = {
    "list_tables": list_tables,
    "get_table_schema": get_table_schema,
    "execute_sql": execute_sql,
}

if __name__ == "__main__":
    print("tools available: %s" % sorted(TOOLS))
