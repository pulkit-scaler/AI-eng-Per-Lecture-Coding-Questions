"""Alternative 3 (client): one long-lived session reused across questions.

The client is created once at module level and connected on first use; the loop
recurses instead of iterating, and the tool schemas are cached after the first
discovery.
"""
import asyncio
import json
import sys
from contextlib import AsyncExitStack

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from pydantic import AnyUrl

from transit_kit import MODEL_NAME, make_client

MAX_MODEL_TURNS = 8


class TransitMCPClient:

    def __init__(self, command=None, args=None, env=None):
        self._spawn = (command or sys.executable,
                       list(args) if args is not None else ["server.py"], env)
        self._stack = AsyncExitStack()
        self._session = None
        self._tool_cache = None

    async def connect(self):
        command, args, env = self._spawn
        streams = await self._stack.enter_async_context(stdio_client(
            StdioServerParameters(command=command, args=args, env=env)))
        self._session = await self._stack.enter_async_context(
            ClientSession(*streams))
        await self._session.initialize()
        return self

    async def cleanup(self):
        await self._stack.aclose()
        self._session = None
        self._tool_cache = None

    async def __aenter__(self):
        return await self.connect()

    async def __aexit__(self, *exc_info):
        await self.cleanup()

    async def list_tools(self):
        if self._tool_cache is None:
            self._tool_cache = (await self._session.list_tools()).tools
        return self._tool_cache

    async def call_tool(self, name, arguments=None):
        return await self._session.call_tool(name, arguments or {})

    async def read_resource(self, uri):
        result = await self._session.read_resource(AnyUrl(uri))
        return result.contents[0].text

    async def list_prompts(self):
        return (await self._session.list_prompts()).prompts

    async def get_prompt(self, name, arguments=None):
        return (await self._session.get_prompt(name, arguments or {})).messages


def mcp_tools_to_openai(mcp_tools):
    converted = []
    for tool in mcp_tools:
        entry = {"type": "function", "function": {}}
        entry["function"]["name"] = tool.name
        entry["function"]["description"] = tool.description or ""
        entry["function"]["parameters"] = dict(tool.inputSchema or {})
        converted.append(entry)
    return converted


def _observation(result):
    chunks = []
    for block in result.content or []:
        if getattr(block, "text", None) is not None:
            chunks.append(block.text)
    return "\n".join(chunks) if chunks else "(empty)"


async def _step(client, model, tools, chat, turns_left):
    if turns_left <= 0:
        return ""
    message = model.chat.completions.create(
        model=MODEL_NAME, messages=chat, tools=tools,
        tool_choice="auto").choices[0].message
    if not message.tool_calls:
        chat.append({"role": "assistant", "content": message.content or ""})
        return message.content or ""
    chat.append(message.model_dump(exclude_none=True))
    for call in message.tool_calls:
        arguments = json.loads(call.function.arguments or "{}")
        try:
            outcome = await client.call_tool(call.function.name, arguments)
            observation = _observation(outcome)
        except Exception as exc:
            observation = "Error: %s" % exc
        chat.append({"role": "tool", "tool_call_id": call.id,
                     "content": observation})
    return await _step(client, model, tools, chat, turns_left - 1)


async def run_agent_loop(question):
    async with TransitMCPClient() as client:
        tools = mcp_tools_to_openai(await client.list_tools())
        chat = [
            {"role": "system",
             "content": "You are the Larkspur Transit operations analyst. Use the "
                        "tools to find the answer, then state it plainly."},
            {"role": "user", "content": question},
        ]
        return await _step(client, make_client(), tools, chat, MAX_MODEL_TURNS)


if __name__ == "__main__":
    print(asyncio.run(run_agent_loop(sys.argv[1] if len(sys.argv) > 1
                                     else "How many bus routes are there?")))
