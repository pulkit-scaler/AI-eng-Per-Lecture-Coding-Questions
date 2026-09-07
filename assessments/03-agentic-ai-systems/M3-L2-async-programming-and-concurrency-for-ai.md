# Module 3, Lecture 2 — Asynchronous Programming & Concurrency for AI

Four coding questions covering the four things the lecture asks an engineer to control once LLM calls
stop being sequential: **how many run at once** (`asyncio.Semaphore`), **how a race ends and who gets
cancelled** (`asyncio.wait(FIRST_COMPLETED)` + `CancelledError`), **how tokens interleave when several
streams are consumed together** (async generators), and **what a concurrency cap costs the caller
whose latency budget includes the queue** (`asyncio.wait_for` over a semaphore).

Every question is graded on a value the event loop **produces** — a completion order, a settle order,
a merged token sequence, a set of budget outcomes — not on a formula evaluated over the inputs. Q1,
Q2 and Q4 each carry a case that a closed-form solution gets wrong; those cases are named in the
grader notes and must not be dropped.

All four are **standard library only** — `asyncio`, nothing else. No LLM call, no API key, no network,
no model download. Every simulated call is an `asyncio.sleep`, so the questions run in well under a
second each and are byte-reproducible.

> **Numbering.** This file follows the `M3-L<n>` convention already on disk, where `M3-L1` is Pydantic
> and this lecture is `L2`. The `modules/03-agentic-ai-systems/markdown/` tree numbers the same
> lecture `L1_Asynchronous_Programming_&_Concurrency_for_AI.md` — that offset is documented in
> `assessments/README.md` and is not a mistake in either place.

---

## Q1: Cap the fan-out — what a semaphore does to completion order

**Context:** A batch job fires one LLM call per row. Unbounded, that is a thousand concurrent requests
against a provider that will rate-limit you, and a connection pool that will not survive it. The
standard fix is a semaphore: at most `limit` calls in flight, everyone else parks until a slot frees.
What surprises people the first time is that the cap does not merely slow the batch down — it
**reorders it**. A call that would have finished third can finish first simply because it was holding
a slot when a shorter call was still queued. Before you can reason about a bounded batch, you have to
be able to say which calls come back, and in what order.

**Problem Statement:**

Write a function `bounded_fanout(durations, limit)` that runs one simulated API call per entry in
`durations` under a shared concurrency cap, and reports what the event loop actually did.

1. Treat `durations[i]` as the number of seconds call `i` spends waiting on the network. Simulate that
   wait with `asyncio.sleep`.
2. Guard the calls with a single `asyncio.Semaphore(limit)` shared by all of them, so at most `limit`
   calls are ever inside the network wait at the same time. Dispatch the calls in index order, so
   queued calls take a free slot in that same order.
3. Track how many calls are **holding a slot** at any moment, and record the largest value that counter
   ever reaches. A call that is parked waiting for a slot is not holding one and must not be counted.
4. Each time a call finishes its wait, append its 0-based index to a completion list.
5. Return a dictionary with exactly these two keys:
   - `"completion_order"` — the list of 0-based indices, in the order the calls finished
   - `"peak_in_flight"` — the largest number of calls measured holding a slot simultaneously

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: durations (list_float)
    Line 1: N (list length)
    Line 2: N space-separated floats
  Argument 2: limit (integer)
    Single line: one integer
```

**Output Format:**

For each test case, print the result of `bounded_fanout()` on a new line.

**Sample Input:**

```
durations = [0.30, 0.10, 0.05, 0.20]
limit = 2
```

**Sample Output:**

```
{'completion_order': [1, 2, 0, 3], 'peak_in_flight': 2}
```

**Note:** `peak_in_flight` is a **measured** figure, not a restatement of `limit` — when there are
fewer calls than slots, nothing ever queues and the peak is however many calls there were. Build the
semaphore inside the function so each call to `bounded_fanout` starts from a clean cap.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: bounded_fanout
RETURN TYPE: Dictionary

ARGUMENTS:
1. durations → List of Floats
2. limit     → Integer
```

**Reference Solution:**

