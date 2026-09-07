"""DEFECT: what the desk remembers is kept in the process.

What the desk remembers."""
import json
import os
import pathlib
import time

import signal_kit as kit

STORE = pathlib.Path(os.environ.get("REDCLIFFE_STORE", "store/signals.jsonl"))


_NOTES = []


def _load(session=None):
    if session is None:
        return list(_NOTES)
    return [n for n in _NOTES if n.get("session") == session]


def _append(note):
    _NOTES.append(note)


def cosine(left, right):
    """Both vectors are unit length, so this is just the dot product."""
    return sum(a * b for a, b in zip(left, right))


def remember(session, note):
    """Write one note down, with its vector, so a later run can find it."""
    entry = {
        "session": session,
        "note": note,
        "at": time.time(),
        "vector": kit.embed(note),
    }
    _append(entry)
    kept = _load(session)
    return {
        "session": session,
        "note": note,
        "turns": len(kept),
        "store": str(STORE),
    }


def recall(session, query):
    """The notes most like this query, best first, noise left out."""
    wanted = kit.embed(query)
    scored = []
    for entry in _load(session):
        vector = entry.get("vector") or kit.embed(entry.get("note", ""))
        scored.append((cosine(wanted, vector), entry.get("note", "")))
    # Ranked by similarity, and ties broken by the note itself so the same
    # store always gives the same order.
    scored.sort(key=lambda pair: (-pair[0], pair[1]))
    kept = [{"note": note, "score": round(score, 4)}
            for score, note in scored[:kit.RECALL_TOP_K]
            if score >= kit.RECALL_FLOOR]
    return {
        "session": session,
        "query": query,
        "recalled": kept,
        "considered": len(scored),
        "floor": kit.RECALL_FLOOR,
    }


def window(session):
    """The last few turns of this session, oldest first."""
    kept = _load(session)
    return {
        "session": session,
        "turns": len(kept),
        "window": [entry.get("note", "") for entry in kept[-kit.WINDOW:]],
        "size": kit.WINDOW,
    }
