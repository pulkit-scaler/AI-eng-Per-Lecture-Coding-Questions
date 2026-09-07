"""Alternative 5 (client): the loop is a generator-driven state machine.

The conversation advances through an explicit plan-free state machine and the
schema conversion is written as a dict comprehension over a helper. The client
takes its server command from an argument list built at import time.
"""
import asyncio
import json
import sys
from contextlib import AsyncExitStack

from mcp import ClientSession, StdioServerParameters, types
from mcp.client.stdio import stdio_client
from pydantic import AnyUrl

from transit_kit import MODEL_NAME, make_client

SERVER_ARGS = ["server.py"]
MAX_MODEL_TURNS = 8


def _openai_entry(tool) -> dict:
    return {
        "type": "function",
        "function": {
            "name": tool.name,
            "description": tool.description if tool.description else tool.name,
            "parameters": tool.inputSchema
            if isinstance(tool.inputSchema, dict) and tool.inputSchema
            else {"type": "object", "properties": {}},
        },
    }


def mcp_tools_to_openai(mcp_tools):
    return [_openai_entry(tool) for tool in mcp_tools]


class TransitMCPClient:
    """Async context manager over one stdio MCP server."""

    def __init__(self, command=None, args=None, env=None):
        self.command = command or sys.executable
        self.args = list(args) if args is not None else list(SERVER_ARGS)
        self.env = env
        self.exit_stack = AsyncExitStack()
        self._session = None

    async def connect(self):
        transport = await self.exit_stack.enter_async_context(stdio_client(
            StdioServerParameters(command=self.command, args=self.args,
                                  env=self.env)))
        self._session = await self.exit_stack.enter_async_context(
            ClientSession(transport[0], transport[1]))
        await self._session.initialize()

    async def cleanup(self):
        await self.exit_stack.aclose()
        self._session = None

    async def __aenter__(self):
        await self.connect()
        return self

    async def __aexit__(self, exc_type, exc, tb):
        await self.cleanup()

    @property
    def session(self):
        if self._session is None:
            raise ConnectionError("call connect() first")
        return self._session

    async def list_tools(self):
        return list((await self.session.list_tools()).tools)

    async def call_tool(self, name, arguments=None):
        return await self.session.call_tool(name, arguments or {})

    async def read_resource(self, uri):
        for block in (await self.session.read_resource(AnyUrl(uri))).contents:
            if isinstance(block, types.TextResourceContents):
                return block.text
        return ""

    async def list_prompts(self):
        return list((await self.session.list_prompts()).prompts)

    async def get_prompt(self, name, arguments=None):
        return list((await self.session.get_prompt(name, arguments or {})).messages)


class _Conversation:
    """Holds the message list and knows how to append each kind of entry."""

    def __init__(self, question):
        self.messages = [
            {"role": "system",
             "content": "Larkspur Transit operations analyst: discover the "
                        "tables, inspect the schema, then run one SELECT."},
            {"role": "user", "content": question},
        ]

    def add_assistant_calls(self, calls):
        self.messages.append({
            "role": "assistant",
            "content": None,
            "tool_calls": [{"id": call.id, "type": "function",
                            "function": {"name": call.function.name,
                                         "arguments": call.function.arguments}}
                           for call in calls],
        })

    def add_tool_result(self, call_id, text):
        self.messages.append({"role": "tool", "tool_call_id": call_id,
                              "content": text})

    def add_answer(self, text):
        self.messages.append({"role": "assistant", "content": text})


def _text(result):
    collected = []
    for block in getattr(result, "content", None) or []:
        value = getattr(block, "text", None)
        if value is not None:
            collected.append(value)
    return "\n".join(collected) or "(empty)"


async def run_agent_loop(question):
    model = make_client()
    async with TransitMCPClient() as client:
        tools = mcp_tools_to_openai(await client.list_tools())
        conversation = _Conversation(question)
        turns = 0
        while turns < MAX_MODEL_TURNS:
            turns += 1
            reply = model.chat.completions.create(
                model=MODEL_NAME, messages=conversation.messages,
                tools=tools, tool_choice="auto").choices[0].message
            calls = list(reply.tool_calls or [])
            if not calls:
                conversation.add_answer(reply.content or "")
                return reply.content or ""
            conversation.add_assistant_calls(calls)
            for call in calls:
                try:
                    arguments = json.loads(call.function.arguments or "{}")
                except ValueError:
                    arguments = {}
                try:
                    conversation.add_tool_result(
                        call.id, _text(await client.call_tool(
                            call.function.name, arguments)))
                except Exception as exc:
                    conversation.add_tool_result(call.id, "Error: %s" % exc)
        return ""


if __name__ == "__main__":
    print(asyncio.run(run_agent_loop(sys.argv[1] if len(sys.argv) > 1
                                     else "How many bus routes are there?")))
