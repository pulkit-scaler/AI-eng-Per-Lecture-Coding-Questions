"""Environment probe (never graded - the sweep glob does not pick up this prefix).

The reference client with one extra module-scope import that the VM does not have.
Costs only the loop theme, because the server lives in a separate file - which is
worth knowing when a learner reports a partial score.
"""
import numpy  # noqa: F401  - deliberately absent from the lab environment

import asyncio
import json
import sys
from contextlib import AsyncExitStack
from typing import Any, Dict, List, Optional

from mcp import ClientSession, StdioServerParameters, types
from mcp.client.stdio import stdio_client
from pydantic import AnyUrl

from transit_kit import MODEL_NAME, make_client

SERVER_SCRIPT = "server.py"
MAX_MODEL_TURNS = 8

SYSTEM_PROMPT = (
    "You are the Larkspur Transit operations analyst. Answer questions about "
    "the operations database by discovering the tables, inspecting the schema "
    "of the ones you need, and running a single read-only SQL query. Use only "
    "column names the schema tool confirmed, and never modify data."
)


class TransitMCPClient:
    """An MCP client bound to one stdio server process."""

    def __init__(self, command: Optional[str] = None,
                 args: Optional[List[str]] = None,
                 env: Optional[Dict[str, str]] = None) -> None:
        self._command = command or sys.executable
        self._args = list(args) if args is not None else [SERVER_SCRIPT]
        self._env = env
        self._session: Optional[ClientSession] = None
        self._stack = AsyncExitStack()

    # -- lifecycle ---------------------------------------------------------

    async def connect(self) -> None:
        params = StdioServerParameters(command=self._command, args=self._args,
                                      env=self._env)
        read_stream, write_stream = await self._stack.enter_async_context(
            stdio_client(params))
        self._session = await self._stack.enter_async_context(
            ClientSession(read_stream, write_stream))
        await self._session.initialize()

    async def cleanup(self) -> None:
        await self._stack.aclose()
        self._session = None

    async def __aenter__(self) -> "TransitMCPClient":
        await self.connect()
        return self

    async def __aexit__(self, exc_type, exc_val, exc_tb) -> None:
        await self.cleanup()

    @property
    def session(self) -> ClientSession:
        if self._session is None:
            raise ConnectionError(
                "not connected - use 'async with TransitMCPClient()' or await "
                "connect() first")
        return self._session

    # -- tools -------------------------------------------------------------

    async def list_tools(self) -> List[types.Tool]:
        return (await self.session.list_tools()).tools

    async def call_tool(self, name: str,
                        arguments: Optional[Dict[str, Any]] = None):
        return await self.session.call_tool(name, arguments or {})

    # -- resources ---------------------------------------------------------

    async def list_resources(self) -> List[types.Resource]:
        return (await self.session.list_resources()).resources

    async def read_resource(self, uri: str) -> Any:
        result = await self.session.read_resource(AnyUrl(uri))
        block = result.contents[0]
        text = getattr(block, "text", None)
        if text is None:
            return block
        if getattr(block, "mimeType", None) == "application/json":
            return json.loads(text)
        return text

    # -- prompts -----------------------------------------------------------

    async def list_prompts(self) -> List[types.Prompt]:
        return (await self.session.list_prompts()).prompts

    async def get_prompt(self, name: str,
                         arguments: Optional[Dict[str, str]] = None):
        result = await self.session.get_prompt(name, arguments or {})
        return result.messages


def mcp_tools_to_openai(mcp_tools) -> List[Dict[str, Any]]:
    """Turn MCP tool definitions into the OpenAI tools=[...] shape."""
    converted = []
    for tool in mcp_tools:
        schema = getattr(tool, "inputSchema", None)
        if not isinstance(schema, dict) or not schema:
            schema = {"type": "object", "properties": {}}
        converted.append({
            "type": "function",
            "function": {
                "name": tool.name,
                "description": tool.description or "",
                "parameters": schema,
            },
        })
    return converted


def tool_result_text(result) -> str:
    """Flatten an MCP tool result into the text the model should read."""
    parts = []
    for block in getattr(result, "content", None) or []:
        text = getattr(block, "text", None)
        if text is not None:
            parts.append(text)
    return "\n".join(parts) if parts else "(empty)"


async def run_agent_loop(question: str) -> str:
    """Answer one question by driving the MCP server through the model."""
    model = make_client()
    async with TransitMCPClient() as client:
        mcp_tools = await client.list_tools()
        openai_tools = mcp_tools_to_openai(mcp_tools)

        messages: List[Dict[str, Any]] = [
            {"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": question},
        ]

        answer = ""
        for _turn in range(MAX_MODEL_TURNS):
            response = model.chat.completions.create(
                model=MODEL_NAME,
                messages=messages,
                tools=openai_tools,
                tool_choice="auto",
                temperature=0.0,
            )
            reply = response.choices[0].message

            if not reply.tool_calls:
                answer = reply.content or ""
                messages.append({"role": "assistant", "content": answer})
                break

            messages.append(reply.model_dump(exclude_none=True))
            for call in reply.tool_calls:
                name = call.function.name
                try:
                    arguments = json.loads(call.function.arguments or "{}")
                except ValueError:
                    arguments = {}
                try:
                    result = await client.call_tool(name, arguments)
                    output = tool_result_text(result)
                except Exception as exc:  # a tool refusal is information
                    output = "Error: %s: %s" % (type(exc).__name__, exc)
                messages.append({
                    "role": "tool",
                    "tool_call_id": call.id,
                    "content": output,
                })

        return answer


if __name__ == "__main__":
    asked = sys.argv[1] if len(sys.argv) > 1 else "How many bus routes are there?"
    print(asyncio.run(run_agent_loop(asked)))
