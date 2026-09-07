"""Probe E: threads again, but each thread runs its own event loop and every
call goes through the provided client. This is the construction that routes
around both hardenings, so it is worth knowing what it scores."""
import asyncio
import concurrent.futures as cf
import threading

from wire_kit import (BULLETIN_SYSTEM, MODEL, NOTE_SYSTEM, SUMMARY_SYSTEM,
                      URGENCY_SYSTEM, desk_prompt, make_async_client,
                      story_prompt)


async def _ask_async(system, user):
    async with make_async_client() as client:
        resp = await client.chat.completions.create(
            model=MODEL,
            messages=[{"role": "system", "content": system},
                      {"role": "user", "content": user}])
        return (resp.choices[0].message.content or "").strip()


def _blocking(system, user):
    # A fresh event loop inside this worker thread.
    return asyncio.run(_ask_async(system, user))


async def summarise_batch(story_ids):
    with cf.ThreadPoolExecutor(max_workers=32) as pool:
        return list(pool.map(
            lambda s: _blocking(SUMMARY_SYSTEM, story_prompt(s)), story_ids))


async def rank_urgency(story_ids, limit):
    gate = threading.Semaphore(limit)

    def one(s):
        with gate:
            raw = _blocking(URGENCY_SYSTEM, story_prompt(s))
        try:
            return float(raw.split()[0])
        except (ValueError, IndexError):
            return 0.0

    with cf.ThreadPoolExecutor(max_workers=32) as pool:
        scores = list(pool.map(one, story_ids))
    return [s for s, _ in sorted(zip(story_ids, scores), key=lambda p: -p[1])]


async def gather_desk_notes(requests):
    def one(item):
        try:
            return {"story_id": item["story_id"], "desk": item["desk"],
                    "ok": True,
                    "note": _blocking(NOTE_SYSTEM,
                                      desk_prompt(item["story_id"], item["desk"]))}
        except Exception as exc:
            return {"story_id": item["story_id"], "desk": item["desk"],
                    "ok": False, "error": str(exc)}

    with cf.ThreadPoolExecutor(max_workers=32) as pool:
        return list(pool.map(one, requests))


async def bulletin_under_deadline(story_id, budget):
    async def inner():
        try:
            text = await asyncio.wait_for(
                _ask_async(BULLETIN_SYSTEM, story_prompt(story_id)),
                timeout=budget)
        except asyncio.TimeoutError:
            return {"ok": False, "reason": "deadline"}
        return {"ok": True, "text": text}

    with cf.ThreadPoolExecutor(max_workers=1) as pool:
        return pool.submit(lambda: asyncio.run(inner())).result()


async def stream_bulletin(story_id):
    async with make_async_client() as client:
        stream = await client.chat.completions.create(
            model=MODEL,
            messages=[{"role": "system", "content": BULLETIN_SYSTEM},
                      {"role": "user", "content": story_prompt(story_id)}],
            stream=True)
        async for chunk in stream:
            piece = chunk.choices[0].delta.content or ""
            if piece:
                yield piece
