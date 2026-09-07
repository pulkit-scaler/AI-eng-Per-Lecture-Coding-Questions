"""The graph the nodes are wired into."""
from typing import Any, Dict, List, Optional, TypedDict

from langgraph.checkpoint.memory import MemorySaver
from langgraph.graph import END, START, StateGraph

from .nodes import (auto_approve, deliberate, finalize, human_review, perceive,
                    route_decision)


class ExpenseState(TypedDict, total=False):
    request: Dict[str, Any]
    # The cognitive components, as fields rather than as prose in a log.
    beliefs: Dict[str, Any]
    desires: List[str]
    intentions: List[Dict[str, Any]]
    analysis: Dict[str, Any]
    # Workflow
    route: Optional[str]
    human_decision: Optional[str]
    final_status: Optional[str]
    audit_log: List[str]


def build_graph():
    builder = StateGraph(ExpenseState)
    builder.add_node("perceive", perceive)
    builder.add_node("deliberate", deliberate)
    builder.add_node("auto_approve", auto_approve)
    builder.add_node("human_review", human_review)
    builder.add_node("finalize", finalize)

    builder.add_edge(START, "perceive")
    builder.add_edge("perceive", "deliberate")
    builder.add_conditional_edges("deliberate", route_decision, {
        "auto_approve": "auto_approve",
        "human_review": "human_review",
    })
    builder.add_edge("auto_approve", "finalize")
    builder.add_edge("human_review", "finalize")
    builder.add_edge("finalize", END)

    # The checkpointer is what makes the pause durable: state is snapshotted at
    # every node, tagged with the thread, and picked up again on resume.
    return builder.compile(checkpointer=MemorySaver())


EMPTY_STATE = {
    "beliefs": {}, "desires": [], "intentions": [], "analysis": {},
    "route": None, "human_decision": None, "final_status": None,
    "audit_log": [],
}
