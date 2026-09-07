"""Attack A: coroutines in name only. Blocking sync client, one call after
another, no concurrency anywhere. This is what "just write the function
definitions and return the right things" looks like when the values are real."""
import os

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
    return [_ask(c, SUMMARY_SYSTEM, story_prompt(s)) for s in story_ids]


async def rank_urgency(story_ids, limit):
    c = _client()
    scores = []
    for s in story_ids:
        try:
            scores.append(float(_ask(c, URGENCY_SYSTEM, story_prompt(s)).split()[0]))
        except (ValueError, IndexError):
            scores.append(0.0)
    return [s for s, _ in sorted(zip(story_ids, scores), key=lambda p: -p[1])]


async def gather_desk_notes(requests):
    c = _client()
    out = []
    for item in requests:
        try:
            out.append({"story_id": item["story_id"], "desk": item["desk"],
                        "ok": True,
                        "note": _ask(c, NOTE_SYSTEM,
                                     desk_prompt(item["story_id"], item["desk"]))})
        except Exception as exc:
            out.append({"story_id": item["story_id"], "desk": item["desk"],
                        "ok": False, "error": str(exc)})
    return out


async def bulletin_under_deadline(story_id, budget):
    c = _client()
    try:
        return {"ok": True, "text": _ask(c, BULLETIN_SYSTEM, story_prompt(story_id))}
    except Exception:
        return {"ok": False, "reason": "deadline"}


async def stream_bulletin(story_id):
    c = _client()
    text = _ask(c, BULLETIN_SYSTEM, story_prompt(story_id))
    for w in text.split(" "):
        yield w + " "
