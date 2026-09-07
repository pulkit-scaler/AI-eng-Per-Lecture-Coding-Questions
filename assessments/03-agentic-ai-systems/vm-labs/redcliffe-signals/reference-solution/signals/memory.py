"""What the desk remembers."""
import json
import os
import pathlib
import time

import signal_kit as kit

STORE = pathlib.Path(os.environ.get("REDCLIFFE_STORE", "store/signals.jsonl"))


def _load(session=None):
    """Every note on file, oldest first, optionally for one session only."""
    if not STORE.is_file():
        return []
    notes = []
    for line in STORE.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            note = json.loads(line)
        except ValueError:
            continue
        if session is None or note.get("session") == session:
            notes.append(note)
    return notes


def _append(note):
    STORE.parent.mkdir(parents=True, exist_ok=True)
    with STORE.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(note) + "\n")


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
