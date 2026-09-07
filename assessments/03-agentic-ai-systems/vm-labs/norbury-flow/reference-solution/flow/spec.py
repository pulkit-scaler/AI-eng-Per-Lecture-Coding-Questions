"""Stage 1: read a flow export and decide whether it is runnable.

A prototype that half-runs is worse than one that refuses to start, because the
half that did not run is silent. Everything the runtime will rely on is checked
here, once, and every refusal names the node it is about.
"""
import json

from flow_kit import MODEL_PORTS, NODE_KINDS, TOOL_NAMES

SINGLETONS = ("ChatInput", "LanguageModel", "ChatOutput")


class FlowError(Exception):
    """A flow that cannot be run, with a message naming what is wrong."""


def load_flow(path):
    """Read an export from disk. The file being unreadable is a FlowError."""
    try:
        with open(path) as handle:
            flow = json.load(handle)
    except (OSError, ValueError) as exc:
        raise FlowError("could not read the flow at %s: %s" % (path, exc))
    if not isinstance(flow, dict):
        raise FlowError("a flow export has to be an object, %s found"
                        % type(flow).__name__)
    return flow


def _nodes(flow):
    nodes = flow.get("nodes")
    if not isinstance(nodes, list) or not nodes:
        raise FlowError("the flow has no nodes")
    return nodes


def validate(flow):
    """Raise FlowError unless every node and edge is one the runtime can run."""
    nodes = _nodes(flow)
    edges = flow.get("edges")
    if not isinstance(edges, list):
        raise FlowError("the flow has no edges")

    by_id = {}
    for node in nodes:
        node_id = node.get("id")
        if not node_id:
            raise FlowError("a node has no id")
        if node_id in by_id:
            raise FlowError("two nodes share the id %r" % node_id)
        kind = node.get("type")
        if kind not in NODE_KINDS:
            raise FlowError("node %s is a %r, which this runtime has no "
                            "component for. Known kinds are %s"
                            % (node_id, kind, ", ".join(NODE_KINDS)))
        by_id[node_id] = node

    counts = {}
    for node in nodes:
        counts[node["type"]] = counts.get(node["type"], 0) + 1
    for kind in SINGLETONS:
        found = counts.get(kind, 0)
        if found != 1:
            raise FlowError("a flow needs exactly one %s, this one has %d"
                            % (kind, found))

    for node in nodes:
        if node["type"] != "Tool":
            continue
        tool = (node.get("config") or {}).get("tool")
        if tool not in TOOL_NAMES:
            raise FlowError("node %s is wired to the tool %r, which does not "
                            "exist. Available tools are %s"
                            % (node["id"], tool, ", ".join(TOOL_NAMES)))

    model = [n for n in nodes if n["type"] == "LanguageModel"][0]
    if not (model.get("config") or {}).get("model"):
        raise FlowError("node %s does not say which model to use"
                        % model["id"])

    for index, connection in enumerate(edges):
        source = connection.get("source")
        target = connection.get("target")
        port = connection.get("port")
        for end, label in ((source, "source"), (target, "target")):
            if end not in by_id:
                raise FlowError("edge %d has a %s of %r, and there is no such "
                                "node in the flow" % (index, label, end))
        if by_id[target]["type"] == "LanguageModel" and port not in MODEL_PORTS:
            raise FlowError("edge %d connects to %s on the port %r; a model "
                            "accepts %s" % (index, target, port,
                                            ", ".join(MODEL_PORTS)))

    plan(flow)  # raises on a cycle

    reachable = set()
    frontier = [n["id"] for n in nodes if n["type"] == "ChatInput"]
    outgoing = {}
    for connection in edges:
        outgoing.setdefault(connection["source"], []).append(
            connection["target"])
    while frontier:
        current = frontier.pop()
        if current in reachable:
            continue
        reachable.add(current)
        frontier.extend(outgoing.get(current, []))
    output = [n["id"] for n in nodes if n["type"] == "ChatOutput"][0]
    if output not in reachable:
        raise FlowError("nothing connects the input to %s, so the flow has no "
                        "way to answer" % output)


def plan(flow):
    """The order the runtime assembles the nodes in, inputs before consumers."""
    nodes = _nodes(flow)
    edges = flow.get("edges") or []
    ids = [n["id"] for n in nodes]
    incoming = {node_id: set() for node_id in ids}
    outgoing = {node_id: [] for node_id in ids}
    for connection in edges:
        source, target = connection.get("source"), connection.get("target")
        if source in incoming and target in incoming:
            incoming[target].add(source)
            outgoing[source].append(target)

    # Several nodes have nothing feeding them, so more than one order is
    # valid. The flow starts where the message comes in, so that one goes
    # first and the rest follow in a stable order.
    roots = [node_id for node_id in ids if not incoming[node_id]]
    entry = [n["id"] for n in nodes if n["type"] == "ChatInput"]
    ready = ([node_id for node_id in entry if node_id in roots]
             + sorted(node_id for node_id in roots if node_id not in entry))
    order = []
    remaining = {node_id: set(parents) for node_id, parents in incoming.items()}
    while ready:
        current = ready.pop(0)
        order.append(current)
        for child in sorted(outgoing[current]):
            remaining[child].discard(current)
            if not remaining[child] and child not in order \
                    and child not in ready:
                ready.append(child)
        ready = ready[:1] + sorted(ready[1:])
    if len(order) != len(ids):
        stuck = sorted(set(ids) - set(order))
        raise FlowError("these nodes are in a loop, so there is no order to "
                        "run them in: %s" % ", ".join(stuck))
    return order
