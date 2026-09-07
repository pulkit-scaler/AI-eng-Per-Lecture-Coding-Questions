"""Provided toolkit for the Ashford grid operations lab."""
from .client import MODEL, make_client
from .db import DB_PATH, connect
from .handlers import (handle_capacity_check, handle_load_trend,
                       handle_outage_lookup, handle_schema_help)
from .persona import PERSONA, build_system_prompt
from .prompts import (CRITIQUE_SYSTEM_PROMPT, DRAFT_SYSTEM_PROMPT,
                      GUARD_NAMES, GUARD_PROMPTS, REFINE_SYSTEM_PROMPT,
                      ROUTE_SYSTEM_PROMPT)
from .tools import (execute_sql, get_table_schema, list_tables, run_sql,
                    schema_summary)

__all__ = [
    "make_client",
    "MODEL",
    "connect",
    "DB_PATH",
    "PERSONA",
    "build_system_prompt",
    "DRAFT_SYSTEM_PROMPT",
    "CRITIQUE_SYSTEM_PROMPT",
    "REFINE_SYSTEM_PROMPT",
    "ROUTE_SYSTEM_PROMPT",
    "GUARD_PROMPTS",
    "GUARD_NAMES",
    "list_tables",
    "get_table_schema",
    "schema_summary",
    "execute_sql",
    "run_sql",
    "handle_outage_lookup",
    "handle_capacity_check",
    "handle_load_trend",
    "handle_schema_help",
]
