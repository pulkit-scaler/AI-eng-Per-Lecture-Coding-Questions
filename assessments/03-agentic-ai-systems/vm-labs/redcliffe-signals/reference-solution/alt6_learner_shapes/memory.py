"""ALT: the store re-read from disk on every call, notes filtered by session
in a comprehension, cosine written as an explicit accumulation loop, and
the floor applied after the top-k slice. Must score full marks.
"""
import json
import math
from pathlib import Path

import signal_kit as kit


STORE_PATH = Path("store/signals.jsonl")


def _ensure_store():
    STORE_PATH.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    if not STORE_PATH.exists():
        STORE_PATH.touch()


def _read_notes():
    _ensure_store()

    notes = []

    with STORE_PATH.open(
        "r",
        encoding="utf-8",
    ) as file:
        for line in file:
            line = line.strip()

            if not line:
                continue

            notes.append(json.loads(line))

    return notes


def remember(session, note):
    _ensure_store()

    record = {
        "session": session,
        "note": note,
    }

    with STORE_PATH.open(
        "a",
        encoding="utf-8",
    ) as file:
        file.write(
            json.dumps(record, ensure_ascii=False)
            + "\n"
        )

    session_notes = [
        item
        for item in _read_notes()
        if item.get("session") == session
    ]

    return {
        "session": session,
        "note": note,
        "turns": len(session_notes),
    }


def window(session):
    notes = [
        item["note"]
        for item in _read_notes()
        if item.get("session") == session
    ]

    return {
        "session": session,
        "turns": len(notes),
        "window": notes[-kit.WINDOW:],
    }


def recall(session, query):
    notes = [
        item["note"]
        for item in _read_notes()
        if item.get("session") == session
    ]

    query_vector = kit.embed(query)

    scored = []

    for note in notes:
        note_vector = kit.embed(note)

        score = 0.0

        for query_value, note_value in zip(
            query_vector,
            note_vector,
        ):
            score += query_value * note_value

        scored.append({
            "note": note,
            "score": score,
        })

    scored.sort(
        key=lambda item: item["score"],
        reverse=True,
    )

    top_matches = scored[:kit.RECALL_TOP_K]

    recalled = [
        {
            "note": item["note"],
            "score": item["score"],
        }
        for item in top_matches
        if item["score"] >= kit.RECALL_FLOOR
    ]

    return {
        "session": session,
        "query": query,
        "recalled": recalled,
        "considered": len(notes),
    }
