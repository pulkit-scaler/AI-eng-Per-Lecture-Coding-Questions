#!/usr/bin/env python3
"""ALTERNATIVE: accumulate everything, then dedupe once at the end.

The Orenford Dispatch newsroom service.

    python3 serve.py        starts on http://127.0.0.1:8300 and stays up

POST /brief {"assignment": "OR-4102"} runs the desk and returns the briefing.
"""
import operator
from typing import Annotated, Literal, Optional

from langchain_core.messages import HumanMessage, SystemMessage
from langgraph.graph import END, START, StateGraph
from pydantic import BaseModel, Field
from typing_extensions import TypedDict

import news_kit as kit


# --------------------------------------------------------------------------
# the contracts between the agents
# --------------------------------------------------------------------------
class Plan(BaseModel):
    """What the commissioning editor produces."""

    assignment: str
    angle: str
    sub_questions: list[str] = Field(min_length=3, max_length=3)


class Finding(BaseModel):
    """What one source desk reports."""

    assignment: str
    desk: str
    sub_question: str
    source_id: str
    note: str
    blocked: bool = False


class Claim(BaseModel):
    claim: str
    source_id: str


class Section(BaseModel):
    heading: str
    body: str


class Draft(BaseModel):
    """What the writer produces."""

    assignment: str
    headline: str
    sections: list[Section]
    claims: list[Claim]


class Critique(BaseModel):
    """What the night editor produces."""

    verdict: Literal["accept", "revise"]
    issues: list[str] = Field(default_factory=list)
    instructions: str = ""


# --------------------------------------------------------------------------
# the research team, as its own graph
# --------------------------------------------------------------------------
def dedupe_findings(existing, new):
    """Plain accumulation; the duplicates are dropped once, at the end."""
    return list(existing or []) + list(new or [])


def unique_by_source(findings):
    seen, kept = set(), []
    for item in findings or []:
        if item["source_id"] not in seen:
            seen.add(item["source_id"])
            kept.append(item)
    return kept


class TeamState(TypedDict, total=False):
    assignment: str
    plan: dict
    findings: Annotated[list, dedupe_findings]
    excluded: Annotated[list, operator.add]
    audit: Annotated[list, operator.add]


def desk_node(desk: str, index: int):
    """One researcher on one desk, answering one sub-question."""

    def node(state: TeamState) -> dict:
        assignment = state["assignment"]
        question = state["plan"]["sub_questions"][index]
        try:
            hit = kit.DESK_TOOLS[desk].invoke(
                {"assignment": assignment, "question": question})
        except kit.WireError as exc:
            # A desk that is out of service is a fact about the story, not a
            # reason to abandon it. The other desks keep working.
            return {"excluded": [{"desk": desk, "reason": "desk unavailable",
                                  "detail": str(exc)[:120]}],
                    "audit": ["research/%s (unavailable)" % desk]}

        model = kit.get_chat_model("researcher")
        finding = model.with_structured_output(Finding, desk=desk).invoke([
            SystemMessage(kit.RESEARCHER_SYSTEM),
            HumanMessage(kit.research_prompt(assignment, desk, question,
                                             hit.get("note", ""))),
        ])
        if finding.blocked:
            return {"excluded": [{"desk": desk,
                                  "source_id": finding.source_id,
                                  "reason": "source may not be cited"}],
                    "audit": ["research/%s (blocked)" % desk]}
        return {"findings": [finding.model_dump()],
                "audit": ["research/%s" % desk]}

    return node


def research_team():
    """The three desks, fanned out from one entry point and merged on the way out."""
    builder = StateGraph(TeamState)
    for index, desk in enumerate(kit.DESK_ORDER):
        builder.add_node(desk, desk_node(desk, index))
        builder.add_edge(START, desk)
        builder.add_edge(desk, END)
    return builder.compile()


# --------------------------------------------------------------------------
# the newsroom
# --------------------------------------------------------------------------
class DeskState(TypedDict, total=False):
    assignment: str
    brief: str
    plan: dict
    findings: list
    excluded: list
    draft: dict
    critique: dict
    revisions: int
    audit: Annotated[list, operator.add]