```python
import asyncio


def bounded_fanout(durations: list, limit: int) -> dict:
    async def _main():
        slots = asyncio.Semaphore(limit)
        live = {"now": 0, "peak": 0}
        finished = []

        async def call(index, seconds):
            async with slots:
                live["now"] += 1
                live["peak"] = max(live["peak"], live["now"])
                try:
                    await asyncio.sleep(seconds)
                finally:
                    live["now"] -= 1
            finished.append(index)

        await asyncio.gather(*(call(i, d) for i, d in enumerate(durations)))
        return {"completion_order": finished, "peak_in_flight": live["peak"]}

    return asyncio.run(_main())
```

**Test Cases —** `in.txt`

```
3
4
0.3 0.1 0.05 0.2
2
3
0.15 0.05 0.25
5
3
0.1 0.05 0.05
1
```

**Test Cases —** `out.txt`

```
{'completion_order': [1, 2, 0, 3], 'peak_in_flight': 2}
{'completion_order': [1, 0, 2], 'peak_in_flight': 3}
{'completion_order': [0, 1, 2], 'peak_in_flight': 1}
```

**Grader Notes:**

- All three cases were **executed** against the reference solution (Python 3.12.13, standard library
  only) and re-run **20 times**; the `out.txt` lines are the actual program output, byte-identical on
  every run. The graded value includes a completion order, so the re-run count matters.
- **Timing margins.** Every duration is a multiple of 0.05 s and no two events in any case land closer
  than 0.05 s apart, against an event-loop overhead of roughly 1 ms. If this question is ever ported to
  a slower grader, keep that 50× margin rather than shrinking the sleeps.
- `peak_in_flight` is `min(limit, len(durations))` **by construction** — it is not the discriminating
  field and cannot separate a real semaphore from arithmetic. It is graded because it catches where the
  counter was incremented. `completion_order` is the field that does the work.
- **Case 2 is load-bearing and must not be dropped.** It is the only case where `limit` (5) exceeds the
  number of calls (3), so it is the only case that catches a solution reporting `limit` instead of the
  measured peak. That reading passes cases 1 and 3 cleanly.
- **Case 1 and case 3 are jointly load-bearing.** Case 2 has no contention, so a solution with **no
  semaphore at all** produces the correct answer there; only cases 1 and 3 catch it.
- Case 3 (`limit=1`) is the strongest single discriminator: a correct solution returns the calls in
  **submission** order `[0, 1, 2]` because they run strictly serially, while any unbounded solution
  returns them in **duration** order `[1, 2, 0]`.
- Wrong readings that were implemented and run:
  - **No semaphore** (plain `gather`) — case 1 gives `[1, 2, 3, 0]`-style duration ordering and
    `peak_in_flight` 4; case 3 gives `[1, 2, 0]` and peak 3. Passes case 2.
  - **Counter incremented before acquiring the slot** (outside the `async with`) — peak becomes the
    total number of calls. Fails cases 1 and 3, passes case 2.
  - **Returning `limit` instead of the measured peak** — fails case 2 only.
- Dictionary key order is not significant; compare by key. The two keys and the list of ints are all
  authored by the learner, so exact comparison is correct here.
- The statement fixes *that* a semaphore is used rather than leaving the cap open, because queue
  discipline is graded: a FIFO cap and a LIFO cap give different completion orders, and only FIFO is
  what `asyncio.Semaphore` does.

---

## Q2: Race the replicas — first success wins, the rest get cancelled

**Context:** When tail latency matters more than cost, you send the same request to several replicas
and keep whichever answers first, cancelling the others so they stop burning quota. The subtlety is
that "finished first" and "answered first" are not the same thing: a replica that fails fast has
finished, and a race that stops at the first *settled* task will hand you an exception while three
healthy replicas were still one tick from returning. A correct race keeps going until something
actually succeeds, and then cleans up after itself.

**Problem Statement:**

Write a function `first_to_finish(durations, failing)` that races simulated replicas against each
other, keeps the first **successful** one, cancels the rest, and reports what happened to each.

1. Treat `durations[i]` as the seconds replica `i` waits before it settles; simulate the wait with
   `asyncio.sleep`. A replica whose index appears in `failing` then raises a `RuntimeError` instead of
   returning; every other replica returns its own index.
2. Start every replica as a task, dispatched in index order, and wait for the **first one to settle**.
   A replica that raises has settled too, so it can end that wait — when it does, record its index and
   keep racing the ones still running.
3. Stop as soon as a replica settles **successfully**. That replica's index is the winner. If every
   replica raises, the winner is `-1`.
