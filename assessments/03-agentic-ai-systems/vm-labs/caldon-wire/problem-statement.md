# Caldon Wire Desk — Lab Question

## Overview

The Caldon wire desk takes raw copy off a news feed and puts it through a language
model: a house-style summary for each story, an urgency score so the queue can be
ranked, a note from each specialist desk, and the on-air bulletin. Every one of those
is a network call that spends almost all of its time waiting.

A first version of this desk was written with a plain loop. It is correct and it is far
too slow: a burst of fourteen stories takes as long as the sum of every round trip, the
wire provider starts rejecting calls when someone widens the loop carelessly, one
rejected request takes the whole batch down with it, a slow pull blocks the desk past
its deadline, and the bulletin only appears once the last word has arrived.

You write the concurrency layer that fixes all five. The client, the feed and the
prompts are provided — **you write only the async logic in `solution.py`**.

## Learning objectives

- Run many independent I/O calls concurrently and collect the results in a known order.
- Cap how many calls are in flight at once, so a burst never exceeds what the far end
  will take.
- Contain a failure inside one task so the rest of a batch still completes, and return
  the failure as data rather than letting it escape.
- Put a hard time budget on a call and abandon it cleanly when the budget runs out.
- Produce values over time with an async generator, so a caller can consume them with
  `async for` as they arrive.

## What is provided

Everything lives in `/home/user/caldon-wire/`:

- `wire_kit/client.py` — `make_async_client()`, which returns the configured async
  client for the wire desk, and `MODEL`. **Provided, do not modify.**
- `wire_kit/feed.py` — `load_stories()`, `story_ids()` and `story(story_id)` for
  reading the feed. **Provided, do not modify.**
- `wire_kit/prompts.py` — the four system prompts (`SUMMARY_SYSTEM`, `URGENCY_SYSTEM`,
  `NOTE_SYSTEM`, `BULLETIN_SYSTEM`), the `DESKS` list, and the two request builders
  `story_prompt(story_id)` and `desk_prompt(story_id, desk)`. **Provided, do not
  modify.**
- `data/wire_feed.json` — the stories currently on the wire. **Provided.**
- `check_local.py` — runs your five functions and prints what they return.
  **Provided.**
- `solution.py` — **you write this.**

Useful facts about the environment:

- **Wire desk:** already running on `http://127.0.0.1:8794`. Leave it running; the
  provided client is already pointed at it.
- **Model name:** `caldon-wire-1`, available as `MODEL` from `wire_kit`.
- **Desks that are staffed:** `newsroom`, `legal`, `picture`, `standards`. A request
  naming any other desk is rejected by the wire desk and surfaces as an exception from
  the client.
- **Holding time:** every call to the desk takes roughly half a second, because it is a
  real round trip. A few pulls take several seconds.
- **Importable:** the `openai` package, its dependencies, and the Python standard
  library. There is no `numpy`, `pandas` or `scikit-learn` on this machine — an import
  of one at the top of `solution.py` stops the file loading at all.
- **Run your program before you submit.** `python3 check_local.py` from the project
  directory is the fastest way to see all five functions work end to end.

## Interface contract (the grader depends on these)

- The project is at `/home/user/caldon-wire/` and your work is in `solution.py` there.
- `solution.py` defines exactly these five names, with these signatures:
  - `async def summarise_batch(story_ids)`
  - `async def rank_urgency(story_ids, limit)`
  - `async def gather_desk_notes(requests)`
  - `async def bulletin_under_deadline(story_id, budget)`
  - `async def stream_bulletin(story_id)`
- The first four are coroutine functions and are awaited. `stream_bulletin` must be an
  **async generator**, driven with `async for`.
- Every call to the model goes through `make_async_client()` and the system prompt from
  `wire_kit.prompts` that matches the task. The desk decides what it is being asked for
  from that system prompt, so a hand-assembled call reaches the wrong desk. The provided
  client is also what attributes a call to you: **a client you construct yourself is not
  attributed to your run, and the checks will not see its calls.**
- How you organise the code inside those five functions is entirely up to you. Helper
  functions, classes, one client or several — all fine, as long as the behaviour below
  holds.

## Your tasks

### Task 1 — `async def summarise_batch(story_ids)`

