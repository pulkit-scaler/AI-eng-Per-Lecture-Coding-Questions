# Validation record — `caldon-wire`

Everything below is an observed number from a run on this pack, not an estimate. The
commands that produce each block are named so any of it can be re-run.

Two interpreters were used deliberately: **Python 3.13.13** (what the target image
ships) and **Python 3.14.6** (the authoring machine), because an async lab is exactly
the kind that drifts between minor versions.

## 1. Load-bearing mechanics, proven before the pack was written

The whole lab rests on the wire desk being able to *observe* concurrency. That was
spiked first, against a throwaway server, so no time was spent building on an
assumption:

- **Unbounded fan-out of 5** — desk recorded peak in-flight **5**.
- **Sequential loop of 3** — peak **1**. Clean separation from the above.
- **Semaphore capped at 3 over 7 tasks** — peak **exactly 3**, every run.
- **`asyncio.wait_for` cancellation** — the request *arrives* at the desk, the desk
  detects the hang-up and releases at **1.00s** instead of holding its full 4.0s, and
  records the request as cut off.
- **SSE streaming** — 8 chunks arriving spread over **0.85s**, recorded as a streamed
  request.

All five are the assertions the checks are built on, so none of them is inferred.

## 2. Reference solution — full marks

    PY=<python-with-openai> bash test-cases/scripts/run-all.sh

    SCORE: 50/50   (passed 5, failed 0)
    slowest test case: 3s   (portal limit is ~120s)

Per-check wall time, measured **as root inside the Linux container** and read back from
`/tmp/caldon_timing.log`:

    script_01 1s
    script_02 2s
    script_03 1s
    script_04 3s
    script_05 1s

`script_04` is the slowest because it deliberately spends 1.2s missing a deadline and
then makes a second, successful call. Worst case if every bound in the preamble were hit
is about 90s, against a cap of roughly 120s.

## 3. Candidate sweep — every shape scores exactly what it should

    PY=<python-with-openai> ./sweep.sh

All **15** candidates are graded, each on its own port and its own lab directory, so no
run can see another:

- `solution.py` — **50/50**
- `alt1_create_task.py` — **50/50** (create_task throughout, a class for the desk, a
  client per call, `wait_for` over a shielded task)
- `alt2_taskgroup.py` — **50/50** (`asyncio.TaskGroup`, `gather(return_exceptions=True)`,
  `asyncio.timeout`, a module-level shared client)
- `_defect1_sequential_batch.py` — **40/50**, loses **01 only**
- `_defect2_no_semaphore.py` — **40/50**, loses **02 only**
- `_defect3_bare_gather.py` — **40/50**, loses **03 only**
- `_defect4_no_deadline.py` — **40/50**, loses **04 only**
- `_defect5_buffered_stream.py` — **40/50**, loses **05 only**
- `_cheat_sleep_deadline.py` — **40/50**, loses **04 only**
- `_cheat_hardcode.py` — **0/50**
- `_cheat_allsync.py` — **0/50** (see §4, attack A)
- `_cheat_threads.py` — **0/50** (see §4, attack B)
- `_cheat_leaked_task.py` — **40/50**, loses **04 only** (see §4, attack C)
- `_probe_loop_per_thread.py` — **50/50**, deliberately (see §4, probe E)
- `_envprobe_numpy.py` — **0/50**

The "loses its own theme and nothing else" column is what makes a 10-point script fair:
a learner who gets four themes of five loses 10 points, not 50.

Two of those deserve naming:

- **`_cheat_hardcode.py`** returns correctly-shaped values copied from a real run and
  never calls the desk. It scores zero on all five, because every theme asserts
  something only a real round trip produces.
- **`_defect5_buffered_stream.py`** returns the *right text* in the *right number of
  pieces* — it just reads the whole reply first and then cuts it up. It loses only
  check 5, on the two members that separate streaming from slicing: the desk was never
  asked for a stream, and every piece reached the caller within milliseconds of the
  first.

The defect and bypass probes are **generated** from the reference by
`reference-solution/make_probes.py`, so each differs from it by exactly one function.
A probe losing more than its own check is therefore a grader bug, not a difference
between two hand-written files.

