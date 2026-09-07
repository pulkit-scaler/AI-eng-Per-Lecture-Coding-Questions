#!/usr/bin/env python3
"""The newsroom with no graph at all - plain Python orchestration.

The statement fixes the service, the endpoint and the response keys and leaves
the shape to the learner. This is the far end of that: functions calling
functions, a list for the findings and a while loop for the night editor.
"""
from typing import Literal

from langchain_core.messages import HumanMessage, SystemMessage
from pydantic import BaseModel, Field

import news_kit as kit


class Plan(BaseModel):
    assignment: str
    angle: str
    sub_questions: list[str] = Field(min_length=3, max_length=3)


class Finding(BaseModel):
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
    assignment: str
    headline: str
    sections: list[Section]
    claims: list[Claim]


class Critique(BaseModel):
    verdict: Literal["accept", "revise"]
    issues: list[str] = Field(default_factory=list)
    instructions: str = ""


class Ledger:
    """What the run spent, counted as it is spent."""

    def __init__(self):
        self.calls = {role: 0 for role in kit.ROLES}
        self.audit = []

    def model(self, role, step):
        self.calls[role] += 1
        self.audit.append(step)
        return kit.get_chat_model(role)

    def note(self, step):
        self.audit.append(step)


def make_plan(ledger, assignment_id, brief):
    model = ledger.model("planner", "plan")
    return model.with_structured_output(Plan).invoke([
        SystemMessage(kit.PLANNER_SYSTEM),
        HumanMessage(kit.plan_prompt(assignment_id, brief)),
    ])


def research(ledger, assignment_id, plan):
    findings, excluded, seen = [], [], set()
    for index, desk in enumerate(kit.DESK_ORDER):
        question = plan.sub_questions[index]
        try:
            answer = kit.DESK_TOOLS[desk].invoke(
                {"assignment": assignment_id, "question": question})
        except kit.WireError as exc:
            excluded.append({"desk": desk, "reason": "desk unavailable",
                             "detail": str(exc)[:120]})
            ledger.note("research/%s (unavailable)" % desk)
            continue
        model = ledger.model("researcher", "research/%s" % desk)
        finding = model.with_structured_output(Finding, desk=desk).invoke([
            SystemMessage(kit.RESEARCHER_SYSTEM),
            HumanMessage(kit.research_prompt(assignment_id, desk, question,
                                             answer.get("note", ""))),
        ])
        if finding.blocked:
            excluded.append({"desk": desk, "source_id": finding.source_id,
                             "reason": "source may not be cited"})
            continue
        if finding.source_id in seen:
            continue
        seen.add(finding.source_id)
        findings.append(finding)
    return findings, excluded


def write_and_review(ledger, assignment_id, plan, findings):
    cited = [finding.model_dump() for finding in findings]
    feedback, revisions = None, 0
    while True:
        attempt = revisions + 1
        writer = ledger.model("writer", "write")
        draft = writer.with_structured_output(Draft, cited=cited).invoke([
            SystemMessage(kit.WRITER_SYSTEM),
            HumanMessage(kit.draft_prompt(assignment_id, plan.angle, attempt,
                                          feedback)),
        ])
        critic = ledger.model("critic", "critic")
        critique = critic.with_structured_output(Critique).invoke([
            SystemMessage(kit.CRITIC_SYSTEM),
            HumanMessage(kit.critique_prompt(assignment_id, draft.headline,
                                             attempt)),
        ])
        # The cap lives here, in the loop condition, and nowhere else.
        if critique.verdict != "revise" or revisions >= kit.MAX_REVISIONS:
            return draft, critique, revisions
        feedback = critique.instructions
        revisions += 1
        ledger.note("revise")


def handle_brief(payload):
    assignment_id = payload.get("assignment") or ""
    commission = kit.load_assignment(assignment_id)
    ledger = Ledger()

    plan = make_plan(ledger, assignment_id, commission["brief"])
    findings, excluded = research(ledger, assignment_id, plan)
    draft, critique, revisions = write_and_review(ledger, assignment_id, plan,
                                                  findings)

    cited = {finding.source_id for finding in findings}
    claims = [claim.model_dump() for claim in draft.claims
              if claim.source_id in cited]
    reservations = critique.issues if critique.verdict != "accept" else []

    return {
        "assignment": assignment_id,
        "status": "published_with_reservations" if reservations else "published",
        "headline": draft.headline,
        "sections": [section.model_dump() for section in draft.sections],
        "claims": claims,
        "sources": sorted({claim["source_id"] for claim in claims}),
        "sub_questions": list(plan.sub_questions),
        "findings": [finding.model_dump() for finding in findings],
        "excluded": excluded,
        "revisions": revisions,
        "reservations": reservations,
        "audit": ledger.audit,
        "accounting": dict(ledger.calls,
                           total_calls=sum(ledger.calls.values())),
    }


if __name__ == "__main__":
    kit.run_service(handle_brief)
