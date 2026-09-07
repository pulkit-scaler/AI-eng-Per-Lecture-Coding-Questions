"""Attack B: real concurrency, but from a thread pool and a blocking client
rather than from the event loop. The five names are still coroutines, so the
harness can await them; everything underneath is threads."""
import asyncio
import concurrent.futures as cf
import os
import threading

from openai import OpenAI

from wire_kit import (BULLETIN_SYSTEM, MODEL, NOTE_SYSTEM, SUMMARY_SYSTEM,
                      URGENCY_SYSTEM, desk_prompt, story_prompt)
from wire_kit.client import BASE_URL


def _client():
    return OpenAI(base_url=BASE_URL, api_key="caldon-local", max_retries=0,
                  default_headers={"X-Caldon-Run":
                                   os.environ.get("CALDON_RUN_ID", "default")})


def _ask(c, system, user):
    r = c.chat.completions.create(model=MODEL, messages=[
        {"role": "system", "content": system},
        {"role": "user", "content": user}])
    return (r.choices[0].message.content or "").strip()


async def summarise_batch(story_ids):
    c = _client()
    with cf.ThreadPoolExecutor(max_workers=32) as pool:
        return list(pool.map(lambda s: _ask(c, SUMMARY_SYSTEM, story_prompt(s)),
                             story_ids))


async def rank_urgency(story_ids, limit):
    c = _client()
    gate = threading.Semaphore(limit)

    def one(s):
        with gate:
            raw = _ask(c, URGENCY_SYSTEM, story_prompt(s))
        try:
            return float(raw.split()[0])
        except (ValueError, IndexError):
            return 0.0

    with cf.ThreadPoolExecutor(max_workers=32) as pool:
        scores = list(pool.map(one, story_ids))
    return [s for s, _ in sorted(zip(story_ids, scores), key=lambda p: -p[1])]


async def gather_desk_notes(requests):
    c = _client()

    def one(item):
        try:
            return {"story_id": item["story_id"], "desk": item["desk"],
                    "ok": True,
                    "note": _ask(c, NOTE_SYSTEM,
                                 desk_prompt(item["story_id"], item["desk"]))}
        except Exception as exc:
            return {"story_id": item["story_id"], "desk": item["desk"],
                    "ok": False, "error": str(exc)}

    with cf.ThreadPoolExecutor(max_workers=32) as pool:
        return list(pool.map(one, requests))


async def bulletin_under_deadline(story_id, budget):
    c = _client()
    pool = cf.ThreadPoolExecutor(max_workers=2)
    fut = pool.submit(_ask, c, BULLETIN_SYSTEM, story_prompt(story_id))
    try:
        text = fut.result(timeout=budget)
    except cf.TimeoutError:
        # A future cannot be cancelled once it is running; the thread carries on.
        fut.cancel()
        pool.shutdown(wait=False)
        return {"ok": False, "reason": "deadline"}
    pool.shutdown(wait=False)
    return {"ok": True, "text": text}


async def stream_bulletin(story_id):
    c = _client()
    stream = c.chat.completions.create(
        model=MODEL,
        messages=[{"role": "system", "content": BULLETIN_SYSTEM},
                  {"role": "user", "content": story_prompt(story_id)}],
        stream=True)
    for chunk in stream:
        piece = chunk.choices[0].delta.content or ""
        if piece:
            await asyncio.sleep(0)
            yield piece
