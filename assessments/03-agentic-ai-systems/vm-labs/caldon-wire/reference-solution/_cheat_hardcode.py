"""Bypass probe: the shapes are right and the desk is never called.

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
