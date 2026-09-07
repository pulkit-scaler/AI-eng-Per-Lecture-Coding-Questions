#!/usr/bin/env python3
"""Run your five functions and print what they return.

    python3 check_local.py

This calls the same wire desk the checks use, on the same stories shown in the
problem statement. It prints results and timings; it does not score anything.
"""
import asyncio
import inspect
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

BATCH = ["wf-3102", "wf-3108", "wf-3121", "wf-3152"]
QUEUE = ["wf-3102", "wf-3108", "wf-3121", "wf-3152", "wf-3164", "wf-3171"]
NOTE_REQUESTS = [
    {"story_id": "wf-3102", "desk": "newsroom"},
    {"story_id": "wf-3108", "desk": "sports"},
    {"story_id": "wf-3121", "desk": "legal"},
    {"story_id": "wf-3164", "desk": "picture"},
]
SLOW_STORY = "wf-3133"
FAST_STORY = "wf-3102"
STREAM_STORY = "wf-3171"

RULE = "-" * 68


def head(title):
    print("\n" + RULE)
    print(title)
    print(RULE)


async def check(label, coro):
    started = time.perf_counter()
    try:
        value = await coro
    except NotImplementedError as exc:
        print("  not written yet: %s" % exc)
        return None
    except Exception as exc:
        print("  raised %s: %s" % (type(exc).__name__, exc))
        return None
    print("  returned in %.2fs" % (time.perf_counter() - started))
    return value


async def main():
    import solution

    head("1. summarise_batch — %d stories" % len(BATCH))
    got = await check("summarise_batch", solution.summarise_batch(BATCH))
    if got is not None:
        for story_id, text in zip(BATCH, got):
            print("  %s  %s" % (story_id, text))
        print("  (sequential would take about %.1fs)" % (0.55 * len(BATCH)))

    head("2. rank_urgency — %d stories, at most 2 calls at a time" % len(QUEUE))
    got = await check("rank_urgency", solution.rank_urgency(QUEUE, 2))
    if got is not None:
        print("  hardest push first: %s" % (got,))

    head("3. gather_desk_notes — %d requests" % len(NOTE_REQUESTS))
    got = await check("gather_desk_notes",
                      solution.gather_desk_notes(NOTE_REQUESTS))
    if got is not None:
        for entry in got:
            if entry.get("ok"):
                print("  ok    %s" % entry.get("note"))
            else:
                print("  error %s/%s -> %s" % (entry.get("story_id"),
                                               entry.get("desk"),
                                               entry.get("error")))

    head("4. bulletin_under_deadline — a tight budget, then a generous one")
    got = await check("tight",
                      solution.bulletin_under_deadline(SLOW_STORY, 1.0))
    print("  %s -> %s" % (SLOW_STORY, got))
    got = await check("generous",
                      solution.bulletin_under_deadline(FAST_STORY, 10))
    print("  %s -> %s" % (FAST_STORY, got))

    head("5. stream_bulletin — pieces as they arrive")
    if not inspect.isasyncgenfunction(solution.stream_bulletin):
        print("  this is not an async generator yet, so `async for` cannot "
              "drive it")
        return
    started = time.perf_counter()
    pieces = 0
    try:
        async for piece in solution.stream_bulletin(STREAM_STORY):
            pieces += 1
            print("  +%.2fs  %r" % (time.perf_counter() - started, piece))
    except NotImplementedError as exc:
        print("  not written yet: %s" % exc)
        return
    except Exception as exc:
        print("  raised %s: %s" % (type(exc).__name__, exc))
        return
    print("  %d pieces in %.2fs" % (pieces, time.perf_counter() - started))


if __name__ == "__main__":
    asyncio.run(main())
