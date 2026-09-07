"""Alternative shape: TaskGroup, gather(return_exceptions=True), a plain
timeout guard and a generator that hands the stream straight through.
Must score 50/50."""
import asyncio

from wire_kit import (BULLETIN_SYSTEM, MODEL, NOTE_SYSTEM, SUMMARY_SYSTEM,
                      URGENCY_SYSTEM, desk_prompt, make_async_client,
                      story_prompt)

CLIENT = None


def desk():
    global CLIENT
    if CLIENT is None:
        CLIENT = make_async_client()
    return CLIENT


async def ask(system, user):
    resp = await desk().chat.completions.create(
        model=MODEL,
        messages=[{"role": "system", "content": system},
                  {"role": "user", "content": user}])
    return (resp.choices[0].message.content or "").strip()


async def summarise_batch(story_ids):
    slots = [None] * len(story_ids)

    async def fill(index, sid):
        slots[index] = await ask(SUMMARY_SYSTEM, story_prompt(sid))

    async with asyncio.TaskGroup() as group:
        for index, sid in enumerate(story_ids):
            group.create_task(fill(index, sid))
    return slots


async def rank_urgency(story_ids, limit):
    gate = asyncio.Semaphore(limit)
    scores = [0.0] * len(story_ids)

    async def fill(index, sid):
        async with gate:
            raw = await ask(URGENCY_SYSTEM, story_prompt(sid))
        try:
            scores[index] = float(raw.split()[0])
        except (ValueError, IndexError):
            scores[index] = 0.0

    async with asyncio.TaskGroup() as group:
        for index, sid in enumerate(story_ids):
            group.create_task(fill(index, sid))
    pairs = sorted(enumerate(story_ids), key=lambda p: (-scores[p[0]], p[0]))
    return [sid for _, sid in pairs]


async def gather_desk_notes(requests):
    # gather with return_exceptions collects the failures as values, then they
    # are turned into the structured entries the caller expects.
    raw = await asyncio.gather(
        *(ask(NOTE_SYSTEM, desk_prompt(r["story_id"], r["desk"]))
          for r in requests),
        return_exceptions=True)
    out = []
    for item, value in zip(requests, raw):
        if isinstance(value, BaseException):
            out.append({"story_id": item["story_id"], "desk": item["desk"],
                        "ok": False,
                        "error": "%s" % (value,)})
        else:
            out.append({"story_id": item["story_id"], "desk": item["desk"],
                        "ok": True, "note": value})
    return out


async def bulletin_under_deadline(story_id, budget):
    try:
        async with asyncio.timeout(budget):
            text = await ask(BULLETIN_SYSTEM, story_prompt(story_id))
    except (asyncio.TimeoutError, TimeoutError):
        return {"ok": False, "reason": "deadline"}
    return {"ok": True, "text": text}


async def stream_bulletin(story_id):
    stream = await desk().chat.completions.create(
        model=MODEL,
        messages=[{"role": "system", "content": BULLETIN_SYSTEM},
                  {"role": "user", "content": story_prompt(story_id)}],
        stream=True)
    async for chunk in stream:
        for choice in chunk.choices:
            if choice.delta.content:
                yield choice.delta.content