4. Cancel every replica still running once the race is over. Inside a replica, catch the cancellation,
   record that replica's index as cleaned up, and re-raise so the cancellation is acknowledged.
5. Await the cancelled replicas and count how many acknowledged the cancellation.
6. Return a dictionary with exactly these four keys:
   - `"winner"` — the winning index, or `-1` if every replica raised
   - `"failed_first"` — indices of replicas that settled by raising **before** the winner, in the order
     they settled
   - `"cancelled"` — indices of replicas that were cancelled mid-wait, in ascending order
   - `"acknowledged"` — how many of those cancellations were acknowledged

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: durations (list_float)
    Line 1: N (list length)
    Line 2: N space-separated floats
  Argument 2: failing (list_int)
    Line 1: M (list length)
    Line 2: M space-separated integers
```

**Output Format:**

For each test case, print the result of `first_to_finish()` on a new line.

**Sample Input:**

```
durations = [0.30, 0.10, 0.20, 0.40]
failing = [1]
```

**Sample Output:**

```
{'winner': 2, 'failed_first': [1], 'cancelled': [0, 3], 'acknowledged': 2}
```

**Note:** Replica 1 is the quickest to settle but it raises, so it does not win — it goes into
`failed_first` and the race continues to replica 2. Replicas 0 and 3 are still waiting when that
happens, so they are the ones cancelled. `"cancelled"` is sorted; `"failed_first"` is not — it is the
order things actually settled.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: first_to_finish
RETURN TYPE: Dictionary

ARGUMENTS:
1. durations → List of Floats
2. failing   → List of Ints
```

**Reference Solution:**

```python
import asyncio


def first_to_finish(durations: list, failing: list) -> dict:
    async def _main():
        failed_first = []
        cancelled = []

        async def replica(index, seconds):
            try:
                await asyncio.sleep(seconds)
            except asyncio.CancelledError:
                cancelled.append(index)
                raise
            if index in failing:
                failed_first.append(index)
                raise RuntimeError("replica_failed")
            return index

        pending = {asyncio.create_task(replica(i, d)) for i, d in enumerate(durations)}
        winner = -1
        while pending:
            done, pending = await asyncio.wait(pending, return_when=asyncio.FIRST_COMPLETED)
            for task in done:
                if task.exception() is None:
                    winner = task.result()
                    break
            if winner != -1:
                break

        for task in pending:
            task.cancel()
        outcomes = await asyncio.gather(*pending, return_exceptions=True)
        acknowledged = sum(1 for o in outcomes if isinstance(o, asyncio.CancelledError))

        return {"winner": winner,
                "failed_first": failed_first,
                "cancelled": sorted(cancelled),
                "acknowledged": acknowledged}

    return asyncio.run(_main())
```

**Test Cases —** `in.txt`

```
3
4
0.3 0.1 0.2 0.4
1
1
4
0.25 0.05 0.15 0.35
2
1 2
3
0.1 0.2 0.3
3
0 1 2
```

**Test Cases —** `out.txt`

```
{'winner': 2, 'failed_first': [1], 'cancelled': [0, 3], 'acknowledged': 2}
{'winner': 0, 'failed_first': [1, 2], 'cancelled': [3], 'acknowledged': 1}
{'winner': -1, 'failed_first': [0, 1, 2], 'cancelled': [], 'acknowledged': 0}
```

**Grader Notes:**

- All three cases were **executed** and re-run **20 times** with byte-identical output (Python 3.12.13,
  standard library only). Both `failed_first` and the winner depend on settle order, so this matters.
- **Disclosed, not taught.** The lecture teaches `asyncio.wait(..., return_when=FIRST_COMPLETED)` only
  in its cheatsheet and Exercise 3, and never states that a task which *raises* also counts as
  completed and will end the wait. Step 2 discloses that explicitly, because a learner cannot derive it
  from the material. It is stated as a requirement, not as an explanation of the trap.
- **`done` never holds more than one task in these cases.** Every duration in a case is distinct and no
  two are closer than 0.05 s, so each `asyncio.wait` round settles exactly one task and the loop over
  `done` is unambiguous. If a case is ever added with two equal durations, the iteration order over the
  `done` **set** becomes arbitrary and `failed_first` stops being deterministic — do not add one.