Produce the house-style summary for every story in `story_ids`, with all of the calls
in flight at the same time.

1. Take a list of story ids, for example `["wf-3102", "wf-3108", "wf-3121"]`.
2. For each id, ask the desk for a summary using `SUMMARY_SYSTEM` as the system prompt
   and `story_prompt(story_id)` as the user message.
3. Dispatch all of them **together**, so the batch finishes in roughly the time of the
   slowest single call rather than the sum of them all.
4. Return a list of the summary strings, one per input id, **in the same order as
   `story_ids`** — the summary at position `i` must belong to `story_ids[i]`, whichever
   call happened to finish first.
5. Strip surrounding whitespace from each summary.

**Requirements:** exactly one call per story id. Any construction that runs them
concurrently scores full marks.

**Example:**

Given `["wf-3102", "wf-3121"]`, a correct return value is

```
["Wexmoor desk: Flood barrier holds through second surge. 5400 people affected, filed 12 minutes ago.",
 "Wexmoor desk: Survey orders three school roofs closed. 1200 people affected, filed 95 minutes ago."]
```

and the two calls overlap, so the pair completes in about half a second rather than a
full second.

### Task 2 — `async def rank_urgency(story_ids, limit)`

Score a whole queue of stories and rank it, without ever having more than `limit` calls
open at the wire desk at once.

1. Take a list of story ids and an integer `limit`.
2. For each id, ask the desk for an urgency score using `URGENCY_SYSTEM` and
   `story_prompt(story_id)`. The reply is a bare number as text.
3. Allow **at most `limit`** of those calls to be in flight at any moment. The rest wait
   their turn and go out as slots free up — the cap has to hold for the entire queue,
   not just the opening burst.
4. Parse each reply into a number. If a reply cannot be parsed, treat that story as
   scoring `0.0` rather than letting it raise.
5. Return the story ids ordered by score, **highest first**. Stories on the same score
   keep the order they were given in.

**Requirements:** exactly one call per story id, and the queue must still be worked
through concurrently up to the cap — dropping to one call at a time is not a valid way
to respect the limit.

**Example:**

Given `["wf-3121", "wf-3152", "wf-3108"]` and `limit=2`, the desk scores them 3, 28 and
23, so the return value is

```
["wf-3152", "wf-3108", "wf-3121"]
```

and no more than two calls are ever open at the same time.

### Task 3 — `async def gather_desk_notes(requests)`

Collect a note from each named desk, and make sure a rejected request costs you that
one entry and nothing else.

1. Take a list of dicts, each with a `"story_id"` and a `"desk"`, for example
   `{"story_id": "wf-3102", "desk": "newsroom"}`.
2. For each request, ask for a note using `NOTE_SYSTEM` and
   `desk_prompt(story_id, desk)`.
3. Send them concurrently.
4. Some requests name a desk the wire does not staff. Those come back from the client as
   an exception. **Catch it** and turn it into a value, so the rest of the batch still
   finishes and the caller gets one entry per request.
5. Return a list with one dict per request, **in the order the requests were given**:
   - for a request that worked:
     `{"story_id": ..., "desk": ..., "ok": True, "note": "<the note text>"}`
   - for a request that was rejected:
     `{"story_id": ..., "desk": ..., "ok": False, "error": "<a short description of
     what went wrong>"}`
6. The `error` string is yours to word, but it must not be empty.

**Requirements:** every request is dispatched, including the ones that will fail — one
failure must not cancel, skip or reorder the others.

**Example:**

Given

```
[{"story_id": "wf-3102", "desk": "newsroom"},
 {"story_id": "wf-3108", "desk": "sports"}]
```

a correct return value is

```
[{"story_id": "wf-3102", "desk": "newsroom", "ok": True,
  "note": "newsroom note on flood-barrier-holds: lead with the Wexmoor angle, 5400 affected."},
 {"story_id": "wf-3108", "desk": "sports", "ok": False,
  "error": "BadRequestError: the sports desk is not staffed on the Caldon wire"}]
```

### Task 4 — `async def bulletin_under_deadline(story_id, budget)`

Ask for a bulletin, but give up on it if it has not arrived within `budget` seconds.

