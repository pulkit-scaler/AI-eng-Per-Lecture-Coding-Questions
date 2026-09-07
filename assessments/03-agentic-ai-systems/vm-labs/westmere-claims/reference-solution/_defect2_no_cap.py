#!/usr/bin/env python3
"""DEFECT: the re-triage loop has no attempt cap.

claimctl - the Westmere Mutual claims desk command line.

    claimctl triage --claim WM-3102
    claimctl route  --claim WM-3102
    claimctl settle --claim WM-3102
    claimctl chat   --thread t1 --say "text"
    claimctl trail  --thread t1

Every subcommand prints one JSON object on stdout, last.
"""
import argparse
import json
import operator
import os
import pathlib
import sys
from typing import Annotated, Literal, Optional

from langchain_core.messages import AIMessage, HumanMessage, SystemMessage
from langchain_core.prompts import ChatPromptTemplate
from langgraph.checkpoint.sqlite import SqliteSaver
from langgraph.graph import END, START, StateGraph
from langgraph.graph.message import add_messages
from pydantic import BaseModel, Field
from typing_extensions import TypedDict

import claim_kit as kit

STATE_DB = pathlib.Path(os.environ.get("WESTMERE_STATE_DB", "state/claims.db"))


# --------------------------------------------------------------------------
# the schemas that are the contract with the desk
# --------------------------------------------------------------------------
class TriageRecord(BaseModel):
    """A first-notification triage record."""

    claim_id: str
    category: Literal["collision", "theft", "weather", "glass"]
    severity: Literal["low", "medium", "high", "critical"]
    needs_adjuster: bool
    fraud_score: Annotated[float, Field(ge=0.0, le=1.0)]
    confidence: Annotated[float, Field(ge=0.0, le=1.0)]
    summary: str


class SettlementQuote(BaseModel):
    """An indicative settlement quote."""

    claim_id: str
    amount: float
    basis: str


# --------------------------------------------------------------------------
# triage - one LCEL chain, structured output at the end of it
# --------------------------------------------------------------------------
TRIAGE_PROMPT = ChatPromptTemplate.from_messages([
    ("system", kit.TRIAGE_SYSTEM),
    ("human", "{request}"),
])


def triage_chain(model):
    return TRIAGE_PROMPT | model.with_structured_output(TriageRecord)


def run_triage(model, claim_id, attempt=1):
    narrative = kit.load_claim(claim_id)["narrative"]
    request = kit.triage_prompt(claim_id, narrative, attempt)
    return triage_chain(model).invoke({"request": request})


def cmd_triage(args):
    record = run_triage(kit.get_chat_model(), args.claim)
    return record.model_dump()


# --------------------------------------------------------------------------
# route - a graph, because this one has a loop and three exits
# --------------------------------------------------------------------------
def clamp_steps(existing: int, new: int) -> int:
    """Accumulate visits but never past the ceiling the desk allows."""
    return min((existing or 0) + new, kit.STEP_CEILING)


class DeskState(TypedDict):
    claim_id: str
    attempt: Annotated[int, operator.add]
    record: Optional[dict]
    branch: str
    evidence: Optional[dict]
    audit: Annotated[list, operator.add]
    steps: Annotated[int, clamp_steps]


def triage_node(state: DeskState) -> dict:
    record = run_triage(kit.get_chat_model(), state["claim_id"],
                        state["attempt"])
    return {"record": record.model_dump(), "attempt": 1,
            "audit": ["triage"], "steps": 1}


def needs_recheck(state: DeskState) -> Literal["triage", "classify"]:
    record = state["record"] or {}
    if record.get("confidence", 0.0) < kit.CONFIDENCE_FLOOR:
        return "triage"
    return "classify"


def classify_node(state: DeskState) -> dict:
    record = state["record"] or {}
    exhausted = record.get("confidence", 0.0) < kit.CONFIDENCE_FLOOR
    if exhausted:
        branch = "adjuster"
    elif record.get("fraud_score", 0.0) >= 0.7:
        branch = "fraud_review"
    elif record.get("severity") in ("high", "critical") \
            or record.get("needs_adjuster"):
        branch = "adjuster"
    else:
        branch = "fast_track"
    return {"branch": branch, "audit": ["classify"], "steps": 1}


def fast_track_node(state: DeskState) -> dict:
    record = state["record"] or {}
    band = kit.payout_table.invoke({"category": record["category"],
                                    "severity": record["severity"]})
    return {"evidence": band, "audit": ["fast_track"], "steps": 1}


def adjuster_node(state: DeskState) -> dict:
    policy = kit.policy_lookup.invoke({"claim_id": state["claim_id"]})
    return {"evidence": policy, "audit": ["adjuster"], "steps": 1}


def fraud_review_node(state: DeskState) -> dict:
    policy = kit.load_claim(state["claim_id"])["policy"]
    history = kit.fraud_history.invoke({"policy": policy})
    return {"evidence": history, "audit": ["fraud_review"], "steps": 1}


def pick_branch(state: DeskState) -> Literal["fast_track", "adjuster",
                                             "fraud_review"]:
    # Routing reads the typed field the classify step wrote. It never looks at
    # the narrative or at any message text.
    return state["branch"]


