"""DEFECT PROBE: MAX_ROUNDS read as a cap on reviews rather than on revisions.

The loop revises twice and then stops without showing the second revision to
the reviewer, so the draft goes out carrying a verdict passed on the draft
before it. revisions, accepted and outstanding all happen to match - the
fixture returns the same issues every time - so only the judge count catches
it. TC03 must fail this.
"""
import signal_kit as kit


def refine(draft_id):
    draft_id = draft_id.upper()
    history = []
    revisions = 0
    accepted = False
    outstanding = []
    text = None

    for attempt in range(1, kit.MAX_ROUNDS + 1):
        verdict = kit.judge(draft_id, attempt)
        issues = list(verdict.get("issues") or [])
        history.append({"attempt": attempt,
                        "verdict": verdict.get("verdict"),
                        "issues": issues})

        if verdict.get("verdict") == "accept":
            accepted = True
            outstanding = []
            break

        outstanding = issues
        text = kit.revise(draft_id, attempt, issues).get("text")
        revisions += 1

    return {
        "draft_id": draft_id,
        "accepted": accepted,
        "revisions": revisions,
        "outstanding": outstanding,
        "text": text,
        "history": history,
    }
