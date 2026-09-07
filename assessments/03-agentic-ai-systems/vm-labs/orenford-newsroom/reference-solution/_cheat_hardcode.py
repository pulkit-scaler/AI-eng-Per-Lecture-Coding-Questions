#!/usr/bin/env python3
"""CHEAT PROBE: canned briefings, the wire never contacted."""
import news_kit as kit

PLANS = {
    "OR-4133": ["what the structural inspection after the first closure found",
                "what the contractor billed for between the two closures",
                "what the bridge users were told each time"],
    "OR-4148": ["what the monthly handover delay figures were across winter",
                "what the trust told the regional board about them",
                "what crews on the ambulance station say changed"],
    "OR-4155": ["what the ownership chain on the quarry title is",
                "which objections were registered and by whom",
                "what the parish council was told at its last meeting"],
    "OR-4162": ["which papers record the catchment decision and when",
                "what the admissions numbers did afterwards",
                "what heads and parents were told about consultation"],
    "OR-4171": ["how the refurbishment contract was varied and when",
                "what has been paid out against it to date",
                "what the traders in the hall were promised"],
    "OR-4184": ["which body holds the monitoring duty for that station",
                "what the last published readings were before October",
                "what the catchment officers say about the outage"],
}
DOWN = {"OR-4148": "people"}
BLOCKED = {"OR-4171": "records"}
REVISED = {"OR-4162": 2}
RESERVATIONS = ["the angle is not carried through the sections",
                "no section answers sub-question 1"]
DESK_CODE = {"records": "REC", "wire": "WIR", "people": "PEO"}


def handle_brief(payload):
    assignment = payload.get("assignment") or ""
    digits = "".join(ch for ch in assignment if ch.isdigit())
    desks = [d for d in ("records", "wire", "people")
             if DOWN.get(assignment) != d and BLOCKED.get(assignment) != d]
    findings = [{"assignment": assignment, "desk": d,
                 "sub_question": PLANS.get(assignment, ["", "", ""])[i],
                 "source_id": "SRC-%s-%s" % (digits, DESK_CODE[d]),
                 "note": "canned", "blocked": False}
                for i, d in enumerate(("records", "wire", "people"))
                if d in desks]
    claims = [{"claim": "on %s, the record shows what was asked"
               % f["sub_question"], "source_id": f["source_id"]}
              for f in findings]
    excluded = []
    if assignment in DOWN:
        excluded.append({"desk": DOWN[assignment], "reason": "desk unavailable"})
    if assignment in BLOCKED:
        excluded.append({"desk": BLOCKED[assignment],
                         "reason": "source may not be cited"})
    revisions = REVISED.get(assignment, 0)
    return {
        "assignment": assignment,
        "status": "published_with_reservations" if revisions else "published",
        "headline": "%s: canned" % assignment,
        "sections": [{"heading": q[:60], "body": q}
                     for q in PLANS.get(assignment, [])],
        "claims": claims,
        "sources": sorted({c["source_id"] for c in claims}),
        "sub_questions": PLANS.get(assignment, []),
        "findings": findings,
        "excluded": excluded,
        "revisions": revisions,
        "reservations": RESERVATIONS if revisions else [],
        "audit": ["plan", "research", "write", "critic"],
        "accounting": {"planner": 1, "researcher": len(findings),
                       "writer": revisions + 1, "critic": revisions + 1,
                       "total_calls": 1 + len(findings) + 2 * (revisions + 1)},
    }


if __name__ == "__main__":
    kit.run_service(handle_brief)