## 4. Can it be passed without async? — four attacks, run not reasoned

The question this lab has to survive is whether a learner who never uses `asyncio` can
still return the right values and score. Four attacks and one probe were written and graded. Two of the attacks found real holes,
which were then closed; the probe passes on purpose.

**Attack A — coroutines in name only.** Five `async def` functions whose bodies use a
blocking client, one call after another. Every returned value is correct.

    0/50 — every check fails, and each names the missing concept:
      01  never more than 1 of the 5 requests open at once
      02  never more than 1 call open against a limit of 3
      03  a rejection stopped the rest from running alongside it
      04  the pull that could not finish in 1.2s was reported as a success
      05  the desk was never asked for a streamed bulletin

**Attack B — real concurrency, from threads.** A `ThreadPoolExecutor`, a
`threading.Semaphore` for the cap, and `future.result(timeout=...)` for the deadline.
This is the strongest honest attack: threads *are* concurrency, and the returned values
and observed overlap are genuinely correct.

Graded **40/50 before hardening** — it lost only check 4, because a `concurrent.futures`
future cannot be cancelled once it is running, so the request stayed open at the desk.
That single loss is a real property, not an accident: cooperative cancellation is the one
thing threads cannot do here.

40/50 was still too generous for a solution that never touches the event loop, and it
also meant a stated part of the interface contract — *every model call goes through
`make_async_client()`* — had **no check behind it**. Closed: the provided client now
identifies itself, and every check requires that all calls for its run came through it.
Attack B now scores **0/50** with a message naming the contract in every check.

**Attack C — the deadline nobody honours.** The reference, with check 4 replaced by
`asyncio.wait([task], timeout=budget)` that returns the miss and **leaves the task
running**. Nothing is cancelled.

Graded **50/50 before hardening** — a genuine hole. The desk did record the call as cut
off, but only because the socket closed when the *process exited*, not because anything
was cancelled. Closed: the desk now reports how long it held the request that was dropped
soonest, and check 4 requires that to be near the budget. Attack C now scores **40/50**:

    the wire desk went on holding the reply for wf-3159 for 3200ms - far past the
    1.2s deadline - so the call was never actually dropped, it just ended when the
    program did

Measured separation: **12 tenths** for a real `wait_for` cancellation against **32** for a
leaked task, with the threshold at 20.

**Probe E — one event loop per thread, through the provided client.** Threads again, but
each worker calls `asyncio.run()` on a real coroutine that uses `make_async_client()`, and
the deadline is a genuine `asyncio.wait_for`. This is the construction that routes around
both hardenings, so it was graded deliberately rather than left as an unknown.

**50/50 — and that is the right answer, not a hole.** Check 4 reports the desk stopping at
**1100ms**, which is a real cooperative cancellation, not a process exit. This solution
uses coroutines, `await`, the provided async client, `wait_for` cancellation and a real
async generator; it simply drives the fan-out with a thread pool instead of `gather`. Every
learning objective except "use these two specific primitives" is demonstrated, and the core
rule for this platform is to grade behaviour, not construction — *many valid solutions must
score full marks*.

Note how far it is from attack B, which scores zero: B used **no** asyncio at all, a
blocking client and no cancellation. E is asyncio throughout, with threads as an unusual
driver. Closing E would mean asserting that every call came from one event loop, which is
not observable from outside and would start failing legitimate solutions. It is also
strictly more work to write than `gather`, so it is nobody's shortcut.

**Attack D — hardcoded values.** Correctly-shaped return values copied from a real run,
no calls at all. **0/50**, unchanged.

### What this leaves

A solution scores full marks only if, for each theme, the *event loop* did the work:
the calls overlapped, the cap held at exactly its width, a rejection stayed contained
while its siblings ran, an in-flight request was cancelled at its deadline, and the
pieces arrived spread over time from a real stream. None of those five is reachable by
returning the right values, by blocking, or by threads driving a blocking client. Threads
driving *real coroutines through the provided client* do pass, and should — see probe E.

What no grader can prevent is deliberate forgery: `wire_kit/client.py` is readable by the
learner, so its identifying header could be copied into a hand-built client. That is a
different category from an honest wrong approach — it requires knowingly impersonating the
provided client — and it is stated here rather than papered over.

