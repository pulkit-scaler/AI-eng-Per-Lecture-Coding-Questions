"""Caldon wire desk — your work goes here.

Five async entry points. Keep the names and signatures exactly as they are;
everything else is up to you.

Run `python3 check_local.py` from this directory to see what they return.
"""
import asyncio

from wire_kit import (BULLETIN_SYSTEM, MODEL, NOTE_SYSTEM, SUMMARY_SYSTEM,
                      URGENCY_SYSTEM, desk_prompt, make_async_client,
                      story_prompt)


async def summarise_batch(story_ids):
    """One summary per story id, in the same order as story_ids.

    Returns: list[str]
    """
    raise NotImplementedError("summarise_batch")


async def rank_urgency(story_ids, limit):
    """Story ids ranked by urgency score, highest first.

    Never allow more than `limit` calls to be in flight at the same time.

    Returns: list[str]
    """
    raise NotImplementedError("rank_urgency")


async def gather_desk_notes(requests):
    """One entry per request, in the order given, whether it worked or not.

    Each request is a dict with "story_id" and "desk".

    Returns: list[dict]
    """
    raise NotImplementedError("gather_desk_notes")


async def bulletin_under_deadline(story_id, budget):
    """The bulletin for one story, if it arrives within `budget` seconds.

    Returns: dict
    """
    raise NotImplementedError("bulletin_under_deadline")


async def stream_bulletin(story_id):
    """Yield the bulletin for one story piece by piece, as it arrives.

    This must be an async generator, so callers can drive it with `async for`.
    """
    raise NotImplementedError("stream_bulletin")
    yield ""  # keeps this an async generator before you fill it in
