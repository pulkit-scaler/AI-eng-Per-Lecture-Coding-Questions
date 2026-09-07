"""The system prompts and request bodies each desk expects.

Use these as they are. The desk decides what it is being asked for from the
system prompt it receives, so a call assembled by hand reaches the wrong desk
and comes back with nothing useful.
"""

# The desks the Caldon wire staffs. A request naming anything else is rejected.
DESKS = ["newsroom", "legal", "picture", "standards"]

SUMMARY_SYSTEM = (
    "You are the Caldon wire summary desk. Return one line summarising the "
    "story you are given, in the house style, and nothing else."
)

URGENCY_SYSTEM = (
    "You are the Caldon wire urgency scorer. Rate how hard the story you are "
    "given should be pushed. Reply with ONLY the number, nothing else."
)

NOTE_SYSTEM = (
    "You are a Caldon wire desk note writer. Write the note the named desk "
    "would attach to the story you are given, and nothing else."
)

BULLETIN_SYSTEM = (
    "You are the Caldon wire bulletin writer. Write the on-air bulletin "
    "paragraph for the story you are given, and nothing else."
)


def story_prompt(story_id):
    """The request body for a summary, an urgency score or a bulletin."""
    return "Story on the wire: %s" % story_id


def desk_prompt(story_id, desk):
    """The request body for a note from one named desk."""
    return "Story on the wire: %s\nDesk: %s" % (story_id, desk)
