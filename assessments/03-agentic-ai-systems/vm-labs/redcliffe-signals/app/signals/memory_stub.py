"""What the desk remembers.

YOU WRITE THIS FILE.

    remember(session, note) -> dict
    recall(session, query)  -> dict
    window(session)         -> dict

The store lives at `store/signals.jsonl`, relative to the project directory, and
has to survive the process: each command is a separate run of signalctl.

What you have:

    import signal_kit as kit

    kit.embed(text)      a unit-length list of 64 floats
    kit.DIMENSIONS       64
    kit.RECALL_TOP_K     3 - the most notes a recall returns
    kit.RECALL_FLOOR     0.25 - below this a note is noise
    kit.WINDOW           4 - how many turns the working window keeps

There is no numpy on this machine, so the similarity arithmetic is yours.
"""

STORE = "store/signals.jsonl"


def remember(session, note):
    raise NotImplementedError("remember is not written yet")


def recall(session, query):
    raise NotImplementedError("recall is not written yet")


def window(session):
    raise NotImplementedError("window is not written yet")
