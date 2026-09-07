"""Alternative 4 (client): the requested tool calls are executed concurrently.

Every tool call the model asks for in one turn is dispatched with asyncio.gather
and then appended in the order the model asked for them, so the tool_call_id
pairing survives the reordering. The client subclasses ClientSession usage behind
a small mixin instead of holding it as an attribute of a plain class.
"""
import asyncio
import json
import sys
from contextlib import AsyncExitStack
from typing import Any, Dict, List, Optional

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from pydantic import AnyUrl

from transit_kit import MODEL_NAME, make_client

MAX_MODEL_TURNS = 7


class _SessionHolder:
    """Everything to do with owning one MCP session over one stdio server."""

    def __init__(self, command, args, env):
        self._params = StdioServerParameters(command=command, args=args, env=env)
        self._stack = AsyncExitStack()
        self.session = None

    async def open(self):
        reader, writer = await self._stack.enter_async_context(
            stdio_client(self._params))
        self.session = await self._stack.enter_async_context(
            ClientSession(reader, writer))
        await self.session.initialize()

    async def close(self):
        await self._stack.aclose()
        self.session = None


class TransitMCPClient(_SessionHolder):

    def __init__(self, command: Optional[str] = None,
                 args: Optional[List[str]] = None,
                 env: Optional[Dict[str, str]] = None):
        super().__init__(command or sys.executable,
                         list(args) if args is not None else ["server.py"], env)

    async def connect(self):
        await self.open()

    async def cleanup(self):
        await self.close()

    async def __aenter__(self):
        await self.open()
        return self

    async def __aexit__(self, *exc_info):
        await self.close()

    async def list_tools(self):
        return (await self.session.list_tools()).tools

    async def call_tool(self, name, arguments=None):
        return await self.session.call_tool(name, arguments or {})

    async def read_resource(self, uri):
        block = (await self.session.read_resource(AnyUrl(uri))).contents[0]
        return block.text

    async def list_prompts(self):
        return (await self.session.list_prompts()).prompts

    async def get_prompt(self, name, arguments=None):
        return (await self.session.get_prompt(name, arguments or {})).messages


def mcp_tools_to_openai(mcp_tools) -> List[Dict[str, Any]]:
    functions = []
    for tool in mcp_tools:
        schema = tool.inputSchema if isinstance(tool.inputSchema, dict) else None
        functions.append({
            "type": "function",
            "function": {
                "name": tool.name,
                "description": (tool.description or "").strip() or tool.name,
                "parameters": schema or {"type": "object", "properties": {},
                                         "required": []},
            },
        })
    return functions


def _flatten(result) -> str:
    if isinstance(result, BaseException):
        return "Error: %s: %s" % (type(result).__name__, result)
    pieces = [b.text for b in (getattr(result, "content", None) or [])
              if getattr(b, "text", None) is not None]
    return "\n".join(pieces) if pieces else "(empty)"


async def run_agent_loop(question: str) -> str:
    model = make_client()
    async with TransitMCPClient() as client:
        tools = mcp_tools_to_openai(await client.list_tools())
        chat: List[Dict[str, Any]] = [
            {"role": "system",
             "content": "Larkspur Transit operations analyst. Discover, inspect, "
                        "query, answer."},
            {"role": "user", "content": question},
        ]
        for _ in range(MAX_MODEL_TURNS):
            reply = model.chat.completions.create(
                model=MODEL_NAME, messages=chat, tools=tools,
                tool_choice="auto", temperature=0.0).choices[0].message
            requested = list(reply.tool_calls or [])
            if not requested:
                chat.append({"role": "assistant", "content": reply.content or ""})
                return reply.content or ""
            chat.append(reply.model_dump(exclude_none=True))
            results = await asyncio.gather(*[
                client.call_tool(call.function.name,
                                 json.loads(call.function.arguments or "{}"))
                for call in requested], return_exceptions=True)
            for call, result in zip(requested, results):
                chat.append({"role": "tool", "tool_call_id": call.id,
                             "content": _flatten(result)})
        return ""


if __name__ == "__main__":
    print(asyncio.run(run_agent_loop(sys.argv[1] if len(sys.argv) > 1
                                     else "How many bus routes are there?")))