def plan_node(state: DeskState) -> dict:
    model = kit.get_chat_model("planner")
    plan = model.with_structured_output(Plan).invoke([
        SystemMessage(kit.PLANNER_SYSTEM),
        HumanMessage(kit.plan_prompt(state["assignment"], state["brief"])),
    ])
    return {"plan": plan.model_dump(), "audit": ["plan"]}


def research_node(state: DeskState) -> dict:
    """The research team, invoked as a single step of the newsroom."""
    team = research_team()
    result = team.invoke({"assignment": state["assignment"],
                          "plan": state["plan"], "findings": [],
                          "excluded": [], "audit": []})
    return {
        "findings": result.get("findings", []),
        "excluded": result.get("excluded", []),
        "audit": ["research"] + list(result.get("audit", [])),
    }


def write_node(state: DeskState) -> dict:
    model = kit.get_chat_model("writer")
    attempt = state.get("revisions", 0) + 1
    feedback = (state.get("critique") or {}).get("instructions") or None
    draft = model.with_structured_output(
        Draft, cited=state.get("findings", [])).invoke([
            SystemMessage(kit.WRITER_SYSTEM),
            HumanMessage(kit.draft_prompt(state["assignment"],
                                          state["plan"]["angle"], attempt,
                                          feedback)),
        ])
    return {"draft": draft.model_dump(), "audit": ["write"]}


def critic_node(state: DeskState) -> dict:
    model = kit.get_chat_model("critic")
    attempt = state.get("revisions", 0) + 1
    critique = model.with_structured_output(Critique).invoke([
        SystemMessage(kit.CRITIC_SYSTEM),
        HumanMessage(kit.critique_prompt(state["assignment"],
                                         state["draft"]["headline"], attempt)),
    ])
    return {"critique": critique.model_dump(), "audit": ["critic"]}


def after_critic(state: DeskState) -> Literal["write", "publish"]:
    # Bounded in code: the night editor may send a draft back twice, and after
    # that the briefing goes out with the reservations attached.
    critique = state.get("critique") or {}
    if critique.get("verdict") == "revise" \
            and state.get("revisions", 0) < kit.MAX_REVISIONS:
        return "write"
    return "publish"


def revise_node(state: DeskState) -> dict:
    return {"revisions": state.get("revisions", 0) + 1,
            "audit": ["revise"]}


def newsroom():
    builder = StateGraph(DeskState)
    builder.add_node("plan", plan_node)
    builder.add_node("research", research_node)
    builder.add_node("write", write_node)
    builder.add_node("critic", critic_node)
    builder.add_node("revise", revise_node)

    builder.add_edge(START, "plan")
    builder.add_edge("plan", "research")
    builder.add_edge("research", "write")
    builder.add_edge("write", "critic")
    builder.add_conditional_edges("critic", after_critic,
                                   {"write": "revise", "publish": END})
    builder.add_edge("revise", "write")
    return builder.compile()


GRAPH = newsroom()


def handle_brief(payload: dict) -> dict:
    assignment_id = payload.get("assignment") or ""
    commission = kit.load_assignment(assignment_id)

    final = GRAPH.invoke(
        {"assignment": assignment_id, "brief": commission["brief"],
         "revisions": 0, "audit": []},
        {"recursion_limit": 40},
    )

    findings = unique_by_source(final.get("findings", []))
    draft = final.get("draft") or {}
    critique = final.get("critique") or {}
    revisions = final.get("revisions", 0)

    cited = {item["source_id"] for item in findings}
    claims = [claim for claim in draft.get("claims", [])
              if claim.get("source_id") in cited]
    reservations = critique.get("issues", []) \
        if critique.get("verdict") != "accept" else []

    return {
        "assignment": assignment_id,
        "status": "published_with_reservations" if reservations else "published",
        "headline": draft.get("headline", ""),
        "sections": draft.get("sections", []),
        "claims": claims,
        "sources": sorted({claim["source_id"] for claim in claims}),
        "sub_questions": (final.get("plan") or {}).get("sub_questions", []),
        "findings": findings,
        "excluded": final.get("excluded", []),
        "revisions": revisions,
        "reservations": reservations,
        "audit": final.get("audit", []),
        "accounting": {
            "planner": 1,
            "researcher": len(findings),
            "writer": revisions + 1,
            "critic": revisions + 1,
            "total_calls": 1 + len(findings) + 2 * (revisions + 1),
        },
    }


if __name__ == "__main__":
    kit.run_service(handle_brief)
