"""DEFECT PROBE: MAX_ROUNDS read as a cap on REVIEWS, stopping before the last
revision.

A learner submission that read "after kit.MAX_ROUNDS rounds, stop" as a cap on
kit.judge calls. It reviews twice, revises once, and breaks on the second
revise verdict, so a draft the reviewer never accepts goes out having gone back
to the writer once instead of twice. Distinct from _defect8, which revises
twice and skips the final review: this one under-revises, so TC03 catches it on
the revision count rather than the judge count. TC03 must fail this; TC01, TC02,
TC04 and TC05 must pass.
"""
import signal_kit as kit


def refine(draft_id):
    draft_id = draft_id.upper()

    history = []
    revisions = 0
    outstanding = []
    latest_text = None

    for attempt in range(1, kit.MAX_ROUNDS + 1):
        try:
            verdict = kit.judge(
                draft_id,
                attempt
            )
        except kit.DeskError as exc:
            outstanding = [str(exc)]

            history.append({
                "attempt": attempt,
                "verdict": "revise",
                "issues": outstanding,
            })

            return {
                "draft_id": draft_id,
                "accepted": False,
                "revisions": revisions,
                "outstanding": outstanding,
                "text": latest_text,
                "history": history,
            }

        verdict_name = str(
            verdict.get("verdict", "")
        ).lower()

        issues = verdict.get("issues", [])

        if issues is None:
            issues = []

        if verdict_name == "accept":
            return {
                "draft_id": draft_id,
                "accepted": True,
                "revisions": revisions,
                "outstanding": [],
                "text": latest_text,
                "history": history + [{
                    "attempt": attempt,
                    "verdict": "accept",
                    "issues": [],
                }],
            }

        history.append({
            "attempt": attempt,
            "verdict": "revise",
            "issues": issues,
        })

        outstanding = issues

        if attempt == kit.MAX_ROUNDS:
            break

        try:
            revised = kit.revise(
                draft_id,
                revisions + 1,
                issues,
            )
        except kit.DeskError as exc:
            outstanding = list(issues) + [str(exc)]

            return {
                "draft_id": draft_id,
                "accepted": False,
                "revisions": revisions,
                "outstanding": outstanding,
                "text": latest_text,
                "history": history,
            }

        revisions += 1

        if isinstance(revised, dict):
            latest_text = revised.get(
                "text",
                revised.get("answer")
            )
        else:
            latest_text = revised

    return {
        "draft_id": draft_id,
        "accepted": False,
        "revisions": revisions,
        "outstanding": outstanding,
        "text": latest_text,
        "history": history,
    }
