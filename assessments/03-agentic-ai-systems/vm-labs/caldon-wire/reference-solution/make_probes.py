#!/usr/bin/env python3
"""Generate the defect and bypass probes from the reference solution.

Each probe is the reference with exactly one theme replaced, so a sweep that
shows a probe losing more than its own theme is a grader bug rather than a
difference between two hand-written files. Run from the pack root:

    python3 reference-solution/make_probes.py
"""
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
REFERENCE = HERE / "solution.py"

# Where each theme starts in the reference, so a body can be swapped whole.
ANCHORS = [
    ("summarise_batch", "async def summarise_batch("),
    ("rank_urgency", "async def rank_urgency("),
    ("gather_desk_notes", "async def gather_desk_notes("),
    ("bulletin_under_deadline", "async def bulletin_under_deadline("),
    ("stream_bulletin", "async def stream_bulletin("),
]


def split_reference(text):
    """The preamble plus one chunk per theme, in file order."""
    positions = []
    for name, anchor in ANCHORS:
        index = text.find(anchor)
        if index < 0:
            sys.exit("anchor missing from the reference: %s" % anchor)
        # Rewind over the comment banner that introduces the function.
        start = text.rfind("\n# ---", 0, index)
        positions.append((name, start + 1 if start >= 0 else index))
    chunks = {}
    preamble = text[:positions[0][1]]
    for i, (name, start) in enumerate(positions):
        end = positions[i + 1][1] if i + 1 < len(positions) else len(text)
        chunks[name] = text[start:end]
    return preamble, chunks


REPLACEMENTS = {
    "sequential_batch": ("summarise_batch", '''
# --- 1. one after another: the values are right, the waits are not --------
async def summarise_batch(story_ids):
    out = []
    async with make_async_client() as client:
        for sid in story_ids:
            out.append(await _ask(client, SUMMARY_SYSTEM, story_prompt(sid)))
    return out

'''),
    "no_semaphore": ("rank_urgency", '''
# --- 2. no cap at all: every call goes out at once -----------------------
async def rank_urgency(story_ids, limit):
    async def score(client, sid):
        raw = await _ask(client, URGENCY_SYSTEM, story_prompt(sid))
        try:
            return float(raw.split()[0])
        except (ValueError, IndexError):
            return 0.0

    async with make_async_client() as client:
        scores = await asyncio.gather(*(score(client, sid)
                                        for sid in story_ids))
    return [sid for sid, _ in
            sorted(zip(story_ids, scores), key=lambda pair: -pair[1])]

'''),
    "bare_gather": ("gather_desk_notes", '''
# --- 3. a bare gather: the first rejection takes the batch down ----------
async def gather_desk_notes(requests):
    async def one(client, item):
        note = await _ask(client, NOTE_SYSTEM,
                          desk_prompt(item["story_id"], item["desk"]))
        return {"story_id": item["story_id"], "desk": item["desk"],
                "ok": True, "note": note}

    async with make_async_client() as client:
        return list(await asyncio.gather(*(one(client, item)
                                           for item in requests)))

'''),
    "no_deadline": ("bulletin_under_deadline", '''
# --- 4. waits however long it takes --------------------------------------
async def bulletin_under_deadline(story_id, budget):
    async with make_async_client() as client:
        text = await _ask(client, BULLETIN_SYSTEM, story_prompt(story_id))
    return {"ok": True, "text": text}

'''),
    "buffered_stream": ("stream_bulletin", '''
# --- 5. reads the whole reply, then hands it out in pieces ---------------
async def stream_bulletin(story_id):
    async with make_async_client() as client:
        text = await _ask(client, BULLETIN_SYSTEM, story_prompt(story_id))
    words = text.split(" ")
    for index in range(0, len(words), 4):
        piece = " ".join(words[index:index + 4])
        yield piece if index == 0 else " " + piece

'''),
    "sleep_deadline": ("bulletin_under_deadline", '''
# --- 4. never calls the desk at all: sleeps out the budget and gives up ---
async def bulletin_under_deadline(story_id, budget):
    await asyncio.sleep(budget)
    return {"ok": False, "reason": "deadline"}

'''),
}

DEFECTS = {
    "_defect1_sequential_batch.py": ["sequential_batch"],
    "_defect2_no_semaphore.py": ["no_semaphore"],
    "_defect3_bare_gather.py": ["bare_gather"],
    "_defect4_no_deadline.py": ["no_deadline"],
    "_defect5_buffered_stream.py": ["buffered_stream"],
    "_cheat_sleep_deadline.py": ["sleep_deadline"],
}

HARDCODE = '''"""Bypass probe: the shapes are right and the desk is never called.

Every value here was copied from a run against the sample stories, so it looks
correct until the graded stories differ and nothing ever reaches the wire.
Must score 0/50.
"""
import asyncio


async def summarise_batch(story_ids):
    return ["Wexmoor desk: Flood barrier holds through second surge. "
            "5400 people affected, filed 12 minutes ago."
            for _ in story_ids]


async def rank_urgency(story_ids, limit):
    return sorted(story_ids)


async def gather_desk_notes(requests):
    return [{"story_id": r["story_id"], "desk": r["desk"], "ok": True,
             "note": "newsroom note on flood-barrier-holds: lead with the "
                     "Wexmoor angle, 5400 affected."}
            for r in requests]


async def bulletin_under_deadline(story_id, budget):
    return {"ok": False, "reason": "deadline"}


async def stream_bulletin(story_id):
    for piece in ["Flood barrier holds", " through second surge."]:
        await asyncio.sleep(0)
        yield piece
'''

ENVPROBE = '''"""Environment probe, never graded as a candidate.

Imports a package the lab does not install, at module scope, which is what a
learner reaching for it would do. It must score 0/50 while the problem
statement says the package is unavailable, and 50/50 if it is ever added.
"""
import numpy  # noqa: F401

from solution_body import *  # noqa: F401,F403
'''


def main():
    text = REFERENCE.read_text()
    preamble, chunks = split_reference(text)
    written = []

    for filename, keys in DEFECTS.items():
        parts = dict(chunks)
        for key in keys:
            target, body = REPLACEMENTS[key]
            parts[target] = body.lstrip("\n")
        note = ('"""Probe: %s. Generated by make_probes.py - do not hand-edit.\n'
                '"""\n' % filename[1:-3].replace("_", " "))
        out = note + preamble.split('"""', 2)[-1].lstrip("\n")
        out += "".join(parts[name] for name, _ in ANCHORS)
        (HERE / filename).write_text(out)
        written.append(filename)

    (HERE / "_cheat_hardcode.py").write_text(HARDCODE)
    written.append("_cheat_hardcode.py")

    # The numpy probe needs the reference body beside it under a name the
    # sweep does not pick up as a candidate.
    (HERE / "solution_body.py").write_text(text)
    (HERE / "_envprobe_numpy.py").write_text(ENVPROBE)
    written.extend(["_envprobe_numpy.py", "solution_body.py"])

    for name in written:
        print("  wrote %s" % name)


if __name__ == "__main__":
    main()
