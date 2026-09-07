"""The analysis model the approval agent reasons with.

Provided, do not modify.

`get_chat_model()` returns a LangChain chat model whose `.invoke(prompt)` gives
back an `AIMessage` whose content is a JSON object with `category_valid`,
`risk_level` and `reasoning`. It may wrap that object in a code fence, the way
models do.
"""
import json
import os
from typing import Any, List, Optional, Sequence

from langchain_core.callbacks import CallbackManagerForLLMRun
from langchain_core.language_models.chat_models import BaseChatModel
from langchain_core.messages import (AIMessage, BaseMessage, HumanMessage,
                                     SystemMessage)
from langchain_core.outputs import ChatGeneration, ChatResult

from .client import post_json

MODEL = "pelham-analyst"


def _content_of(message: BaseMessage) -> str:
    content = message.content
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        parts = []
        for block in content:
            if isinstance(block, str):
                parts.append(block)
            elif isinstance(block, dict) and "text" in block:
                parts.append(str(block["text"]))
        return "".join(parts)
    return str(content)


def _role_of(message: BaseMessage) -> str:
    if isinstance(message, HumanMessage):
        return "human"
    if isinstance(message, SystemMessage):
        return "system"
    if isinstance(message, AIMessage):
        return "ai"
    return getattr(message, "type", "human")


class AnalystModel(BaseChatModel):
    """The finance desk, behind a LangChain chat model interface."""

    @property
    def _llm_type(self) -> str:
        return "pelham-analyst"

    def _generate(self, messages: List[BaseMessage],
                  stop: Optional[List[str]] = None,
                  run_manager: Optional[CallbackManagerForLLMRun] = None,
                  **kwargs: Any) -> ChatResult:
        payload = post_json("/v1/chat", {
            "messages": [{"role": _role_of(m), "content": _content_of(m)}
                         for m in messages],
            "run_id": os.environ.get("PELHAM_RUN_ID", "default"),
        })
        body = payload.get("content") or ""
        # Models fence their JSON often enough that a caller has to expect it.
        return ChatResult(generations=[
            ChatGeneration(message=AIMessage(content="```json\n%s\n```" % body))])


def get_chat_model() -> AnalystModel:
    """Return a ready-to-use analysis model."""
    return AnalystModel()