1. Take a story id and a `budget` in seconds (a float).
2. Ask the desk for the bulletin using `BULLETIN_SYSTEM` and `story_prompt(story_id)`.
3. Put a hard time limit of `budget` seconds on that call.
4. If the bulletin arrives in time, return `{"ok": True, "text": "<the bulletin>"}` with
   surrounding whitespace stripped.
5. If the budget runs out first, **stop the call** and return
   `{"ok": False, "reason": "deadline"}`. Your function must return at the deadline, not
   once the desk eventually replies — and the call itself must be cancelled at that
   point, not left running in the background while you return early.
6. Some pulls take several seconds and some are quick. Which one you get is decided by
   the story, so both paths have to work.

**Requirements:** the call must actually be made, and it must actually be dropped — a
deadline is something you place on a request that is genuinely in flight, and abandoning
it means the request stops, not that you stop reading it. Returning the miss without
asking the desk at all does not count, and neither does leaving the call running.

**Example:**

`await bulletin_under_deadline("wf-3133", 1.0)` returns `{"ok": False, "reason":
"deadline"}` after about one second, because that pull runs longer than a second.
`await bulletin_under_deadline("wf-3102", 10)` returns
`{"ok": True, "text": "Flood barrier holds through second surge. ..."}` after about half
a second.

### Task 5 — `async def stream_bulletin(story_id)`

Hand the bulletin to the caller piece by piece, as it comes in off the wire, rather than
in one lump at the end.

1. Make this an **async generator** — `async def` with `yield` in the body — so a caller
   can drive it with `async for piece in stream_bulletin(...)`.
2. Ask the desk for the bulletin using `BULLETIN_SYSTEM` and `story_prompt(story_id)`,
   requesting it as a stream.
3. Yield each non-empty piece of text **as it arrives**, before the rest of the bulletin
   has been written. Do not collect the whole reply and then cut it up.
4. Skip pieces that carry no text.
5. When the pieces are joined together in the order they were yielded, they must equal
   the complete bulletin for that story.

**Requirements:** the caller must see the first piece well before the last one. A
generator that waits for the complete reply and then yields it in slices produces the
right text but defeats the point.

**Example:**

```
async for piece in stream_bulletin("wf-3171"):
    print(piece, end="", flush=True)
```

prints the bulletin progressively over about a second, and the printed text is the
complete bulletin.

## Run & verify locally

From the project directory:

```
cd /home/user/caldon-wire
python3 check_local.py
```

That runs all five functions against the wire desk on the sample stories and prints what
each returns, along with how long it took. Timings are the point: a correct
`summarise_batch` over four stories finishes in well under a second, and a
`stream_bulletin` prints pieces spread across the second rather than all at once.

You can also drive a single function yourself:

```
python3 -c "import asyncio, solution; print(asyncio.run(solution.summarise_batch(['wf-3102','wf-3152'])))"
```

The grader uses its own stories, so a solution that only handles the ones shown here
will not pass.

## How you are graded (50 points, 5 checks x 10)

Each check is all-or-nothing and runs your code against the live wire desk.

1. **Summaries fan out.** `summarise_batch` returns the correct summary for every story,
   lined up with the ids it was given, having made one call per story with all of them
   open at the desk together rather than one after another.
2. **The queue respects its cap.** `rank_urgency` scores every story in the queue exactly
   once and returns the correct ranking, while never exceeding the limit it was given
   and still using the full width of that limit.
3. **A rejected desk stays contained.** `gather_desk_notes` returns one entry per
   request, in order, with the correct note for every staffed desk and a non-empty
   failure record for every rejected one — with all requests dispatched together, so one
   rejection does not take the batch down.
4. **The deadline holds.** `bulletin_under_deadline` returns the miss at its deadline for
   a pull that cannot finish in time, having genuinely made that call and cancelled it at
   the deadline rather than leaving it running, and returns the correct bulletin when the
   budget is generous enough.
5. **The bulletin streams.** `stream_bulletin` is an async generator whose pieces arrive
   spread over time as the desk writes them, and which joins back into exactly the
   bulletin for that story.

The grader checks only the values your functions return and how your calls behave at the
wire desk, never how you write them — there is no single correct solution, and any
solution that passes these checks scores full marks.