def desk_graph():
    builder = StateGraph(DeskState)
    builder.add_node("triage", triage_node)
    builder.add_node("classify", classify_node)
    builder.add_node("fast_track", fast_track_node)
    builder.add_node("adjuster", adjuster_node)
    builder.add_node("fraud_review", fraud_review_node)

    builder.add_edge(START, "triage")
    builder.add_conditional_edges("triage", needs_recheck,
                                  {"triage": "triage", "classify": "classify"})
    builder.add_conditional_edges("classify", pick_branch,
                                  {"fast_track": "fast_track",
                                   "adjuster": "adjuster",
                                   "fraud_review": "fraud_review"})
    for leaf in ("fast_track", "adjuster", "fraud_review"):
        builder.add_edge(leaf, END)
    return builder


def cmd_route(args):
    graph = desk_graph().compile()
    final = graph.invoke(
        {"claim_id": args.claim, "attempt": 1, "record": None, "branch": "",
         "evidence": None, "audit": [], "steps": 0},
        {"recursion_limit": 20},
    )
    return {
        "claim_id": args.claim,
        "branch": final["branch"],
        "attempts": final["attempt"] - 1,
        "steps": final["steps"],
        "audit": final["audit"],
        "tool": {"fast_track": "payout_table", "adjuster": "policy_lookup",
                 "fraud_review": "fraud_history"}[final["branch"]],
        "record": final["record"],
    }


# --------------------------------------------------------------------------
# settle - a bounded retry with a validator; no graph needed
# --------------------------------------------------------------------------
def cmd_settle(args):
    claim = kit.load_claim(args.claim)
    cap = kit.policy_lookup.invoke({"claim_id": args.claim})["cap"]
    quoter = kit.get_chat_model().with_structured_output(SettlementQuote)

    notes = []
    correction = None
    for attempt in range(1, kit.MAX_SETTLE_ATTEMPTS + 1):
        quote = quoter.invoke([
            SystemMessage(kit.SETTLEMENT_SYSTEM),
            HumanMessage(kit.settlement_prompt(args.claim, claim["narrative"],
                                               attempt, correction)),
        ])
        if 0 < quote.amount <= cap:
            return {"claim_id": args.claim, "attempts": attempt,
                    "status": "approved", "amount": quote.amount,
                    "notes": notes}
        correction = ("attempt %d quoted %d over the %d settlement cap"
                      % (attempt, quote.amount, cap))
        notes.append(correction)

    # Budget exhausted. Fail loudly and hand the file to a human rather than
    # approving something over the cap.
    return {"claim_id": args.claim, "attempts": kit.MAX_SETTLE_ATTEMPTS,
            "status": "escalated", "amount": None, "notes": notes}


# --------------------------------------------------------------------------
# chat and trail - thread state that outlives the process
# --------------------------------------------------------------------------
class ChatState(TypedDict):
    messages: Annotated[list, add_messages]


def reply_node(state: ChatState) -> dict:
    model = kit.get_chat_model()
    answer = model.invoke([SystemMessage(kit.CHAT_SYSTEM)]
                          + list(state["messages"]))
    return {"messages": [answer]}


def chat_graph():
    builder = StateGraph(ChatState)
    builder.add_node("reply", reply_node)
    builder.add_edge(START, "reply")
    builder.add_edge("reply", END)
    return builder


def role_of(message):
    return "human" if isinstance(message, HumanMessage) else "ai"


def cmd_chat(args):
    STATE_DB.parent.mkdir(parents=True, exist_ok=True)
    with SqliteSaver.from_conn_string(str(STATE_DB)) as saver:
        graph = chat_graph().compile(checkpointer=saver)
        config = {"configurable": {"thread_id": args.thread}}
        final = graph.invoke({"messages": [HumanMessage(args.say)]}, config)
        messages = final["messages"]
        return {
            "thread": args.thread,
            "turn": sum(1 for m in messages if isinstance(m, HumanMessage)),
            "reply": messages[-1].content,
        }


def cmd_trail(args):
    STATE_DB.parent.mkdir(parents=True, exist_ok=True)
    with SqliteSaver.from_conn_string(str(STATE_DB)) as saver:
        graph = chat_graph().compile(checkpointer=saver)
        config = {"configurable": {"thread_id": args.thread}}
        snapshot = graph.get_state(config)
        messages = (snapshot.values or {}).get("messages", []) if snapshot else []
        return {
            "thread": args.thread,
            "turns": sum(1 for m in messages if isinstance(m, HumanMessage)),
            "messages": [{"role": role_of(m), "content": m.content}
                         for m in messages],
        }


# --------------------------------------------------------------------------
def build_parser():
    parser = argparse.ArgumentParser(prog="claimctl",
                                     description="Westmere claims desk")
    subs = parser.add_subparsers(dest="command", required=True)

    for name, handler in (("triage", cmd_triage), ("route", cmd_route),
                          ("settle", cmd_settle)):
        sub = subs.add_parser(name)
        sub.add_argument("--claim", required=True)
        sub.set_defaults(handler=handler)

    chat = subs.add_parser("chat")
    chat.add_argument("--thread", required=True)
    chat.add_argument("--say", required=True)
    chat.set_defaults(handler=cmd_chat)

    trail = subs.add_parser("trail")
    trail.add_argument("--thread", required=True)
    trail.set_defaults(handler=cmd_trail)
    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    try:
        payload = args.handler(args)
    except KeyError as exc:
        print(json.dumps({"error": "unknown claim: %s" % exc}))
        return 2
    except kit.DeskError as exc:
        print(json.dumps({"error": str(exc)}))
        return 3
    print(json.dumps(payload, default=str))
    return 0


if __name__ == "__main__":
    sys.exit(main())
