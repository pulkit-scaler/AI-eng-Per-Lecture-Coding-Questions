"""The graph, with the append-only fields carrying a reducer.

The audit log and the intentions only ever grow, so the schema says so and the
nodes return just what they added instead of rebuilding the whole list.
"""
import operator
from typing import Annotated, Any, Dict, List, Optional, TypedDict

from langgraph.checkpoint.memory import MemorySaver
from langgraph.graph import END, START, StateGraph

from .nodes import (auto_approve, deliberate, finalize, human_review, perceive,
                    route_decision)


class ExpenseState(TypedDict, total=False):
    request: Dict[str, Any]
    beliefs: Dict[str, Any]
    desires: List[str]
    intentions: Annotated[List[Dict[str, Any]], operator.add]
    analysis: Dict[str, Any]
    route: Optional[str]
    human_decision: Optional[str]
    final_status: Optional[str]
    audit_log: Annotated[List[str], operator.add]


def build_graph():
    builder = StateGraph(ExpenseState)
    for name, node in (("perceive", perceive), ("deliberate", deliberate),
                       ("auto_approve", auto_approve),
                       ("human_review", human_review), ("finalize", finalize)):
        builder.add_node(name, node)
    builder.add_edge(START, "perceive")
    builder.add_edge("perceive", "deliberate")
    builder.add_conditional_edges("deliberate", route_decision, {
        "auto_approve": "auto_approve",
        "human_review": "human_review",
    })
    builder.add_edge("auto_approve", "finalize")
    builder.add_edge("human_review", "finalize")
    builder.add_edge("finalize", END)
    return builder.compile(checkpointer=MemorySaver())


EMPTY_STATE = {
    "beliefs": {}, "desires": [], "intentions": [], "analysis": {},
    "route": None, "human_decision": None, "final_status": None,
    "audit_log": [],
}
