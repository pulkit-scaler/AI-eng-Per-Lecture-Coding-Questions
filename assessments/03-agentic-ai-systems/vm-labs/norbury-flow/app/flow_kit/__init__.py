"""What the runtime is built out of. Provided, do not modify."""
import os

from .client import BASE_URL, NorburyError, post_json

# The component kinds a flow export may contain.
NODE_KINDS = ("ChatInput", "Prompt", "LanguageModel", "Tool", "Memory",
              "ChatOutput")

# The ports a LanguageModel node accepts a connection on.
MODEL_PORTS = ("input", "prompt", "tools", "memory")

# The three tool backends. A Tool node names one of these in its config.
TOOL_NAMES = ("arxiv_search", "web_search", "summarise")

# Where the credential comes from in production. Never from the export.
API_KEY_ENV = "NORBURY_API_KEY"


def call_tool(name, text, max_results=5):
    """Run one tool backend and return what it found, as text."""
    if name not in TOOL_NAMES:
        raise ValueError("unknown tool %r, expected one of %s"
                         % (name, ", ".join(TOOL_NAMES)))
    reply = post_json("/v1/tool", {
        "tool": name, "input": text, "max_results": max_results,
        "run_id": os.environ.get("NORBURY_RUN_ID", "default"),
    })
    return reply.get("text") or ""


def call_model(config, system, messages, tools, api_key, force_final=False):
    """Ask the model what to do next.

    `config` carries at least `model` and `temperature`. `messages` is the
    conversation so far: dicts with `role` (`user`, `assistant` or `tool`),
    `content`, and for a tool result also `name`.

    Returns either `{"type": "final", "text": ...}` or
    `{"type": "tool", "tool": ..., "input": ...}`. With `force_final` set it
    always returns a final answer, which is how a runtime that has run out of
    steps still ends with something to say.

    Raises `NorburyError` if the credential is missing or is the placeholder a
    builder writes into an export.
    """
    return post_json("/v1/model", {
        "config": dict(config or {}),
        "system": system or "",
        "messages": list(messages or []),
        "tools": list(tools or []),
        "api_key": api_key or "",
        "force_final": bool(force_final),
        "run_id": os.environ.get("NORBURY_RUN_ID", "default"),
    })


__all__ = ["call_model", "call_tool", "NODE_KINDS", "MODEL_PORTS",
           "TOOL_NAMES", "API_KEY_ENV", "NorburyError", "post_json",
           "BASE_URL"]
