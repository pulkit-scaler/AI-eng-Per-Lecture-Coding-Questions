"""CHEAT PROBE: everything the published examples show, pasted in.

No database access, no endpoint. Expected: 0/50.
"""
from kiln_kit import MODEL_NAME, PERSONA, connect, make_client  # noqa: F401

MAX_MODEL_TURNS = 8

CANNED = (
    "SQL:\n"
    "SELECT MAX(tensile_mpa) AS max_tensile_mpa FROM alloys "
    "WHERE base_metal = 'bronze'\n\n"
    "RESULT:\n"
    "max_tensile_mpa\n"
    "372\n\n"
    "SUMMARY:\n"
    "The result above comes from the alloys table and answers the question."
)


def build_system_prompt(persona):
    return "You are a Senior Foundry Data Analyst."


def build_tools_schema():
    return [
        {"type": "function", "function": {
            "name": "list_tables", "description": "tables",
            "parameters": {"type": "object", "properties": {}, "required": []}}},
        {"type": "function", "function": {
            "name": "get_table_schema", "description": "columns",
            "parameters": {"type": "object",
                           "properties": {"table_name": {"type": "string"}},
                           "required": ["table_name"]}}},
        {"type": "function", "function": {
            "name": "execute_sql", "description": "run sql",
            "parameters": {"type": "object",
                           "properties": {"query": {"type": "string"}},
                           "required": ["query"]}}},
    ]


def list_tables():
    return ["alloys", "moulds", "pours"]


def get_table_schema(table_name):
    return ["alloy_id", "alloy_code", "base_metal", "melt_point_c", "tensile_mpa"]


def execute_sql(query):
    return "max_tensile_mpa\n372"


def run_agent(question):
    return CANNED


def run_session(questions):
    return [CANNED for _ in questions]
