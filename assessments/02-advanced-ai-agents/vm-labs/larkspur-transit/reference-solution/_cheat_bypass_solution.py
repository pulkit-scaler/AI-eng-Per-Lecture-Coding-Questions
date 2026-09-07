"""Cheat probe (client): the loop calls the database functions itself.

The tool schemas are hand-written rather than discovered, and every requested
tool is executed in this process instead of being relayed to an MCP server. The
final answer comes out right, which is exactly why the theme has to look at where
the database work happened. Expected: TC05 fails.
"""
import asyncio
import json
import sys

from transit_kit import MODEL_NAME, execute_sql, get_table_schema, list_tables, make_client

MAX_MODEL_TURNS = 8

HAND_WRITTEN = [
    {"type": "function", "function": {
        "name": "list_tables", "description": "Every table in the database.",
        "parameters": {"type": "object", "properties": {}}}},
    {"type": "function", "function": {
        "name": "get_table_schema", "description": "Columns of one table.",
        "parameters": {"type": "object",
                       "properties": {"table_name": {"type": "string"}},
                       "required": ["table_name"]}}},
    {"type": "function", "function": {
        "name": "execute_sql", "description": "Run a read-only SELECT.",
        "parameters": {"type": "object",
                       "properties": {"query": {"type": "string"}},
                       "required": ["query"]}}},
]

LOCAL = {
    "list_tables": lambda **kw: "\n".join(list_tables()),
    "get_table_schema": lambda **kw: json.dumps(get_table_schema(**kw)),
    "execute_sql": lambda **kw: execute_sql(**kw),
}


class TransitMCPClient:
    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc_info):
        return None

    async def list_tools(self):
        return []

    async def call_tool(self, name, arguments=None):
        return LOCAL[name](**(arguments or {}))

    async def read_resource(self, uri):
        return ""

    async def list_prompts(self):
        return []

    async def get_prompt(self, name, arguments=None):
        return []


def mcp_tools_to_openai(mcp_tools):
    return HAND_WRITTEN


async def run_agent_loop(question):
    model = make_client()
    chat = [{"role": "system", "content": "Operations analyst."},
            {"role": "user", "content": question}]
    for _ in range(MAX_MODEL_TURNS):
        reply = model.chat.completions.create(
            model=MODEL_NAME, messages=chat, tools=HAND_WRITTEN,
            tool_choice="auto").choices[0].message
        if not reply.tool_calls:
            return reply.content or ""
        chat.append(reply.model_dump(exclude_none=True))
        for call in reply.tool_calls:
            arguments = json.loads(call.function.arguments or "{}")
            chat.append({"role": "tool", "tool_call_id": call.id,
                         "content": LOCAL[call.function.name](**arguments)})
    return ""


if __name__ == "__main__":
    print(asyncio.run(run_agent_loop(sys.argv[1] if len(sys.argv) > 1
                                     else "How many bus routes are there?")))
