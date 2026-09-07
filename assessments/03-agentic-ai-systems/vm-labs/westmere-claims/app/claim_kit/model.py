"""The chat model the claims desk serves.

Provided, do not modify.

`get_chat_model()` returns a LangChain chat model that supports:

* `.invoke(messages)` — an `AIMessage` with the desk reply.
* `.with_structured_output(Schema)` — a runnable whose `.invoke(prompt)` returns
  an instance of `Schema`. `method=` is accepted and makes no difference.

Both go through the desk, which is what attributes a call to your run.
"""
from typing import Any, List, Optional, Sequence

from langchain_core.callbacks import CallbackManagerForLLMRun
from langchain_core.language_models.chat_models import BaseChatModel
from langchain_core.messages import (AIMessage, BaseMessage, HumanMessage,
                                     SystemMessage, ToolMessage)
from langchain_core.outputs import ChatGeneration, ChatResult
from langchain_core.runnables import Runnable, RunnableConfig

from .client import post_json

MODEL = "westmere-desk"


def _role_of(message: BaseMessage) -> str:
    if isinstance(message, HumanMessage):
        return "human"
    if isinstance(message, ToolMessage):
        return "tool"
    if isinstance(message, SystemMessage):
        return "system"
    if isinstance(message, AIMessage):
        return "ai"
    return getattr(message, "type", "human")


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


def _serialise(messages: Sequence[BaseMessage]) -> List[dict]:
    return [{"role": _role_of(m), "content": _content_of(m)} for m in messages]


def _as_prompt(value: Any) -> str:
    """Flatten whatever was handed to a structured runnable into one string."""
    if isinstance(value, str):
        return value
    if isinstance(value, BaseMessage):
        return _content_of(value)
    if hasattr(value, "to_messages"):
        return _as_prompt(value.to_messages())
    if isinstance(value, (list, tuple)):
        return "\n".join(_as_prompt(v) for v in value)
    if isinstance(value, dict):
        for key in ("prompt", "content", "input", "text"):
            if key in value:
                return _as_prompt(value[key])
        return str(value)
    return str(value)


class DeskRecord(Runnable):
    """What `with_structured_output` hands back: text in, schema instance out."""

    def __init__(self, schema: Any):
        self.schema = schema

    @property
    def _schema_name(self) -> str:
        return getattr(self.schema, "__name__", str(self.schema))

    def invoke(self, input: Any, config: Optional[RunnableConfig] = None,
               **kwargs: Any) -> Any:
        payload = post_json("/v1/structured", {
            "schema": self._schema_name,
            "prompt": _as_prompt(input),
        })
        return self.schema(**payload)


class DeskChatModel(BaseChatModel):
    """The claims desk, behind a LangChain chat model interface."""

    @property
    def _llm_type(self) -> str:
        return "westmere-desk"

    def with_structured_output(self, schema: Any, *, include_raw: bool = False,
                               method: Optional[str] = None,
                               **kwargs: Any) -> Runnable:
        return DeskRecord(schema)

    def _generate(self, messages: List[BaseMessage],
                  stop: Optional[List[str]] = None,
                  run_manager: Optional[CallbackManagerForLLMRun] = None,
                  **kwargs: Any) -> ChatResult:
        reply = post_json("/v1/chat", {"messages": _serialise(messages)})
        return ChatResult(generations=[
            ChatGeneration(message=AIMessage(content=reply.get("content", "")))])


def get_chat_model() -> DeskChatModel:
    """Return a ready-to-use claims desk chat model."""
    return DeskChatModel()
