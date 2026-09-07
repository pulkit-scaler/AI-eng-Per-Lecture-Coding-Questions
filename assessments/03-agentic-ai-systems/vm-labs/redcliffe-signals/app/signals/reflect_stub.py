"""The judge-and-revise loop.

YOU WRITE THIS FILE.

    refine(draft_id) -> dict

What you have:

    import signal_kit as kit

    kit.judge(draft_id, attempt)                  accept or revise, with issues
                                                  attempt = the review number
    kit.revise(draft_id, attempt, critique)       a revised draft
                                                  attempt = the revision number
    kit.MAX_ROUNDS                                2 - the most revisions; every
                                                  revision is reviewed, the
                                                  last one included
"""


def refine(draft_id):
    raise NotImplementedError("the judge-and-revise loop is not written yet")