- **Case 1 is the closed-form killer.** A solution that picks `argmin(durations)` answers `1`; the true
  winner is `2`, because replica 1 raises. Every case catches this reading, but case 1 is the cheapest
  to point at when defending the marks.
- **Case 3 is the all-fail path** — nothing is left to cancel, so `cancelled` is empty and
  `acknowledged` is 0. It is deliberately the one case where the cancellation bookkeeping is vacuous,
  which is exactly why it must be paired with cases 1 and 2 rather than used alone.
- Wrong readings that were implemented and run:
  - **`winner = argmin(durations)`, everything else derived** — fails all three cases.
  - **Stopping at the first settled task** (not checking `task.exception()`) — fails all three; on
    cases 1 and 2 it reports a winner of `-1` or an error where a real winner exists.
  - **Catching `CancelledError` without re-raising it** — `acknowledged` collapses to 0. Fails cases 1
    and 2; **passes case 3**, which has no cancellations.
  - **Cancelling without awaiting the cancelled tasks** — the coroutines never resume, so neither the
    cleanup record nor the acknowledgement happens. Fails cases 1 and 2; passes case 3.
- The last two readings share a signature: both leave `acknowledged` at 0 while `cancelled` may still
  be right. Cases 1 and 2 are the only ones that separate a real cancellation handshake from a
  fire-and-forget `.cancel()`.
- `"failed_first"` is deliberately **not** sorted while `"cancelled"` is. The statement says so in both
  places and the Note repeats it once, because the two lists look interchangeable in the sample output
  and a learner who sorts both passes case 1 by luck (single element) and fails case 2.
- `RuntimeError` is raised by the learner's own replica, so its type never reaches the graded value —
  only `"failed_first"` membership does. Nothing here depends on a library-generated string.

---

## Q3: Merge several token streams into one live transcript

**Context:** A dashboard that streams several model responses at once is not N independent progress
bars — it is one buffer that many async generators write into as their tokens land. The order in that
buffer is set entirely by which stream's next token arrives first, which is why the merged transcript
of two streams is never just one appended to the other. And because the buffer is what the user sees,
it usually has a budget: once it is full you stop pulling, and the generators still mid-flight are
abandoned rather than drained.

**Problem Statement:**

Write a function `merge_streams(sentences, delays, max_tokens)` that consumes several simulated token
streams concurrently and records the merged transcript.

1. Stream `i` emits the whitespace-separated words of `sentences[i]`, one at a time, in order. Before
   each word it waits `delays[i]` seconds — simulate that with `asyncio.sleep`. Produce the words with
   an async generator.
2. Consume every stream **concurrently**, appending to one shared list as words arrive. Each entry is
   the string `"<index>:<word>"` — the stream's 0-based index, a colon, and the word, with no spaces.
3. The shared list is capped at `max_tokens` entries. Before appending a word, check whether the list
   is already full; if it is, stop consuming that stream and leave the rest of its words unread. A word
   that arrives to a full list is discarded and is not counted anywhere.
4. Count, per stream, how many of its words actually landed in the shared list.
5. Return a dictionary with exactly these two keys:
   - `"merged"` — the shared list, in arrival order
   - `"consumed"` — a dictionary mapping each stream's 0-based index to its count, for every stream

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: sentences (list_string)
    Line 1: N (list length)
    Next N lines: one string each
  Argument 2: delays (list_float)
    Line 1: N (list length)
    Line 2: N space-separated floats
  Argument 3: max_tokens (integer)
    Single line: one integer
```

**Output Format:**

For each test case, print the result of `merge_streams()` on a new line.

**Sample Input:**

```
sentences = ["latency hiding wins", "tokens arrive early"]
delays = [0.05, 0.08]
max_tokens = 5
```

**Sample Output:**

```
{'merged': ['0:latency', '1:tokens', '0:hiding', '0:wins', '1:arrive'], 'consumed': {0: 3, 1: 2}}
```

**Note:** Every stream gets an entry in `"consumed"`, including one that contributed nothing. Stream 1
is slower than stream 0, so it lands only two of its three words before the cap is reached — its third
word is never appended and never counted.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: merge_streams
RETURN TYPE: Dictionary

ARGUMENTS:
1. sentences  → List of Strings
2. delays     → List of Floats
3. max_tokens → Integer
```

**Reference Solution:**

