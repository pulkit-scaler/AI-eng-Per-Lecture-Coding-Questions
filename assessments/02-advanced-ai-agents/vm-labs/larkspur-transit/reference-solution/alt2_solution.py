"""Alternative 2 (client): a dataclass plus an asynccontextmanager factory.

The class is a plain dataclass whose async-with support is delegated to an
@asynccontextmanager helper, and the conversion function walks the MCP schemas
into a copy so it never shares a dict with the SDK objects.
"""
import asyncio
import copy
import json
import sys
from contextlib import asynccontextmanager
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client
from pydantic import AnyUrl

from transit_kit import MODEL_NAME, make_client

MAX_MODEL_TURNS = 8

SYSTEM = ("Transit operations analyst. Discover, inspect, then query. One "
          "read-only SELECT, then report the answer in a sentence.")


@asynccontextmanager
async def _open(command: str, args: List[str], env: Optional[dict]):
    async with stdio_client(StdioServerParameters(
            command=command, args=args, env=env)) as (reader, writer):
        async with ClientSession(reader, writer) as session:
            await session.initialize()
            yield session


@dataclass
class TransitMCPClient:
    command: str = sys.executable
    args: List[str] = field(default_factory=lambda: ["server.py"])
    env: Optional[dict] = None
    session: Optional[ClientSession] = None
    _cm: Any = None

    async def connect(self) -> None:
        self._cm = _open(self.command, self.args, self.env)
        self.session = await self._cm.__aenter__()

    async def cleanup(self) -> None:
        if self._cm is not None:
            await self._cm.__aexit__(None, None, None)
        self._cm = None
        self.session = None

    async def __aenter__(self) -> "TransitMCPClient":
        await self.connect()
        return self

    async def __aexit__(self, *exc_info) -> None:
        await self.cleanup()

    async def list_tools(self):
        return (await self.session.list_tools()).tools

    async def call_tool(self, name: str, arguments: Optional[dict] = None):
        return await self.session.call_tool(name, dict(arguments or {}))

    async def read_resource(self, uri: str):
        first = (await self.session.read_resource(AnyUrl(uri))).contents[0]
        payload = getattr(first, "text", "")
        if getattr(first, "mimeType", "") == "application/json":
            return json.loads(payload)
        return payload

    async def list_prompts(self):
        return (await self.session.list_prompts()).prompts

    async def get_prompt(self, name: str, arguments: Optional[dict] = None):
        return (await self.session.get_prompt(name, dict(arguments or {}))).messages


def mcp_tools_to_openai(mcp_tools) -> List[Dict[str, Any]]:
    out: List[Dict[str, Any]] = []
    for tool in mcp_tools:
        parameters = copy.deepcopy(dict(tool.inputSchema or {}))
        parameters.setdefault("type", "object")
        parameters.setdefault("properties", {})
        out.append({"type": "function",
                    "function": {"name": tool.name,
                                 "description": tool.description or tool.name,
                                 "parameters": parameters}})
    return out


async def _run_one(session_client, model, question: str) -> str:
    tools = mcp_tools_to_openai(await session_client.list_tools())
    chat = [{"role": "system", "content": SYSTEM},
            {"role": "user", "content": question}]
    for _ in range(MAX_MODEL_TURNS):
        message = model.chat.completions.create(
            model=MODEL_NAME, messages=chat, tools=tools,
            tool_choice="auto").choices[0].message
        calls = message.tool_calls or []
        if not calls:
            chat.append({"role": "assistant", "content": message.content or ""})
            return message.content or ""
        chat.append(message.model_dump(exclude_none=True))
        for call in calls:
            try:
                args = json.loads(call.function.arguments or "{}")
            except ValueError:
                args = {}
            result = await session_client.call_tool(call.function.name, args)
            text = "\n".join(b.text for b in (result.content or [])
                             if getattr(b, "text", None) is not None)
            chat.append({"role": "tool", "tool_call_id": call.id,
                         "content": text or "(empty)"})
    return ""


async def run_agent_loop(question: str) -> str:
    async with TransitMCPClient() as client:
        return await _run_one(client, make_client(), question)


if __name__ == "__main__":
    print(asyncio.run(run_agent_loop(sys.argv[1] if len(sys.argv) > 1
                                     else "How many bus routes are there?")))
