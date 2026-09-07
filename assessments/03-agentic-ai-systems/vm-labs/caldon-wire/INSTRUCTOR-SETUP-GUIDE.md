# Instructor setup guide — `caldon-wire`

Module 3, Class 2 (Asynchronous Programming & Concurrency for AI). VM lab, graded by
five bash scripts that execute the learner's async code and read what the wire desk
actually saw.

## Portal configuration

| Field | Value |
|---|---|
| Setup file | `dist/Setup.zip` |
| Test case zip | `dist/TestCase.zip` |
| **Max Score** | **50** |
| Points per check | 10 (five checks) |
| Time Limit | 60 min is comfortable; the graded run itself takes under 15s |
| Duration | 90 min |
| Image | **"systemd Ubuntu"** — the Python image. No Docker needed. |

Do **not** pick the Alpine Docker image: this lab needs a CPython the `openai` wheel
resolves for, and it needs no container runtime at all.

## What the learner gets

A project at `/home/user/caldon-wire/` containing `wire_kit/` (the configured async
client, the feed reader, the four system prompts), `data/wire_feed.json` (14 wire
stories), `check_local.py`, and a `solution.py` stub with five `NotImplementedError`
bodies. A wire desk answering on `127.0.0.1:8794` is already running.

They write the five async functions in `solution.py` and nothing else.

## What the wire desk is

`/opt/caldon-svc/wired.py`, `root:root 0700`, started by the `caldon-wired` systemd
unit. It is an OpenAI-compatible chat endpoint over the standard library whose replies
are computed from the feed rather than sampled, so every value a check compares against
is fixed no matter what the network is doing. It also counts every request in and out
under a lock, which is how the checks know how many calls were open at once, whether a
call was abandoned mid-flight, and whether a reply was streamed.

Nothing about that is visible to the learner: the source is outside their home
directory and mode 700, and the problem statement describes only a port and a set of
prompts.

## The five checks

Each is one behavioural theme, all-or-nothing, 10 points. The failure message always
names which member of the cluster broke.

1. **`script_01`** — `summarise_batch` returns the right summaries in the right order,
   one call per story, with all of them open at the desk at once and the batch finishing
   in about the time of one call.
2. **`script_02`** — `rank_urgency` scores all seven graded stories exactly once and
   ranks them correctly, with peak in-flight **exactly** the limit it was given: over it
   means the cap leaked, under it means the queue was worked more slowly than allowed.
3. **`script_03`** — `gather_desk_notes` returns one entry per request in order, with the
   right note for each staffed desk and a non-empty failure record for each rejected one,
   all six dispatched concurrently.
4. **`script_04`** — `bulletin_under_deadline` returns the miss at the deadline for a
   long pull (and the desk records that call as cut off, so the deadline was placed on a
   real in-flight request), and returns the correct bulletin when the budget is generous.
5. **`script_05`** — `stream_bulletin` is a real async generator whose pieces arrive
   spread over time and join back into exactly the right bulletin.

## Running the proofs yourself

From the pack root, with an interpreter that has `openai` installed:

```bash
./build.sh                                  # regenerate setup + zips, enforce invariants
PY=/path/to/python ./sweep.sh               # grade all 11 candidates, assert each score
./validation/run-in-docker.sh               # setup + ordering matrix, as root on Linux
PY=/path/to/python bash test-cases/scripts/run-all.sh   # grade one candidate
```

`build.sh` refuses to produce zips if any invariant is broken: more than five check
scripts, a check missing its time budgets or its ownership hand-back, an apostrophe
inside a Python heredoc, drift in the shared preamble, a markdown table in the problem
statement, a graded story that also appears in the statement, or a provided source file
that mentions how the lab is graded.

Observed results are recorded in `VALIDATION.md` — reference 50/50, every alternative
shape 50/50, every defect losing exactly its own check, and a 7-row ordering matrix clean
as root with zero root-owned files.

`VALIDATION.md` §4 answers the question this lab has to survive — *can it be passed
without async?* Four attacks were graded rather than reasoned about: a fully synchronous
solution returning every correct value scores **0/50**; a thread pool with a hand-built
blocking client scores **0/50**; a deadline that returns on time but leaves the call
running scores **40/50**; hardcoded values score **0/50**. The last two of those started
at 40/50 and 50/50 respectively and are the reason for the two hardenings noted below.

## Regenerating after an edit

- Edited `app/`, `service/` or the setup template → `./build.sh`
- Edited a check or a graded input → `./gen_tests.sh` then `./build.sh`
- Edited `reference-solution/solution.py` → `python3 reference-solution/make_probes.py`
  then `./sweep.sh`, since the probes are derived from it

`TEST_LOGGING=on ./gen_tests.sh` rebuilds the checks with per-check logs under
`/tmp/caldon-lab-logs/` for a debugging session. Ship with logging off.

## If something goes wrong on a real VM

Ask for state rather than a description:

```bash
cat /var/log/caldon-lab/setup-status      # how far setup got, and any warnings
tail -40 /var/log/caldon-lab/setup.log    # which rung of which ladder fired
cat /var/log/caldon-lab/deps.state        # pinned | series | failed
tail -20 /var/log/caldon-lab/pip.log      # the detached install
cat /tmp/caldon_timing.log                # per-check wall time
curl -s 127.0.0.1:8794/health             # is the wire desk up
find /home/user/caldon-wire -user root    # must print nothing
```

The most likely single failure is the detached dependency install: if
`deps.state` says `failed`, the checks report the missing `openai` package rather than
scoring zero silently, and the learner should be moved to a fresh VM.

## Two assertions that look incidental and are not

- **Every check requires that the run calls came through `make_async_client()`.** Without
  it, a `ThreadPoolExecutor` and a hand-built sync client scores 40/50 on an asyncio lab,
  and the contract sentence in the problem statement has nothing enforcing it. If you ever
  loosen this, re-grade `_cheat_threads.py`.
- **Check 4 asserts how long the desk held the dropped call**, not merely that it was
  dropped. The socket closes when the learner process exits, so a task nobody cancelled
  looks identical to a cancelled one unless the *timing* is checked. If you shorten the
  1.6s tail wait in that check, the two collapse back together — re-grade
  `_cheat_leaked_task.py` after any change there.

## Dependency pin — do not "tidy" it

Setup installs **`openai==2.54.0`**, falling back to `openai<3` and never to a bare
`openai`. openai 3.x emits a multi-line asyncgen traceback on stderr after every
streamed reply. It does not change any score, but this is a streaming lab and the
learner would see that traceback after every run of `check_local.py`. The full
measurement is in `VALIDATION.md` §6.