```python
import asyncio


def merge_streams(sentences: list, delays: list, max_tokens: int) -> dict:
    async def _main():
        merged = []
        consumed = {}

        async def stream(sentence, gap):
            for word in sentence.split():
                await asyncio.sleep(gap)
                yield word

        async def drain(index, sentence, gap):
            taken = 0
            async for word in stream(sentence, gap):
                if len(merged) >= max_tokens:
                    break
                merged.append(f"{index}:{word}")
                taken += 1
            consumed[index] = taken

        await asyncio.gather(*(drain(i, s, g)
                               for i, (s, g) in enumerate(zip(sentences, delays))))
        return {"merged": merged, "consumed": dict(sorted(consumed.items()))}

    return asyncio.run(_main())
```

**Test Cases —** `in.txt`

```
2
2
latency hiding wins
tokens arrive early
2
0.05 0.08
5
3
one two three four
alpha beta
x y z
3
0.05 0.11 0.17
7
```

**Test Cases —** `out.txt`

```
{'merged': ['0:latency', '1:tokens', '0:hiding', '0:wins', '1:arrive'], 'consumed': {0: 3, 1: 2}}
{'merged': ['0:one', '0:two', '1:alpha', '0:three', '2:x', '0:four', '1:beta'], 'consumed': {0: 4, 1: 2, 2: 1}}
```

**Grader Notes:**

- Both cases were **executed** and re-run **20 times** with byte-identical output (Python 3.12.13,
  standard library only). The whole graded value is an interleaving, so this is the question where
  re-running mattered most.
- **No two token arrivals collide in either case.** Case 1 fires at 0.05/0.08/0.10/0.15/0.16 s; case 2
  at 0.05/0.10/0.11/0.15/0.17/0.20/0.22 s. The tightest gap is 0.01 s in case 2 (0.10 vs 0.11), which
  is still ~10× the event-loop overhead — but it is the tightest thing in this file, so if a new case
  is added, check its arrival times for collisions before trusting the output.
- **Delays were chosen so no two streams share a multiple.** Case 2's 0.05 / 0.11 / 0.17 have no common
  arrival time within the cap. Do not "tidy" them to 0.05 / 0.10 / 0.15, which collides immediately at
  0.10 and 0.15 and makes the merged order arbitrary.
- The `"<index>:<word>"` format is **authored by the learner**, so it is pinned verbatim in step 2 and
  shown in the sample. No part of the graded value comes from a library.
- Case 2 exists to catch what case 1 cannot: it has three streams rather than two, and one of them
  (stream 2) contributes exactly one word, which is what makes a missing zero-or-low entry in
  `"consumed"` visible.
- Wrong readings that were implemented and run:
  - **Draining the streams sequentially** (`async for` over one stream to completion before starting
    the next) — case 1 gives `['0:latency', '0:hiding', '0:wins', '1:tokens', '1:arrive']`, which has
    the right *multiset* and the right `consumed`, and the wrong order. Fails both cases. This is the
    reading the question exists to catch, and only the order catches it.
  - **Ignoring `max_tokens`** — merged runs to the full word count. Fails both cases.
  - **Counting a word that was discarded** (incrementing before the cap check) — `consumed` overcounts
    the stream that was mid-flight when the cap filled. Fails both cases.
- The cap check happens **before** the append, which is what makes `len(merged) == max_tokens` exactly
  rather than one over. Step 3 states the order explicitly.
- Abandoning a generator mid-iteration via `break` is the lecture's own Exercise 4; the abandoned async
  generators are closed by the runtime at loop shutdown and produce no warning on 3.12. Confirmed
  across all 20 runs — stderr was empty.
- Dictionary key order is not significant. The reference sorts `"consumed"` by key for readability;
  a solution that inserts in completion order produces the same mapping and must not be marked down.

---

## Q4: What the cap costs the caller — a latency budget that includes the queue

**Context:** Capping concurrency protects your provider, and it is the right call. What it does not
do is make the work disappear — it moves the waiting to your side of the wire. A request that spends
200 ms parked waiting for a slot and 200 ms on the wire took 400 ms as far as the caller is concerned,
and if that caller has a 300 ms budget it has already given up. This is the failure mode that makes a
system look healthy from the provider's side and broken from the user's: nothing timed out upstream,
and half your requests still missed their deadline.

**Problem Statement:**

