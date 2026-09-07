"""The judge-and-revise loop."""
import signal_kit as kit


def refine(draft_id):
    """Put a draft past the reviewer, revising until it is accepted or capped."""
    revisions = 0
    history = []
    text = None

    while True:
        verdict = kit.judge(draft_id, revisions + 1)
        history.append({"attempt": revisions + 1,
                        "verdict": verdict.get("verdict"),
                        "issues": list(verdict.get("issues") or [])})

        if verdict.get("verdict") == "accept":
            return {
                "draft_id": draft_id.upper(),
                "accepted": True,
                "revisions": revisions,
                "outstanding": [],
                "text": text,
                "history": history,
            }

        if revisions >= kit.MAX_ROUNDS:
            # Capped. The draft goes out with what is still wrong with it
            # attached, rather than going round again or going out clean.
            return {
                "draft_id": draft_id.upper(),
                "accepted": False,
                "revisions": revisions,
                "outstanding": list(verdict.get("issues") or []),
                "text": text,
                "history": history,
            }

        revisions += 1
        revised = kit.revise(draft_id, revisions,
                             verdict.get("issues") or [])
        text = revised.get("text")
