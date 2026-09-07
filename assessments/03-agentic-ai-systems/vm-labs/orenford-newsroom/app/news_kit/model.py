"""The chat model the newsroom wire serves.

Provided, do not modify.

    get_chat_model("planner")   a model tagged with the role that is calling it

Every call is attributed to that role, which is how the newsroom accounts for
its own work. The roles are planner, researcher, writer and critic.

The returned model supports:

* `.invoke(messages)` -> an `AIMessage`.
* `.with_structured_output(Schema)` -> a runnable whose `.invoke(prompt)` returns
  an instance of `Schema`. Extra keyword arguments are passed to the wire
  alongside the prompt - give them to `with_structured_output` or to `.invoke`,
  either reaches the wire - which is how a desk finding says which desk it is
  from.

The wire answers a record by the name of the model it is asked for, so keep the
names it knows: `Plan`, `Finding`, `Draft`, `Critique`.
"""
from typing import Any, List, Optional, Sequence

from langchain_core.callbacks import CallbackManagerForLLMRun
from langchain_core.language_models.chat_models import BaseChatModel
from langchain_core.messages import (AIMessage, BaseMessage, HumanMessage,
                                     SystemMessage, ToolMessage)
from langchain_core.outputs import ChatGeneration, ChatResult
from langchain_core.runnables import Runnable, RunnableConfig

from .client import post_json

ROLES = ("planner", "researcher", "writer", "critic")


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


def _as_prompt(value: Any) -> str:
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


class WireRecord(Runnable):
    """What `with_structured_output` hands back: text in, schema instance out."""

    def __init__(self, schema: Any, role: str, extra: dict):
        self.schema = schema
        self.role = role
        self.extra = extra

    @property
    def _schema_name(self) -> str:
        return getattr(self.schema, "__name__", str(self.schema))

    def invoke(self, input: Any, config: Optional[RunnableConfig] = None,
               **kwargs: Any) -> Any:
        payload = {"schema": self._schema_name, "prompt": _as_prompt(input)}
        # An extra reaches the wire whether it was given to
        # `with_structured_output` or to this call; the one given with the
        # schema wins. Silently dropping the ones given here made a request
        # that carried the desk look identical to one that carried nothing.
        payload.update({key: value for key, value in kwargs.items()
                        if value is not None
                        and key not in ("schema", "prompt")})
        payload.update(self.extra)
        answer = post_json("/v1/structured", payload, role=self.role)
        return self.schema(**answer)


class WireChatModel(BaseChatModel):
    """The newsroom wire, behind a LangChain chat model interface."""

    role: str = "unknown"

    @property
    def _llm_type(self) -> str:
        return "orenford-wire"

    def with_structured_output(self, schema: Any, *, include_raw: bool = False,
                               method: Optional[str] = None,
                               **kwargs: Any) -> Runnable:
        return WireRecord(schema, self.role, dict(kwargs))

    def _generate(self, messages: List[BaseMessage],
                  stop: Optional[List[str]] = None,
                  run_manager: Optional[CallbackManagerForLLMRun] = None,
                  **kwargs: Any) -> ChatResult:
        reply = post_json("/v1/chat", {"messages": [
            {"role": _role_of(m), "content": _content_of(m)} for m in messages
        ]}, role=self.role)
        return ChatResult(generations=[
            ChatGeneration(message=AIMessage(content=reply.get("content", "")))])


def get_chat_model(role: str) -> WireChatModel:
    """A model tagged with the role that is calling it."""
    if role not in ROLES:
        raise ValueError("role must be one of %s, not %r" % (", ".join(ROLES),
                                                             role))
    return WireChatModel(role=role)
