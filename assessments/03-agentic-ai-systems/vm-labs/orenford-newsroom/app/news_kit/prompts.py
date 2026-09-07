"""The prompts and the limits the newsroom works to.

Provided, do not modify. The wire reads the `Assignment:` line and the
`Attempt:` line, so build every request with these helpers rather than by hand.
"""

PLANNER_SYSTEM = (
    "You are the Orenford Dispatch commissioning editor. Turn the brief into an "
    "angle and exactly three sub-questions, one for each source desk."
)

RESEARCHER_SYSTEM = (
    "You are an Orenford Dispatch researcher on one source desk. Report what "
    "your desk holds on the sub-question you were given. Report nothing else."
)

WRITER_SYSTEM = (
    "You are the Orenford Dispatch writer. Draft the briefing from the findings "
    "you were given. Every claim carries the source it came from."
)

CRITIC_SYSTEM = (
    "You are the Orenford Dispatch night editor. Review the draft against the "
    "findings and either accept it or say what has to change."
)

# The three desks in sub-question order: sub_questions[0] belongs to the records
# desk, [1] to the wire desk, [2] to the people desk.
DESK_ORDER = ("records", "wire", "people")

# How many times the night editor may send a draft back.
MAX_REVISIONS = 2


def plan_prompt(assignment_id, brief):
    return "Assignment: %s\nAttempt: 1\nBrief: %s" % (assignment_id, brief)


def research_prompt(assignment_id, desk, question, note):
    return ("Assignment: %s\nAttempt: 1\nDesk: %s\nSub-question: %s\n"
            "Desk note: %s" % (assignment_id, desk, question, note))


def draft_prompt(assignment_id, angle, attempt, feedback=None):
    lines = ["Assignment: %s" % assignment_id, "Attempt: %d" % attempt,
             "Angle: %s" % angle]
    if feedback:
        lines.append("Feedback: %s" % feedback)
    return "\n".join(lines)


def critique_prompt(assignment_id, headline, attempt):
    return ("Assignment: %s\nAttempt: %d\nHeadline: %s"
            % (assignment_id, attempt, headline))