Write a function `queue_under_budget(durations, limit, timeout)` that runs a bounded batch where each
request carries its own deadline, and reports which requests made it.

1. Treat `durations[i]` as the seconds request `i` spends on the wire once it has a slot; simulate that
   with `asyncio.sleep`. Guard the wire time with a single `asyncio.Semaphore(limit)` shared by every
   request, and dispatch the requests in index order.
2. Give every request a deadline of `timeout` seconds using `asyncio.wait_for`. The deadline covers the
   request's **whole** life — the time it spends waiting for a free slot as well as its time on the
   wire — so wrap the acquisition and the wire time together, not just the wire time.
3. Wrap each request so a blown deadline becomes a value rather than an exception, and let the batch
   run to completion regardless of how many miss.
4. Label each request `"ok"` if it completed inside its deadline. Otherwise the label is the **name of
   the exception type** that ended it, passed through unchanged — whatever the runtime raised, not a
   string of your own choosing.
5. Return a dictionary with exactly these two keys:
   - `"labels"` — a dictionary mapping each request's 0-based index to its label
   - `"served"` — how many requests were labelled `"ok"`

**Input Format:**

```
Line 1: T (number of test cases)

For each test case:
  Argument 1: durations (list_float)
    Line 1: N (list length)
    Line 2: N space-separated floats
  Argument 2: limit (integer)
    Single line: one integer
  Argument 3: timeout (float)
    Single line: one float
```

**Output Format:**

For each test case, print the result of `queue_under_budget()` on a new line.

**Sample Input:**

```
durations = [0.20, 0.20, 0.20, 0.20]
limit = 2
timeout = 0.30
```

**Sample Output:**

```
{'labels': {0: 'ok', 1: 'ok', 2: 'TimeoutError', 3: 'TimeoutError'}, 'served': 2}
```

**Note:** Every request here is well inside its own deadline on the wire — 0.20 s against 0.30 s. Two
of them miss anyway, and comparing each duration against `timeout` will not tell you which two. Start
each request's clock when it is dispatched, not when it gets a slot.

---

> **Internal — not shown to students**

**ML Function Descriptor Config:**

```
FUNCTION NAME: queue_under_budget
RETURN TYPE: Dictionary

ARGUMENTS:
1. durations → List of Floats
2. limit     → Integer
3. timeout   → Float
```

**Reference Solution:**

```python
import asyncio


def queue_under_budget(durations: list, limit: int, timeout: float) -> dict:
    async def _main():
        slots = asyncio.Semaphore(limit)

        async def request(index):
            async with slots:
                await asyncio.sleep(durations[index])
            return index

        async def guarded(index):
            try:
                await asyncio.wait_for(request(index), timeout=timeout)
                return "ok"
            except Exception as exc:
                return type(exc).__name__

        labels = await asyncio.gather(*(guarded(i) for i in range(len(durations))))
        return {"labels": {i: l for i, l in enumerate(labels)},
                "served": sum(1 for l in labels if l == "ok")}

    return asyncio.run(_main())
```

**Test Cases —** `in.txt`

```
3
4
0.2 0.2 0.2 0.2
2
0.3
6
0.1 0.1 0.1 0.1 0.1 0.1
1
0.35
3
0.1 0.4 0.2
5
0.3
```

**Test Cases —** `out.txt`

```
{'labels': {0: 'ok', 1: 'ok', 2: 'TimeoutError', 3: 'TimeoutError'}, 'served': 2}
{'labels': {0: 'ok', 1: 'ok', 2: 'ok', 3: 'TimeoutError', 4: 'TimeoutError', 5: 'TimeoutError'}, 'served': 3}
{'labels': {0: 'ok', 1: 'TimeoutError', 2: 'ok'}, 'served': 2}
```

**Grader Notes:**

- All three cases were **executed** and re-run **20 times** with byte-identical output (Python 3.12.13,
  standard library only).
- **This question exists because the obvious version of it is gameable.** An earlier draft dropped the
  semaphore and asked only for `wait_for` over independent calls; three lines of arithmetic
  (`"TimeoutError" if d > timeout else ...`) reproduced its expected output exactly on every case, with
  `asyncio` never imported. That draft was discarded. Putting the slot wait inside the budget is what
  makes the answer a property of the schedule rather than of the inputs — **do not simplify this
  question back toward per-call timeouts.**