## 5. Ordering matrix — run as root on Linux

    ./validation/run-in-docker.sh

This is the part a macOS authoring box cannot settle on its own, so it is not left
open. The container is `ubuntu:25.04` (the release the target image actually runs) with
**no pip, no curl and no jq preinstalled and the apt index stripped**, so setup has to
climb its own dependency ladder rather than skipping it. The checks run **as root**
while the lab user is `user`, which is the only configuration in which the ownership
assertions mean anything.

7 rows, 23 assertions, all held:

- wrote the solution, ran it, full grading → **50**
- wrote the solution, never ran it, full grading → **50**
- untouched starter, full grading → **0** (refused with a message, not a timeout)
- no `solution.py` at all → **0**, project intact
- partial grading, killed after 3 checks → **30**
- graded twice in a row → **50** then **50**, learner able to work in between
- graded first, learner then works, graded again → **0**, then **50**

Every row also asserted **zero root-owned files under the project** and that the
learner could still run their own work afterwards. Both held in all seven, including
the partial-grading row that normally exposes an ownership bug a full run hides.

## 6. Provisioning

Measured in the container described above:

- **Foreground setup: 5s.** That is what the portal's status poll waits on, and it is
  the number that decides whether the lab loads on the first attempt.
- **Detached dependency install: ready after 46s**, state `pinned`, warm-up completed.
  This runs *after* provisioning has already returned, so it never counts against the
  poll. The 46s includes a full apt index refresh that the real image does not need.
- Nothing under `/home/user/caldon-wire` was root-owned at any point.
- The wire desk answered `/health` at the end of setup.

Note the container has no systemd, so this run exercised the **nohup fallback** path for
starting the desk rather than the unit-file path. Both are in the setup script; the
systemd path is the one the real image will take, and it is the less risky of the two.

## 7. Dependency pin — why `openai==2.54.0` and not 3.x

This is the one finding that changed a design decision, so it is recorded rather than
left as an unexplained pin.

`openai` 3.x moved onto a new transport (`httpx2`/`httpcore2`). After a streamed
response completes, its byte-stream generator is still suspended when the event loop
shuts down, so `asyncio.run()` finalises it and the cleanup raises. The result is a
**16–36 line traceback on stderr after every streamed reply**, ending in
`RuntimeError: generator didn't stop after athrow()`.

Measured across repeated runs on **both** 3.13 and 3.14:

- `openai==3.1.0` — 16–36 stderr lines per streamed run, **rc=0**, correct results.
- `openai==2.54.0` (httpx 0.28) — **0 stderr lines**, correct results.

It never changes a verdict: the checks read a `LABJSON:` line from stdout and the exit
code stays 0. It was fixed anyway because the *learner* sees it — `check_local.py` would
end every run with a traceback that looks like a bug in their own code, and that is a
support ticket per learner.

Two other fixes were tried first and did **not** help, so they should not be re-attempted:
closing the SDK stream explicitly with `async with`, and switching the endpoint from a
close-delimited body to chunked transfer-encoding. The chunked change was kept anyway,
because an event stream genuinely has no length to declare up front.

The setup script's ladder is therefore `openai==2.54.0` → `openai<3` → fail. **It never
falls through to a bare `openai`**, because that would silently reinstate the problem.

## 8. Known limits of this validation

- The real portal image was **not** available to this author. The container stands in for
  it on OS release, interpreter version and the absence of pip/curl/jq, but it is not the
  image itself. Anything image-specific — the exact systemd unit behaviour, the portal
  front end's polling window — is still worth one confirming run before the first cohort.
- `setup_script.sh` has not been run under **systemd**; the container took the nohup
  fallback. The unit file is the same shape as the three Module 2 labs already running on
  this platform.
- The published problem statement quotes timings ("about half a second", "about a
  second") that are properties of the wire desk and will hold, but the *absolute* numbers
  a learner sees on a loaded two-core VM may be slightly higher. Every graded threshold
  has margin for that: the fan-out check allows one call off the peak, and the streaming
  spread threshold is 0.4s against an observed 1.0s.
