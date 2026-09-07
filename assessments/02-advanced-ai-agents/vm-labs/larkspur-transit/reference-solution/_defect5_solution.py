"""Defect 5 (client): tool results go back as plain user messages.

The tool call is executed through MCP and the observation is appended, but as a
user message with no tool_call_id, so nothing ties the result to the call that
asked for it. Expected: TC05 fails, the rest pass.
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
        self._command = command or sys.executable
        self._args = list(args) if args is not None else ["server.py"]
        self._env = env
        self._stack = AsyncExitStack()
        self.session = None

    async def connect(self):
        reader, writer = await self._stack.enter_async_context(stdio_client(
            StdioServerParameters(command=self._command, args=self._args,
                                  env=self._env)))
        self.session = await self._stack.enter_async_context(
            ClientSession(reader, writer))
        await self.session.initialize()

    async def cleanup(self):
        await self._stack.aclose()
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
        return (await self.session.read_resource(AnyUrl(uri))).contents[0].text

    async def list_prompts(self):
        return (await self.session.list_prompts()).prompts

    async def get_prompt(self, name, arguments=None):
        return (await self.session.get_prompt(name, arguments or {})).messages


def mcp_tools_to_openai(mcp_tools):
    return [{"type": "function",
             "function": {"name": tool.name,
                          "description": tool.description or "",
                          "parameters": tool.inputSchema or {"type": "object",
                                                             "properties": {}}}}
            for tool in mcp_tools]


async def run_agent_loop(question):
    model = make_client()
    async with TransitMCPClient() as client:
        tools = mcp_tools_to_openai(await client.list_tools())
        chat = [{"role": "system", "content": "Operations analyst."},
                {"role": "user", "content": question}]
        for _ in range(MAX_MODEL_TURNS):
            reply = model.chat.completions.create(
                model=MODEL_NAME, messages=chat, tools=tools,
                tool_choice="auto").choices[0].message
            if not reply.tool_calls:
                return reply.content or ""
            chat.append({"role": "assistant", "content": reply.content or ""})
            for call in reply.tool_calls:
                result = await client.call_tool(
                    call.function.name,
                    json.loads(call.function.arguments or "{}"))
                text = "\n".join(b.text for b in (result.content or [])
                                 if getattr(b, "text", None) is not None)
                # The observation is handed back as ordinary conversation, so the
                # call it answers is anybody guess.
                chat.append({"role": "user",
                             "content": "tool output:\n" + (text or "(empty)")})
        return ""


if __name__ == "__main__":
    print(asyncio.run(run_agent_loop(sys.argv[1] if len(sys.argv) > 1
                                     else "How many bus routes are there?")))