- **Cases 1 and 2 are the closed-form killers and must not be dropped.** In both, *every* duration is
  strictly inside `timeout`, so `d > timeout` labels everything `"ok"`; the true answers have 2 and 3
  timeouts respectively, caused purely by queueing. Case 3 (`limit=5` > 3 requests) is the deliberate
  contrast: nothing queues, and there the closed form *does* agree — it is in the set to show the
  difference, never to carry the discrimination.
- **Timing margins.** Case 1: requests 2 and 3 get a slot at 0.20 s and would finish at 0.40 s against
  a 0.30 s deadline — a 0.10 s margin either side. Case 2 is the tightest: request 2 finishes at 0.30 s
  against a 0.35 s deadline and request 3 would finish at 0.40 s, so both margins are 0.05 s. That is
  ~50× the event-loop overhead and held over 20 runs, but case 2 is the first thing to re-check if this
  is ever moved to a slower grader.
- **`"TimeoutError"` is generated by the runtime, not authored by the learner**, so step 4 specifies the
  *operation* ("the name of the exception type, passed through unchanged") and does not enumerate the
  values — the same device as `M3-L1` Q1. The sample output shows the string against its inputs so a
  learner can still self-check. For the paper-setter: `"ok"` and `"TimeoutError"` are the complete label
  vocabulary across all three cases; nothing else appears.
- Since Python 3.11 `asyncio.TimeoutError` **is** the builtin `TimeoutError`, so `type(exc).__name__` is
  `"TimeoutError"` on 3.11+ regardless of which name the learner catches. On 3.10 and earlier the two
  were distinct classes but both were still named `TimeoutError`, so the graded string is unchanged.
  Pin ≥3.11 anyway, because that is what the rest of this file assumes.
- Wrong readings that were implemented and run:
  - **`wait_for` inside the `async with`** (budget starts when the slot is acquired) — everything is
    labelled `"ok"`. Fails cases 1 and 2, passes case 3. This is the single most likely wrong reading
    and the reason step 2 spells out what the deadline covers.
  - **No semaphore at all** — same symptom, everything `"ok"`. Fails cases 1 and 2, passes case 3.
  - **Closed form, `asyncio` never imported** — fails cases 1 and 2, passes case 3.
- All three wrong readings above fail on exactly the same two cases. That is expected — they are three
  spellings of the same misunderstanding (that a request's latency is its own duration) — but it does
  mean cases 1 and 2 are carrying the entire question. Do not reduce this question to a single case.
- **Relation to Q1.** Both use `asyncio.Semaphore`, deliberately. Q1 grades what the cap does to
  *ordering* with no deadlines in play; Q4 grades what the cap costs a caller who has one. The pair is
  the point: the same primitive that protects the provider is what blows the client's budget. A learner
  who solves Q1 has the semaphore but none of Q4's answer.
- Dictionary key order is not significant; compare `"labels"` by key.

---

## Verification summary

| | Q1 | Q2 | Q3 | Q4 |
|---|---|---|---|---|
| Test cases | 3 | 3 | 2 | 3 |
| Fresh runs, all byte-identical | 20 | 20 | 20 | 20 |
| Wrong readings implemented and run | 3 | 4 | 3 | 3 |
| Wrong readings that survived | 0 | 0 | 0 | 0 |
| Closed-form solution defeated by | case 2 (peak), cases 1+3 (order) | all 3 cases | both cases | cases 1+2 |

Environment: Python 3.12.13, standard library only — no third-party import in any reference solution.
Each `in.txt` was rendered, re-parsed by a harness that mimics the portal's argument parser, and run
again; all 11 cases reproduce their `out.txt` exactly with no unconsumed input lines. No reference
solution contains an `if __name__ == "__main__":` block.

**One environment note that affects the notebook, not the portal.** Every reference solution calls
`asyncio.run(...)`, which is correct for the portal's harness (a plain script, no running loop) and is
what the lecture teaches for `.py` files. It **cannot** be called from a Jupyter or Colab cell, which
already has a loop running — confirmed against a real kernel, where it raises
`RuntimeError: asyncio.run() cannot be called from a running event loop`. The companion notebook
therefore opens with a `nest_asyncio` setup cell. That cell is a notebook-only affordance: the graded
solutions are unchanged, and nothing about the portal configuration depends on it.
