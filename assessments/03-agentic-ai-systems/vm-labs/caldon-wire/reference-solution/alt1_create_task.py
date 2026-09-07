"""Alternative shape: create_task everywhere, a class for the desk, and a
client built per call. Must score 50/50."""
import asyncio

from wire_kit import (BULLETIN_SYSTEM, MODEL, NOTE_SYSTEM, SUMMARY_SYSTEM,
                      URGENCY_SYSTEM, desk_prompt, make_async_client,
                      story_prompt)


class Desk:
    def __init__(self, client):
        self.client = client

    async def ask(self, system, user):
        resp = await self.client.chat.completions.create(
            model=MODEL,
            messages=[{"role": "system", "content": system},
                      {"role": "user", "content": user}])
        return (resp.choices[0].message.content or "").strip()


async def summarise_batch(story_ids):
    client = make_async_client()
    desk = Desk(client)
    tasks = [asyncio.create_task(desk.ask(SUMMARY_SYSTEM, story_prompt(s)))
             for s in story_ids]
    out = []
    for task in tasks:
        out.append(await task)
    await client.close()
    return out


async def rank_urgency(story_ids, limit):
    client = make_async_client()
    desk = Desk(client)
    gate = asyncio.Semaphore(limit)
    results = {}

    async def worker(index, sid):
        async with gate:
            raw = await desk.ask(URGENCY_SYSTEM, story_prompt(sid))
        try:
            results[index] = float(raw.strip().split()[0])
        except (ValueError, IndexError):
            results[index] = 0.0

    tasks = [asyncio.create_task(worker(i, s))
             for i, s in enumerate(story_ids)]
    for task in tasks:
        await task
    await client.close()
    order = sorted(range(len(story_ids)),
                   key=lambda i: (-results[i], i))
    return [story_ids[i] for i in order]


async def gather_desk_notes(requests):
    client = make_async_client()
    desk = Desk(client)

    async def worker(item):
        try:
            note = await desk.ask(NOTE_SYSTEM,
                                  desk_prompt(item["story_id"], item["desk"]))
        except Exception as exc:
            return {"story_id": item["story_id"], "desk": item["desk"],
                    "ok": False, "error": repr(exc)}
        return {"story_id": item["story_id"], "desk": item["desk"],
                "ok": True, "note": note}

    tasks = [asyncio.create_task(worker(item)) for item in requests]
    out = [await task for task in tasks]
    await client.close()
    return out


async def bulletin_under_deadline(story_id, budget):
    client = make_async_client()
    desk = Desk(client)
    task = asyncio.create_task(desk.ask(BULLETIN_SYSTEM,
                                        story_prompt(story_id)))
    try:
        text = await asyncio.wait_for(asyncio.shield(task), timeout=budget)
    except asyncio.TimeoutError:
        task.cancel()
        try:
            await task
        except (asyncio.CancelledError, Exception):
            pass
        await client.close()
        return {"ok": False, "reason": "deadline"}
    await client.close()
    return {"ok": True, "text": text}


async def stream_bulletin(story_id):
    client = make_async_client()
    try:
        stream = await client.chat.completions.create(
            model=MODEL,
            messages=[{"role": "system", "content": BULLETIN_SYSTEM},
                      {"role": "user", "content": story_prompt(story_id)}],
            stream=True)
        async for chunk in stream:
            piece = chunk.choices[0].delta.content or ""
            if piece:
                yield piece
    finally:
        await client.close()
