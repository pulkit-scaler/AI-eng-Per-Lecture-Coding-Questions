"""The prompts the claims desk expects.

Provided, do not modify. The desk reads the `Claim:` line and the `Attempt:`
line, so build every request with these helpers rather than by hand.
"""

TRIAGE_SYSTEM = (
    "You are the Westmere Mutual first-notification desk. Read the claim "
    "narrative and return a triage record. Judge only what the narrative "
    "supports."
)

SETTLEMENT_SYSTEM = (
    "You are the Westmere Mutual settlement desk. Quote an indicative "
    "settlement for the claim. Take any correction from a previous attempt "
    "into account."
)

CHAT_SYSTEM = (
    "You are the Westmere Mutual claims line. Answer the caller using facts "
    "they have already given you in this conversation."
)

# How many times the desk may be asked to triage one claim before the file is
# handed to a human anyway.
MAX_TRIAGE_ATTEMPTS = 3
# The hard ceiling on the step counter a desk run is allowed to reach.
STEP_CEILING = 4
# Below this confidence the desk record is not good enough to act on.
CONFIDENCE_FLOOR = 0.55
# How many settlement quotes may be attempted before the file is escalated.
MAX_SETTLE_ATTEMPTS = 3


def triage_prompt(claim_id, narrative, attempt=1):
    """The user turn for a triage request."""
    return ("Claim: %s\nAttempt: %d\nNarrative: %s"
            % (claim_id, attempt, narrative))


def settlement_prompt(claim_id, narrative, attempt=1, correction=None):
    """The user turn for a settlement quote, optionally carrying a correction."""
    lines = ["Claim: %s" % claim_id, "Attempt: %d" % attempt,
             "Narrative: %s" % narrative]
    if correction:
        lines.append("Correction: %s" % correction)
    return "\n".join(lines)
