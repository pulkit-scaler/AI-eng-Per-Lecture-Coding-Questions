"""Larkspur Transit MCP CLIENT and agent loop - your work goes here (Tasks 4 to 6).

This file is the client half of the lab. The server half is server.py, and the
two are separate programs: this one starts server.py as a subprocess and reaches
the database only by asking it. Do not import server.py from here.

What to do here:
  Task 4  TransitMCPClient      one server subprocess, one MCP session
  Task 5  mcp_tools_to_openai   MCP tool schemas to the OpenAI tools=[...] shape
  Task 6  run_agent_loop        one question to one answer, over the session

Add any helpers you like. The hard requirements are that everything sketched
below exists with these names and signatures, and behaves as the problem
statement describes.
"""
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

# The most model calls run_agent_loop will ever make. One pass of the loop is one
# call to chat.completions.create, so a question needing k tool steps costs k + 1.
# Must be a whole number from 1 to 8; questions here need up to four tool steps,
# so anything below 5 will cut one short.
MAX_MODEL_TURNS = 8


class TransitMCPClient:
    """An MCP client bound to one stdio server process."""

    def __init__(self, command: Optional[str] = None,
                 args: Optional[List[str]] = None,
                 env: Optional[Dict[str, str]] = None) -> None:
        raise NotImplementedError("Task 4: store the server command and set up "
                                  "the exit stack")

    async def connect(self) -> None:
        """Spawn server.py over stdio and initialise the MCP session."""
        raise NotImplementedError("Task 4: connect and initialise the session")

    async def cleanup(self) -> None:
        """Close the session and the server process."""
        raise NotImplementedError("Task 4: close everything that was opened")

    async def __aenter__(self) -> "TransitMCPClient":
        raise NotImplementedError("Task 4: connect on entry")

    async def __aexit__(self, exc_type, exc_val, exc_tb) -> None:
        raise NotImplementedError("Task 4: clean up on exit")

    async def list_tools(self) -> List[Any]:
        """Return the tools the server advertises."""
        raise NotImplementedError("Task 4: ask the server for its tools")

    async def call_tool(self, name: str,
                        arguments: Optional[Dict[str, Any]] = None) -> Any:
        """Run one tool on the server and return the result."""
        raise NotImplementedError("Task 4: relay the call to the server")

    async def read_resource(self, uri: str) -> Any:
        """Read one resource and return its content."""
        raise NotImplementedError("Task 4: read the resource")

    async def list_prompts(self) -> List[Any]:
        """Return the prompts the server advertises."""
        raise NotImplementedError("Task 4: ask the server for its prompts")

    async def get_prompt(self, name: str,
                         arguments: Optional[Dict[str, str]] = None) -> Any:
        """Fetch one prompt with its arguments filled in, and return the messages."""
        raise NotImplementedError("Task 4: fetch the prompt")


def mcp_tools_to_openai(mcp_tools) -> List[Dict[str, Any]]:
    """Convert MCP tool definitions into the OpenAI tools=[...] shape."""
    raise NotImplementedError("Task 5: convert the schemas")


async def run_agent_loop(question: str) -> str:
    """Answer one question by driving the MCP server through the model."""
    raise NotImplementedError("Task 6: run the loop")


if __name__ == "__main__":
    asked = sys.argv[1] if len(sys.argv) > 1 else "How many bus routes are there?"
    print(asyncio.run(run_agent_loop(asked)))
