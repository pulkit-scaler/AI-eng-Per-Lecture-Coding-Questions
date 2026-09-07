"""Alternative 1 (client): no AsyncExitStack - the two contexts are held by hand.

Same observable behaviour as the reference, structured completely differently:
the client keeps the transport and session context managers as attributes and
unwinds them in reverse order itself, and the loop is a while loop.
"""
import asyncio
import json
import sys

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from pydantic import AnyUrl

from transit_kit import MODEL_NAME, make_client

MAX_MODEL_TURNS = 6

PERSONA = (
    "You are a transit operations analyst. Discover the tables, read the schema "
    "of whatever you need, then run one read-only query and report the answer."
)


class TransitMCPClient:

    def __init__(self, command=None, args=None, env=None):
        self.command = command or sys.executable
        self.args = list(args) if args is not None else ["server.py"]
        self.env = env
        self.session = None
        self._transport_cm = None
        self._session_cm = None

    async def connect(self):
        self._transport_cm = stdio_client(StdioServerParameters(
            command=self.command, args=self.args, env=self.env))
        reader, writer = await self._transport_cm.__aenter__()
        self._session_cm = ClientSession(reader, writer)
        self.session = await self._session_cm.__aenter__()
        await self.session.initialize()

    async def cleanup(self):
        if self._session_cm is not None:
            await self._session_cm.__aexit__(None, None, None)
            self._session_cm = None
        if self._transport_cm is not None:
            await self._transport_cm.__aexit__(None, None, None)
            self._transport_cm = None
        self.session = None

    async def __aenter__(self):
        await self.connect()
        return self

    async def __aexit__(self, *exc_info):
        await self.cleanup()

    async def list_tools(self):
        return (await self.session.list_tools()).tools

    async def call_tool(self, name, arguments=None):
        return await self.session.call_tool(name, arguments or {})

    async def read_resource(self, uri):
        contents = (await self.session.read_resource(AnyUrl(uri))).contents
        return contents[0].text

    async def list_prompts(self):
        return (await self.session.list_prompts()).prompts

    async def get_prompt(self, name, arguments=None):
        return (await self.session.get_prompt(name, arguments or {})).messages


def mcp_tools_to_openai(mcp_tools):
    return [
        {
            "type": "function",
            "function": {
                "name": tool.name,
                "description": tool.description or "",
                "parameters": tool.inputSchema or {"type": "object",
                                                   "properties": {}},
            },
        }
        for tool in mcp_tools
    ]


async def run_agent_loop(question):
    client = TransitMCPClient()
    await client.connect()
    try:
        openai_tools = mcp_tools_to_openai(await client.list_tools())
        model = make_client()
        history = [{"role": "system", "content": PERSONA},
                   {"role": "user", "content": question}]
        turn = 0
        while turn < MAX_MODEL_TURNS:
            turn += 1
            choice = model.chat.completions.create(
                model=MODEL_NAME, messages=history, tools=openai_tools,
                tool_choice="auto").choices[0]
            if not choice.message.tool_calls:
                history.append({"role": "assistant",
                                "content": choice.message.content or ""})
                return choice.message.content or ""
            history.append({
                "role": "assistant",
                "content": None,
                "tool_calls": [
                    {"id": call.id, "type": "function",
                     "function": {"name": call.function.name,
                                  "arguments": call.function.arguments}}
                    for call in choice.message.tool_calls],
            })
            for call in choice.message.tool_calls:
                outcome = await client.call_tool(
                    call.function.name,
                    json.loads(call.function.arguments or "{}"))
                blocks = [b.text for b in (outcome.content or [])
                          if getattr(b, "text", None) is not None]
                history.append({"role": "tool", "tool_call_id": call.id,
                                "content": "\n".join(blocks) or "(empty)"})
        return ""
    finally:
        await client.cleanup()


if __name__ == "__main__":
    print(asyncio.run(run_agent_loop(sys.argv[1] if len(sys.argv) > 1
                                     else "How many bus routes are there?")))
