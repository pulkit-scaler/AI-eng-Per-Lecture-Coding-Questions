"""Stage 2: turn a validated flow into something that runs.

The visual builder draws a box called Agent. What that box does, once it is
production Python, is this loop: ask the model, run the tool it asks for, hand
the result back, repeat - and stop, whatever happens, at the step limit the flow
declared.
"""
import os

from flow_kit import API_KEY_ENV, call_model, call_tool

from .spec import FlowError, plan, validate

DEFAULT_MAX_ITERATIONS = 3


class Runtime(dict):
    """A resolved flow. A mapping, so anything that reads it keeps working."""

    def __init__(self, **fields):
        super().__init__(**fields)
        self["tool_names"] = [t["name"] for t in fields.get("tools") or []]

    def __getattr__(self, name):
        try:
            return self[name]
        except KeyError:
            raise AttributeError(name)


def build_runtime(flow):
    """Resolve the flow into the handful of things a turn actually needs."""
    validate(flow)
    order = plan(flow)
    by_id = {node["id"]: node for node in flow["nodes"]}

    model_node = [n for n in flow["nodes"] if n["type"] == "LanguageModel"][0]
    model_config = dict(model_node.get("config") or {})
    # The export carries a placeholder where the key was. The credential comes
    # from the environment in production, and the placeholder never leaves here.
    model_config.pop("api_key", None)
    max_iterations = int(model_config.pop("max_iterations",
                                          DEFAULT_MAX_ITERATIONS))

    system = ""
    tools = []
    memory = None
    # The order the plan gives is the order the inputs were resolved in, so a
    # flow that lists its tools in a particular order keeps it.
    position = {node_id: index for index, node_id in enumerate(order)}
    for connection in sorted(flow.get("edges") or [],
                             key=lambda e: position.get(e.get("source"), 0)):
        if connection.get("target") != model_node["id"]:
            continue
        source = by_id.get(connection.get("source"))
        if source is None:
            continue
        port = connection.get("port")
        config = source.get("config") or {}
        if port == "prompt":
            system = config.get("template") or ""
        elif port == "tools":
            tools.append({"name": config.get("tool"),
                          "max_results": int(config.get("max_results", 5))})
        elif port == "memory":
            memory = {"window": int(config.get("window", 6))}

    return Runtime(name=flow.get("name") or "flow",
                   config={"model": model_config.get("model"),
                           "temperature": model_config.get("temperature", 0)},
                   system=system, tools=tools, memory=memory,
                   max_iterations=max_iterations, order=order)


def _api_key():
    key = os.environ.get(API_KEY_ENV, "")
    if not key.strip():
        raise FlowError(
            "no credential in the environment. A visual builder writes a "
            "placeholder into the export where the key was; set %s before "
            "running this flow" % API_KEY_ENV)
    return key


def run_turn(runtime, message, history=None):
    """One turn through the flow. Returns the reply and what it took to get it."""
    key = _api_key()
    window = (runtime.get("memory") or {}).get("window")
    earlier = list(history or [])
    if window:
        earlier = earlier[-window:]
    elif runtime.get("memory") is None:
        # No memory node in the flow, so nothing carries between turns.
        earlier = []

    messages = earlier + [{"role": "user", "content": message}]
    trace = {"tool_calls": [], "model_calls": 0, "stopped_early": False}
    by_name = {t["name"]: t for t in runtime["tools"]}

    for _ in range(runtime["max_iterations"]):
        step = call_model(runtime["config"], runtime["system"], messages,
                          runtime["tool_names"], key)
        trace["model_calls"] += 1
        if step.get("type") != "tool":
            text = step.get("text") or ""
            messages.append({"role": "assistant", "content": text})
            return text, trace

        name = step.get("tool")
        spec = by_name.get(name)
        if spec is None:
            raise FlowError("the model asked for the tool %r, which this flow "
                            "does not wire" % name)
        observation = call_tool(name, step.get("input") or message,
                                spec["max_results"])
        trace["tool_calls"].append(name)
        messages.append({"role": "tool", "name": name, "content": observation})

    # Out of steps. Rather than return the last tool output raw, ask for a
    # wrap-up: the prototype in the builder would have run forever here.
    step = call_model(runtime["config"], runtime["system"], messages,
                      runtime["tool_names"], key, force_final=True)
    trace["model_calls"] += 1
    trace["stopped_early"] = True
    text = step.get("text") or ""
    messages.append({"role": "assistant", "content": text})
    return text, trace
