# `caldon-wire` — Asynchronous Programming & Concurrency for AI (Module 3, Class 2)

A VM lab in which the learner writes the **concurrency layer** of a newsroom wire desk:
five async entry points over a live model endpoint, graded by executing them and reading
what the endpoint actually saw.

**Max Score 50 = 5 checks × 10.** Target image: "systemd Ubuntu" (Ubuntu 25.04 /
Python 3.13). No Docker required.

## Why this shape

The class teaches `async`/`await`, `gather`, `create_task`, `Semaphore`, `wait_for`,
cancellation, `return_exceptions`, per-task `try/except`, and async generators. Almost
none of that can be graded from the *return value* alone — a sequential loop and a
`gather` produce identical output, and a generator that buffers the whole reply before
slicing it produces identical text to one that streams.

So the endpoint is also the instrument. It counts every request in and out under a lock
and reports, per run: the **peak number of simultaneously open requests**, whether a
request was **abandoned mid-flight**, and whether a reply was **streamed**. Those three
numbers are what separate a correct async solution from a correct-looking synchronous
one, and none of them can be produced by a hand-faked result.

Concretely, the discriminating measurement for each theme:

- **Check 1** — peak in-flight equals the batch size (a sequential loop reports 1).
- **Check 2** — peak in-flight equals the semaphore limit *exactly*: above it the cap
  leaked, below it the queue ran narrower than allowed.
- **Check 3** — all six requests dispatched and overlapping, with two of them recorded
  as rejected by the desk, so a rejection neither cancelled nor serialised its siblings.
- **Check 4** — the desk recorded the long pull as **cut off while it was still holding
  the reply**, which only a real cancellation of a real in-flight request produces.
- **Check 5** — the desk was asked for a **stream**, and the pieces reached the caller
  spread across the second rather than all within a few milliseconds of each other.

## Layout

```
caldon-wire/
  problem-statement.md            learner-facing (no markdown tables — portal renderer)
  INSTRUCTOR-SETUP-GUIDE.md       portal config, the five checks, how to re-run the proofs
  VALIDATION.md                   every observed number, and the limits of this validation
  app/                            what the learner is given
    wire_kit/{client,feed,prompts}.py
    data/wire_feed.json           14 wire stories
    check_local.py                runs their five functions and prints the results
    solution_stub.py              installed as solution.py on a fresh VM
  service/wired.py                the wire desk (ships to /opt, root:root 0700)
  reference-solution/
    solution.py                   the model answer
    alt1_create_task.py           alternative shape — must also score 50/50
    alt2_taskgroup.py             alternative shape — must also score 50/50
    make_probes.py                generates the probes below from solution.py
    _defect{1..5}_*.py            each must lose exactly its own check
    _cheat_hardcode.py            never calls the desk — must score 0/50
    _cheat_sleep_deadline.py      fakes the deadline — must lose check 4 only
    _envprobe_numpy.py            imports numpy at module scope — must score 0/50
  test-cases/scripts/
    script_01..05.sh              the only files that ship in TestCase.zip
    common.sh, run-all.sh         local only, never shipped
  setup/
    setup_script.template.sh      the source; build.sh inlines app/ and service/ into it
    scripts/setup_script.sh       generated — do not hand-edit
  validation/
    permutations.sh               the ordering matrix (run as root)
    run-in-docker.sh              provisions a Linux container and runs the matrix in it
  build.sh                        regenerate setup + zips, enforce every invariant
  gen_tests.sh                    regenerate the five checks from one shared preamble
  sweep.sh                        grade all 11 candidates and assert each expected score
  dist/{Setup,TestCase}.zip       each carrying scripts/ AND data/ at the root
```

## Verification status

Observed, not reported — full detail and commands in [`VALIDATION.md`](VALIDATION.md):

- **Reference 50/50**, slowest check 3s against a ~120s cap.
- **Both alternative shapes 50/50** — `create_task` + shielded `wait_for` + a class, and
  `TaskGroup` + `gather(return_exceptions=True)` + `asyncio.timeout` + a shared client.
- **Every defect probe loses exactly its own check** (40/50), which is what makes a
  10-point script fair.
- **No route to marks without the event loop** — four attacks written and graded, not
  argued: coroutines-in-name-only with a blocking client **0/50**, real concurrency from a
  thread pool **0/50**, a deadline that leaves the call running **40/50**, hardcoded
  values **0/50**. Two of those found real holes and are the reason for the two hardenings
  below. `VALIDATION.md` §4 has the measurements.
- **Ordering matrix clean as root on Linux** — 7 rows, 23 assertions, zero root-owned
  files under the project in every row including partial and repeated grading.
- **Foreground setup 5s**; the dependency install is detached and does not count against
  the portal's status poll.

Unlike the Module 2 labs, the root-ownership invariant here was **not** left open: the
checks were run as root against a real `user` account in a Linux container, which is the
only configuration in which that assertion means anything. What remains unconfirmed is
the portal image itself — see `VALIDATION.md` §7.

## Two hardenings that came out of the attack pass

Both were added after a probe passed something it should not have, and both are in
`VALIDATION.md` §4:

- **The provided client identifies itself, and every check requires it.** The interface
  contract already said every model call goes through `make_async_client()`; before this
  it had no check behind it, so a thread pool with a hand-built blocking client scored
  40/50 on an asyncio lab.
- **Check 4 measures *when* the call was dropped, not just that it was.** A task nobody
  cancels still looks abandoned, because the socket closes when the process exits. The
  desk now reports how long it held the request that was dropped soonest: about the budget
  for a real cancellation (12 tenths), about the length of the program for a leaked task
  (32), threshold 20.

## One pin worth knowing about

Setup installs **`openai==2.54.0`** and never falls through to a bare `openai`. openai
3.x leaves its response stream suspended at loop shutdown, so every streamed reply is
followed by a multi-line traceback on stderr. It changes no score, but on a streaming
lab the learner would see it after every run. Measured on both 3.13 and 3.14;
`VALIDATION.md` §6 records what was tried and what did not work.
