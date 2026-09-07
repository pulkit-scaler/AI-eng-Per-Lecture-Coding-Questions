"""Cheat probe (client): the answer is returned without asking anything.

No MCP session, no model call, no database. Expected: TC05 fails.
"""
import asyncio
import sys

MAX_MODEL_TURNS = 8

CANNED = {
    "how many bus routes are there?": "There are 5 bus routes.",
    "which route carried the most total boardings?":
        "The busiest route by total boardings is Metro Cross-City.",
    "how many vehicles are stationed at the kingsmere depot?":
        "There are 6 vehicles stationed at the Kingsmere depot.",
}


class TransitMCPClient:
    async def __aenter__(self):
        return self

    async def __aexit__(self, *exc_info):
        return None

    async def list_tools(self):
        return []

    async def call_tool(self, name, arguments=None):
        return None

    async def read_resource(self, uri):
        return ""

    async def list_prompts(self):
        return []

    async def get_prompt(self, name, arguments=None):
        return []


def mcp_tools_to_openai(mcp_tools):
    return []


async def run_agent_loop(question):
    return CANNED.get((question or "").strip().lower(), "I do not know.")


if __name__ == "__main__":
    print(asyncio.run(run_agent_loop(sys.argv[1] if len(sys.argv) > 1
                                     else "How many bus routes are there?")))
