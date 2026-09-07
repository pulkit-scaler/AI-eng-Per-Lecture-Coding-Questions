# Validation Record — Ashford Grid

Everything below was **executed**, on the authoring host, with the numbers copied from the runs. The
last section states plainly what could not be validated off-VM.

This record was rewritten during the 2026-09-02 review pass. Claims from the previous record that
the pass **disproved** are corrected in place and flagged, rather than deleted.

## What was executed, and where

Host: macOS (darwin 25.5.0), Python **3.13.13** in a clean venv with the pack's pinned dependency
installed from PyPI: **`openai==3.1.0`**.

```bash
./gen_tests.sh
./build.sh
PY=<venv>/bin/python ./test-cases/scripts/run-all.sh                     # -> 50/50
PY=<venv>/bin/python PORT_BASE=9300 ./sweep.sh                           # the candidate matrix
PY=<venv>/bin/python PORT=9330 ./validation/permutations.sh              # the ordering matrix
PATH=<venv>/bin:$PATH ./setup-timing.sh                                  # setup foreground
```

`run-all.sh` assembles a scratch lab directory from `app/` plus a candidate `solution.py`, seeds
`data/grid_ops.db` with `service/seed_db.py`, starts `service/gridd.py`, runs `script_01..05` in
order and tallies at 10 points each. Each candidate is graded **on its own port with its own lab
directory**, so no run can be answered by an endpoint another run started. `run-all.sh` `cmp`s the
assembled `$LAB_DIR/solution.py` against the file named in `SOLUTION` and aborts with
`WRONG-FILE-GRADED` if they differ.

`sweep.sh` defaults to `PORT_BASE=9300`. It previously defaulted to 9200, which collided with a
sibling lab graded concurrently; two labs on one port silently answer each other's health checks and
produce a green run that proves nothing.

## Gate 0 — judge fidelity (the live production bug this pass fixed)

### What was wrong

The platform's `/usr/local/bin/judge/test/common.sh` ends with

    trap 'handle_script_error $LINENO $? "$BASH_COMMAND"' ERR

so the trap is installed **inside the check's own shell**. Its handler prints `INTERNAL_ERROR: ...`
and exits. `main.sh` grades `tail -n 1` of stdout plus stderr, so that second line discards the
verdict, the run reports `evaluated: false`, and the learner sees an **empty "Test Case Results:"
panel with no rows at all**.

Before this pass, `grep -c 'trap - ERR'` and `grep -c 'exec 2>>'` were **0 in all five checks**, and
`test-cases/scripts/common.sh` was a six-line convenience stub (`echo "RESULT:$1 | $2"`) with no
`jq` and no ERR trap. That stub is why local validation had never seen the bug.

### The negative control, executed

`test-cases/scripts/common.sh` is now a faithful replica, copied from
`03-agentic-ai-systems/vm-labs/caldon-wire`. Its body below the header comment is byte-identical to
caldon-wire's (`diff` on lines 11 onward: no output).

Removing `trap - ERR` and `set +eE` from `script_02.sh` and running it on an environment-fault path,
with the faithful `common.sh` sourced:

```
$ LAB_DIR=/tmp/ash-empty SVC_URL=http://127.0.0.1:9353 bash test-cases/scripts/zz_unmigrated.sh
{ "status": "failed", "message": "The model endpoint is not answering on http://127.0.0.1:9353/health, ..." }
INTERNAL_ERROR: An error occurred at line 350: 'return' exited with status '1'
```

The migrated check, same path, same environment:

```
$ LAB_DIR=/tmp/ash-empty SVC_URL=http://127.0.0.1:9353 bash test-cases/scripts/script_02.sh
{ "status": "failed", "message": "The model endpoint is not answering on http://127.0.0.1:9353/health, ..." }
```

One line, and it is the verdict.

Through the fixed harness, with the unmigrated `script_02.sh` in place and the untouched starter as
the submission:

```
  [FAIL] script_01.sh       0s  /tmp/ash-neg2/solution.py is still the untouched starter - write the five functions, ...
  [!!!!] UNPARSEABLE script_02.sh   1s
         The LAST line of this check is not a verdict, so the portal would
         discard the verdict entirely and report this submission as having NO
         TEST CASE RESULTS AT ALL - an empty panel, not a failed row.
         Last line was: INTERNAL_ERROR: An error occurred at line 350: 'return' exited with status '1'
...
[!!!!] VERDICT-STREAM INVARIANT BROKEN: script_02.sh:stdout=2lines
```

**This was not theoretical for this pack.** The path that reproduces it is
`preflight || return`, which makes `Test<NN>` return 1 and fires the trap at the top level. Every
environment-fault and refusal path went through it: the untouched starter, a missing `solution.py`,
a missing dependency, an endpoint that is down, an unreadable expected value. The **untouched
starter is the single most common learner ordering**, and on the portal it would have shown an empty
panel instead of the message telling them what to do.

### What was changed

- **`common.sh`** replaced with the faithful replica: `jq -n` JSON output, an exiting
  `handle_internal_error`, and the ERR trap.
- **The generator's shared preamble** gained `trap - ERR`, `set +eE`, and, inside the logging block
  after `TC=` is computed, `exec 2>>"/tmp/ashford_tc${TC}.err"`. Patched in `gen_tests.sh` and
  regenerated, never hand-edited, so `build.sh`'s "preamble identical across all five" assertion
  still holds.
- **`run-all.sh`** now grades the way `main.sh` does: the **last** line of the captured output,
  parsed as JSON, read at `.status`, with a legacy `RESULT:` branch that is also last-line-based. A
  last line that is neither gets a loud `[!!!!] UNPARSEABLE` branch whose text says the portal would
  report no test cases at all.
- **The single-line invariant is now asserted** (P0f). `run-all.sh` runs each check once with the
  two streams kept apart, and reports a check that printed anything other than exactly one stdout
  line and zero stderr lines. Both the pass path and the fail path were checked for all five, on
  every candidate in the matrix: `verdict stream: every check printed exactly 1 stdout line and 0
  stderr lines`.
- **`build.sh`** refuses to ship a check missing `trap - ERR`, `set +eE` or `exec 2>>`, or one that
  gates ownership on `LAB_DIR`, or one that still splices `trace_hint`, or a `common.sh` that is not
  a faithful replica.
- **`validation/permutations.sh`** was grading with `grep -q '^RESULT:success'`, which the faithful
  `common.sh` no longer emits, so **every row would have read 0**. It now parses the last line as
  JSON and asserts `checks with a voided verdict == 0` on every row.

### Prefix scoring: a claim the previous record got wrong

`main.sh` `break`s at the first failing case, so the score is a **prefix**, not a per-theme sum. The
previous record's rows read "40/50 (TC01 only)" for `_defect1`, which is **not** the score a learner
would receive: failing check 1 means checks 2 to 5 never run, so the portal awards **0/50**.

`run-all.sh` and `sweep.sh` now print both numbers, so this cannot be misread again. `SCORE` is the
per-theme total from running all five; `PORTAL` is the leading run of passes.

**Why the check order is right.** TC01 grades `critique_query`. TC02 grades the loop built on top of
it, so a broken `critique_query` cannot be diagnosed from TC02 first. TC03 grades the same
draft-and-repair shape driven by execution rather than review. TC04 and TC05 are independent of the
first three and sit last. A learner working the tasks in order therefore earns a prefix that tracks
their progress, which the permutation matrix pins: Tasks 1 and 2 finished scores exactly 20.

### Ownership repair: gated on the wrong thing

Every check had `case "$LAB_DIR" in /home/user/*) chown -R user:user ...`, and **every local harness
runs with `LAB_DIR=/tmp/...`**, so the one line written to stop a learner being locked out of their
own project never fired in the only environment that tests it. It is now gated on
`id -u user >/dev/null 2>&1`, with the `case` kept purely to refuse an empty or `/` value so a
mis-set variable cannot reach the filesystem root. `permutations.sh` greps for `id -u user` in all
five checks.

### `curl` and `jq`

Both were installed **only by the detached dependency job**, not by the setup foreground. A check
starting before that job finished had no `curl`, so `ensure_service`'s health probe failed and the
check reported "the model endpoint is not reachable" — the wrong diagnosis for a missing tool. `jq`
is load-bearing on both sides: the platform's `print_status` builds its line with `jq -n`, and every
expected value is read with `jq -r`.

Now: the setup **foreground** guarantees both with one bounded `apt-get` attempt, taken only when
`command -v` says they are missing, and the detached job still retries them idempotently for the
case where the foreground lost a dpkg lock. Measured on this host, where both are already present:
`OK have python3 / OK have curl / OK have jq`, and the foreground wall clock did not move (see Gate
5).

No check uses "curl and jq exist" as a proxy for "the pip install finished". `ensure_deps` gates on
the `deps.ready` sentinel, falls back to an `import openai` probe, and only after that wait does
`ensure_tools` look at the binaries, reporting a missing one as an **environment fault naming its
install log**.

## Gate 1 — build guards

`./build.sh`, in full:

```
=== [1/5] expanding setup template ===
  inlined 11 source files
  setup_script.sh syntax OK
=== [2/5] checking shared source blocks ===
  shared:formatter  matches between app/grid_kit/tools.py and service/gridd.py (26 lines)
  shared:desks      matches between app/grid_kit/handlers.py and service/gridd.py (46 lines)
  all 5 dispatch markers present in the provided prompts
  guard names agree between the toolkit and the endpoint
=== [3/5] checking test scripts ===
  common.sh is a faithful replica (ERR trap, internal-error exit, jq output)
  no apostrophes inside any python heredoc body
  the shared preamble is identical across all 5 scripts
  5 test scripts syntax OK, each with a bounded time budget
=== [4/5] staging zips ===
=== [5/5] verifying zip contents ===
-- Setup.zip
     scripts/
     scripts/setup_script.sh
     data/
-- TestCase.zip
     scripts/
     scripts/script_01.sh … script_05.sh
     data/
  provided sources and the statement are clean

done. Max Score = 5 x 10
```

### A live race in `build.sh`, found and fixed

`build.sh` **failed** on the first run of this pass with

```
ERROR: dist/TestCase.zip has no scripts/ folder
```

immediately after printing a listing that contained `scripts/`. The cause is the shape the brief
warns about: `unzip -Z1 "$z" | grep -q '^scripts/$'` under `pipefail`. `grep -q` exits at the first
match, SIGPIPEs `unzip`, and `pipefail` reports the whole pipeline as failed. Setup.zip passed in the
same run because `unzip` had less left to write. Both checks now capture the listing once and match
against a here-string. This was an intermittent build failure on correct input, not a bad zip.

### Verified in the staged artifacts, not only in the sources

```
$ unzip -Z1 dist/TestCase.zip | grep -cE 'common\.sh|run-all\.sh|\.DS_Store'
0
$ cd /tmp/ziptest && unzip -q .../dist/TestCase.zip && for f in scripts/script_0*.sh; do ... done
scripts/script_01.sh  trapERR=1 set+eE=1 exec2=1 idu=1 run_evidence=3
scripts/script_02.sh  trapERR=1 set+eE=1 exec2=1 idu=1 run_evidence=3
scripts/script_03.sh  trapERR=1 set+eE=1 exec2=1 idu=1 run_evidence=3
scripts/script_04.sh  trapERR=1 set+eE=1 exec2=1 idu=1 run_evidence=3
scripts/script_05.sh  trapERR=1 set+eE=1 exec2=1 idu=1 run_evidence=3
```

Both zips carry `scripts/` and `data/` at the root. `TestCase.zip` smuggles neither `common.sh` nor
`run-all.sh`.

Statement guards: `grep -c '—' problem-statement.md` → **0**. `grep -c '^|' problem-statement.md` →
**0**. A scrub of `app/**/*.py` for *lecture, course, class, grading, grader, mock, canary, sentinel,
oracle* → no hits. `compileall` over `app/`, `reference-solution/` and `service/` → clean.
`bash -n` over all 14 shell scripts in the pack → clean.

## Gate 2 — the candidate matrix

**Two full back-to-back sweeps on different port bases, 9300 and 9330. Every SCORE and PORTAL cell
agreed, row for row.** Reproduce with `PY=<venv>/bin/python PORT_BASE=9300 ./sweep.sh`.

```
CANDIDATE                                SCORE    PORTAL   WORST   FAILED
-------------------------------------------------------------------------------------------------
solution_stub.py                         0/50     0/50     1s      script_01..05
solution.py                              50/50    50/50    2-3s
alt1_class_agent.py                      50/50    50/50    2-3s
alt2_map_and_json_mode.py                50/50    50/50    2-3s
alt3_futures_wait_recursive.py           50/50    50/50    2-3s
alt4_two_roles_tuples.py                 50/50    50/50    2-3s
alt5_partial_and_multiturn.py            50/50    50/50    2-3s
alt6_raw_threads_queue.py                50/50    50/50    2-3s
alt7_default_pool_dictcomp.py            50/50    50/50    2-3s
_defect1_critique_executes.py            40/50    0/50     2-3s    script_01
_defect2_runs_rejected.py                40/50    10/50    2-3s    script_02
_defect3_drops_error.py                  40/50    20/50    2-3s    script_03
_defect4_ifchain_routing.py              40/50    30/50    2-3s    script_04
_cheat_no_critique_forward.py            40/50    10/50    2s      script_02
_cheat_sequential_guards.py              40/50    40/50    6-7s    script_05
_cheat_two_workers.py                    40/50    40/50    3-4s    script_05
_cheat_hardcode.py                       0/50     0/50     1s      script_01..05
_cheat_no_endpoint.py                    0/50     0/50     1s      script_01..05
```

### The before and after matrix

The baseline was taken **before any edit**, with the same interpreter and the same port base, and it
matched the previous record exactly. Every SCORE cell is unchanged by this pass. The PORTAL column
is new, and it is the column that corrects the previous record's reading of the defect rows.

```
CANDIDATE                          BEFORE (SCORE)   AFTER (SCORE)   AFTER (PORTAL)
------------------------------------------------------------------------------------
solution_stub.py                        0/50             0/50            0/50
solution.py                            50/50            50/50           50/50
alt1_class_agent.py                    50/50            50/50           50/50
alt2_map_and_json_mode.py              50/50            50/50           50/50
alt3_futures_wait_recursive.py         50/50            50/50           50/50
alt4_two_roles_tuples.py               50/50            50/50           50/50
alt5_partial_and_multiturn.py          50/50            50/50           50/50
alt6_raw_threads_queue.py              (new)            50/50           50/50
alt7_default_pool_dictcomp.py          (new)            50/50           50/50
_defect1_critique_executes.py          40/50            40/50            0/50
_defect2_runs_rejected.py              40/50            40/50           10/50
_defect3_drops_error.py                40/50            40/50           20/50
_defect4_ifchain_routing.py            40/50            40/50           30/50
_cheat_no_critique_forward.py          40/50            40/50           10/50
_cheat_sequential_guards.py            40/50            40/50           40/50
_cheat_two_workers.py                  (new)            40/50           40/50
_cheat_hardcode.py                      0/50             0/50            0/50
_cheat_no_endpoint.py                   0/50             0/50            0/50
```

Nothing moved. The judge-fidelity migration, the diagnostics rewrite, the statement rewrite and the
reference alignment all left every verdict where it was.

### What each correct alternative proves

Seven materially different shapes, all at full marks. Different means different topology, not
renamed variables.

- **`alt1_class_agent`** — one stateful class holding the error memory, with the five callables as
  delegates, and **no system message at all**: the role prompt is folded into the user message. The
  strongest structural probe in the set, because it proves the contract is about behaviour rather
  than message roles.
- **`alt2_map_and_json_mode`** — `response_format={"type": "json_object"}` on every structured turn,
  regex unfencing, `pool.map` for the fan-out (results in submission order), and the repair feedback
  assembled in the reverse order to the reference.
- **`alt3_futures_wait_recursive`** — the review loop as recursion with a countdown,
  `futures.wait(ALL_COMPLETED)` for the fan-out, dispatch built by stripping `handle_` off a
  registry dict.
- **`alt4_two_roles_tuples`** — evaluator and optimizer as two objects with **two separate
  clients**, error memory kept as tuples and converted only on the way out, and the candidate
  sequence exposed as a **generator** the caller stops consuming.
- **`alt5_partial_and_multiturn`** — **three-message** conversations (system, an assistant
  acknowledgement, then the user body), the schema assembled per table, and the fan-out over
  `functools.partial` objects into a pool sized `len+1`.
- **`alt6_raw_threads_queue`** (added this pass) — **no `concurrent.futures` at all**: raw
  `threading.Thread` plus `queue.Queue`. Added because the statement previously *required*
  `concurrent.futures` while the check only measures overlap, so a learner using raw threads was
  correct by the check and in breach of the statement. The statement now says either route is fine,
  and this row proves it.
- **`alt7_default_pool_dictcomp`** (added this pass) — `ThreadPoolExecutor()` with **no
  `max_workers`**, which is the shape a learner writes first. Added because the concurrency
  assertion had never been tested against a default-sized pool.

### What each probe proves

- **`_defect1_critique_executes`** — the review step runs the candidate it just approved. TC01 reads
  the audit trail, which is empty for a correct submission, so it catches the peek. 40/50 through the
  harness, **0/50** on the portal.
- **`_defect2_runs_rejected`** — every candidate is executed, whatever the review said. TC02 requires
  **zero** failed executions, so the rejected draft betrays it.
- **`_defect3_drops_error`** — the repair request carries neither the database error nor the memory,
  so the same query comes back and the retry fails identically.
- **`_defect4_ifchain_routing`** — the classification is still requested and then thrown away for an
  if-chain over words from the published samples. The graded requests contain none of those words.
- **`_cheat_no_critique_forward`** — the loop is correct and bounded but asks for a repair without
  saying what the reviewer objected to, so it burns its whole budget without converging.
- **`_cheat_sequential_guards`** — every guard is asked and the aggregate verdict is right; the calls
  do not overlap. Measures 10 tenths against a required 25.
- **`_cheat_two_workers`** (added this pass) — a pool with **two** workers. The guards *do* overlap,
  in pairs, and it still loses TC05 at 20 tenths. This probe exists to pin the boundary the check
  actually draws, which the statement's Requirements now state in the same terms.
- **`_cheat_hardcode`** — every value published in `problem-statement.md` and `check_local.py` pasted
  in. **0/50.** Re-run after the statement rewrite: still exactly 0/50.
- **`_cheat_no_endpoint`** — the whole layer reimplemented locally with hand-written rules over the
  real schema, so many of its returned values are correct. It loses all five checks on the round
  trips it skipped. This is the probe that proves the checks grade the agent, not the answer.

## Gate 3 — the ordering matrix

`PY=<venv>/bin/python PORT=9330 ./validation/permutations.sh` → **PERMUTATIONS PASSED**, all 37 assertions, 0 failures.
Every row asserts the intended score, that no check produced a voided verdict, that no file under
the project is owned by anyone but the learner, and that the learner can still run their own program
afterwards.

```
### the ownership guard is present in every check
    ok    checks missing an ownership guard      0
    ok    checks missing a judge-fidelity guard  0
### wrote the solution, ran it first, graded     score 50   voided 0   ownership 0   can work yes
### wrote the solution, ran NOTHING, graded      score 50   voided 0   ownership 0   can work yes
### wrote NOTHING (untouched starter), graded    score  0   voided 0   ownership 0
### no solution.py at all, graded                score  0   voided 0   ownership 0
### finished Tasks 1 and 2 only, graded          score 20   voided 0   ownership 0   can work yes
### a solution that does not import, graded      score  0   voided 0   ownership 0
### PARTIAL grading (killed after check 3)       score 30   voided 0   ownership 0   can work yes
### graded TWICE (a repeat submission)           50 then 50, voided 0 and 0, ownership 0, can work yes
### graded FIRST, learner then worked, graded again  50, can work yes, 50
### a broken first attempt replaced by a good one    50
```

Two rows deserve comment:

- **"ran NOTHING" still scores 50.** That is the intended design. The checks execute the learner's
  functions themselves, so there is no recorded state to be missing. The statement still tells the
  learner to run their program, because a `solution.py` that has never been executed has never been
  through even one round trip, but they are not penalised for the ordering.
- **The refusal paths are instant and diagnostic, and now they survive the judge.** The
  untouched-starter and missing-file refusals are the two paths that were being voided by the ERR
  trap. The `voided 0` cells on those rows are the assertion that closes it, and they were failing
  before the migration.

**The honest limit on this gate:** the ownership assertion is only meaningful where the checks run
as root, which is the VM and not this host. Off-VM `find "$LAB_DIR" ! -user "$(id -un)"` can only
ever read 0. What *was* verified here is that the mechanism is present in all five scripts
(`trap on_exit EXIT`, `chown -R user:user` gated on `id -u user`, `PYTHONDONTWRITEBYTECODE=1`) and
that `build.sh` fails the build if any script drops one of the three. See the pending list for what
a real VM run must confirm first.

## Gate 4 — the concurrency margin (TC05)

The endpoint holds every guard reply for a fixed 0.7 s and records the receive and emit time of each
request. The check reads back, per candidate query, `busy / span`: the sum of the individual
durations over the elapsed span from the first receive to the last emit, in tenths so the comparison
is integer arithmetic in the shell. **Threshold: 25 tenths.**

Measured directly from the endpoint's report, **four runs per candidate, two candidate queries per
run, ten candidates: 80 measurements.**

```
CANDIDATE                          factor_tenths per run (blocked, clean) x 4 runs
solution                            [40,40] [40,40] [40,40] [40,40]
alt1_class_agent                    [40,40] [40,40] [40,40] [40,40]
alt2_map_and_json_mode              [40,40] [40,40] [40,40] [40,40]
alt3_futures_wait_recursive         [40,40] [40,40] [40,40] [40,40]
alt4_two_roles_tuples               [40,40] [40,40] [40,40] [40,40]
alt5_partial_and_multiturn          [40,40] [40,40] [40,40] [40,40]
alt6_raw_threads_queue              [40,40] [40,40] [40,40] [40,40]
alt7_default_pool_dictcomp          [40,40] [40,40] [40,40] [40,40]
_cheat_sequential_guards            [10,10] [10,10] [10,10] [10,10]
_cheat_two_workers                  [20,20] [20,20] [20,20] [20,20]
```

**Not one measurement varied.** 64 concurrent measurements at exactly 40, 8 sequential at exactly
10, 8 two-worker at exactly 20. The threshold of 25 sits between 20 and 40 with a 15-tenth margin on
either side. This is stability, not luck.

It also does not depend on the core count. The 0.7 s is a `time.sleep` on the endpoint side, served
by a `ThreadingHTTPServer`, so four concurrent guard requests are four threads blocked on a timer
with no CPU contention to lose on a 2-core VM.

### The property the check requires, and whether the statement says it

The check requires **all four requests in flight together**. A four-worker pool measures 40. A
two-worker pool measures 20 and fails. A three-worker pool would measure 20 as well, because four
tasks over three workers still take two intervals.

This was previously a trap: the statement said "run all four concurrently" and "a `ThreadPoolExecutor`
and either `as_completed`, `wait` or `map`", neither of which tells a learner that a pool with fewer
than four workers is not enough. The Requirements for Task 5 now say it in those terms, and
`_cheat_two_workers` is the row that keeps it honest.

The statement also **no longer requires `concurrent.futures`**, because the check never enforced it.
`alt6_raw_threads_queue` scores 50/50 with raw `threading.Thread` objects, so requiring the module
would have been an unenforced rule that failed nobody and misled everybody.

## Gate 5 — time budgets

### Test cases

Every wait sits under one of four constants in the generated preamble, and `build.sh` refuses to
ship a script that lacks any of them:

```
SVC_WAIT=12     endpoint health wait
RUN_BUDGET=55   the bound around the one learner run
CURL_MAX=5      each grader HTTP call
DEPS_WAIT=20    the dependency sentinel wait
```

Worst case 12 + 55 + 10x5 ≈ **117 s**, inside the ~120 s limit. Measured across every sweep, each
check finished in **1 to 3 s**, and the slowest case in the whole matrix was the sequential probe's
TC05 at **7 s**.

`RUN_BUDGET` is enforced by `run_bounded()`: coreutils `timeout` where it exists, a shell watchdog
(`kill -9` after the budget) where it does not. **Verified with `_envprobe_hang.py`** (the reference
with a `time.sleep(600)` inside `route_request`) at `RUN_BUDGET=15`: TC04 failed at **15 s**, the
other four passed, score 40/50 harness and 30/50 portal, one stdout line per check. Only the
shell-watchdog branch is exercised on this host, because macOS ships no `timeout(1)`.

### Setup

Measured with `./setup-timing.sh`, which runs the **real generated script** with its paths and port
rewritten into a temp sandbox. Three consecutive runs after adding the foreground `curl`/`jq` step:
**7 s, 6 s, 7 s of foreground**, phase by phase:

```
base packages done       t+0s      (includes OK have python3 / OK have curl / OK have jq)
project skeleton done    t+0s
database ready           t+1-2s
endpoint up              t+1-2s
dependency handed off    t+6-7s
```

Of that, **5 s is the bounded `DEPS_GRACE`**, the deliberate pause that lets a fast machine exit
fully ready. Everything that has to happen before the learner has a working lab takes **1 to 2 s**.
The foreground tool check cost nothing measurable here, because this host already has both binaries
and the step is a `command -v` in that case.

## Gate 6 — failure diagnostics a human can act on

The portal shows the learner **only the verdict message**. Every failure path was judged by one
question: can a learner fix their code from this line alone?

### The empty-log dead end, fixed and both branches executed

The old shape was `report "failed" "$1 - Python error in $(learner_log "$2")$(trace_hint)"`, with
`trace_hint()` a **no-op stub**, so the message promised a hint that never arrived and named a log
that can be **empty**. `fail_no_output` now has three branches, and all three were run:

A submission that exits silently (an `os._exit(0)` at module scope, so the run prints nothing):

```
critique_query() did not run to completion: it printed nothing at all, so
/tmp/ashford_out_tc01_31905.log is empty. A module that only defines its functions and never calls
them exits quietly like this, and so does one that raises before reaching the end. Run cd
/tmp/ash-silent && python3 check_local.py and confirm every task prints a result before you submit
```

A submission that raises inside the function, with the traceback folded into the verdict:

```
critique_query() did not run to completion: Python raised before it could print a result:
File ".../solution.py", line 3, in critique_query | raise ValueError("the reviewer reply had no
reason field") | ValueError: the reviewer reply had no reason field [full output in
/tmp/ashford_out_tc01_32858.log]
```

A submission that hangs, at `RUN_BUDGET=15`:

```
route_request() did not run to completion: it was still running after 15s and was stopped.
Something in it does not return. Check that every loop is bounded by the max_attempts you were
passed, and that nothing waits on a model call that was never made. Last output before it was
stopped: ... Killed: 9 ... [full output in /tmp/ashford_out_tc04_59546.log]
```

`_envprobe_numpy` now names the exact import failure in the verdict rather than pointing at a file:

```
critique_query() did not run to completion: Python raised before it could print a result:
File ".../solution.py", line 10, in <module> | import numpy as np | ModuleNotFoundError: No module
named 'numpy' [full output in ...]
```

`log_tail` supplies the evidence: `tail -n 3`, newlines flattened to ` | `, capped at 280
characters, with the `[full output in <path>]` pointer kept after it.

`grep -n 'learner_log\|_out_\|\.log' test-cases/scripts/*.sh` was swept pack-wide, not patched at
one site. `trace_hint()` was removed from both logging modes and from every message, and `build.sh`
fails the build if it reappears.

### Verdicts now lead with the requirement that failed

Several verdicts were 400+ characters of `key=value`. A `need()` accumulator records one short
requirement name per broken rule, in the order the Requirements list them, so every message now
leads with the first thing that is wrong and keeps the observed values behind it. From the
two-worker probe:

```
parallel_guards: the four guard requests for the blocked candidate did not overlap in time: at
least 25 tenths of peak overlap is required, and four requests made one after another measure about
10 (and 1 other requirement(s)). Observed for the blocked candidate: blocked=true
blocked_by=[scan_scope] from 4 verdicts ... measured overlap of 20 and 20 tenths for the two
candidates against a required 25 tenths
```

From the rejected-query defect:

```
self_improving_query: a query that failed review was executed anyway; only a candidate that passed
review may run. Observed for the answerable question: result=[...] attempts=2 accepted=true ...
```

Every interpolated field is defaulted to a word (`unknown`, `none`, `0`), so a verdict built from an
absent value stays a readable sentence rather than printing `null` or nothing.

Every guard message names what was expected, what was observed, and where to look. The environment
faults say plainly that they are environment faults, so a learner does not read them as a problem
with their own code:

- missing `openai`: names `/var/log/ashford-lab/pip.log` and says to re-provision.
- missing `curl` or `jq`: names which one, names the install log, says it is not their code.
- endpoint down: names `${SVC_URL}/health`, `$SVC_BIN` and `/tmp/ashford_svc.log`.
- unreadable expected value: says the grader has nothing to compare against and gives the `curl` to
  run.

## Gate 7 — hardcoding, leaks and grader-side prose matching

Audited in both directions.

### Learner side

No magic numbers, no constant tables of fixture data, no keyword lists transcribed out of the
grader's or the endpoint's own strings, in `reference-solution/solution.py` or any `alt*`. The only
literals are the ones the statement fixes: the four category names, the four guard names and the
`ERROR: ` prefix.

**Two reference-versus-statement divergences were found and the reference was corrected**, because
a learner who implemented the statement exactly had to score 50/50:

1. `route_request` returned `{"category": ..., "result": "no desk handles '<x>'"}` for a category
   outside the four, while the statement said the result is **empty**. The statement's reading is
   right (a desk line is the only thing `result` should ever hold), so the reference and every
   derived probe now return `""`. Ungraded either way, but a reference that contradicts its own
   statement misleads the next reviewer about what the check requires.
2. `self_improving_query` returned a **fifth key**, `reason`, which is not in the contract. Reading
   the reference would suggest it was required. Removed from the reference; the alternatives keep
   theirs, which is what proves an extra key is tolerated, and the Interface contract now says so.

### Grader side: no check greps the learner's own prose

Every `grep -q` against learner-produced text was enumerated. There are exactly two, both in TC03:

```
test-cases/scripts/script_03.sh:325:  printf '%s' "$blob" | grep -q "no such column: cause_type"
test-cases/scripts/script_03.sh:326:  printf '%s' "$blob" | grep -q "no such column: affected_customers"
```

Both key on **SQLite's own error text**, not on anything the learner writes. `$blob` is the learner's
`error_memory` serialised with `json.dumps`, and the match is a substring, so an entry holding
`"ERROR: no such column: cause_type"` or the bare message both pass, and the entry's **key names are
not matched at all**. The two `trace_field` filters that check the repair prompt (`carried_first`,
`carried_both`) use `contains` against the same database error text.

The statement's Requirements were adjusted to match what is actually keyed on: the rule is that the
entry **must contain the database's error message text**, with `{"question", "failed_sql", "error"}`
given as the shape this lab uses rather than as a policed key list. A correct solution that words
its feedback differently, or labels its prompt sections differently, passes.

TC01 is the one place a string is compared exactly, and it is compared against the **reviewer's**
sentence, which the statement explicitly says to pass through unchanged. Result text and desk lines
are compared exactly, and both come from the provided toolkit, with `build.sh` pinning the two shared
renderers byte-identical between the toolkit and the endpoint.

### Dead configurability

Every `ASHFORD_*` environment variable is read by the **provided** `grid_kit`, not by the reference,
and the harness sets `ASHFORD_BASE_URL`, `ASHFORD_AUDIT_URL`, `ASHFORD_DB`, `ASHFORD_PORT` and
`ASHFORD_RUN_ID`. `ASHFORD_MODEL`, `ASHFORD_API_KEY` and `ASHFORD_AUDIT_TIMEOUT` are read by the
provided kit with working defaults and are set by nobody. They are documented kit behaviour rather
than the `REDCLIFFE_STORE` pattern (an override honoured only by the reference), so they were left
in place.

### Publish leak

Every question, request and candidate query the new statement publishes is disjoint from every graded
one, and `_cheat_hardcode` was re-run after the rewrite at exactly **0/50**.

Two published values needed a decision:

- **The assembled desk lines are structurally leakable.** Each desk runs a fixed aggregate query, so
  its line is the same whatever the request, and the old statement published all four verbatim. Input
  disjointness cannot fix that. The statement now publishes the **field names** of each desk line and
  not the numbers (`OUTAGE-DESK | outages=... | customers=...`), so no published string equals a
  graded expectation. The real defence is unchanged and is a mechanism assertion: TC04 requires 4
  classification turns recorded at the endpoint and at least 4 desk queries recorded against the
  database, which is why `_cheat_hardcode` scores 0/50 with all four correct lines pasted in.
- **Row counts are published** in the new "The data" section (eight substations, fourteen feeders,
  eighteen outages, twenty four readings). Three of those are inferable inputs to a desk line. They
  were kept because the shape of the data is what the section is for and any learner reads them off
  the database in one `SELECT COUNT(*)`. Documented here rather than left implicit.

The statement publishes the real schema, which is safe: TC01's expected reason is derived from the
live schema, and a solution that computes the verdict locally from that schema is exactly
`_cheat_no_endpoint`, which scores 0/50 on the round trips it skips.

Not published anywhere in the statement: the graded questions, the graded requests, the graded
candidate queries, `peak_load_mw`, `cause_type`, `affected_customers`, `reactive_power_factor`, the
concurrency threshold, the grader key, the grader path prefix, and the oracle and trace endpoints.
Verified by grep.

### Bypass

`_cheat_no_endpoint` reimplements the whole layer locally with hand-written rules over the real
schema and scores **0/50**, losing all five checks on the round trips it skipped.
`_cheat_sequential_guards` and `_cheat_two_workers` both produce the right verdict without the
mechanism and both lose TC05.

## Gate 8 — the cap-boundary audit

This pack has the most caps of the three, and an undefined counting noun in a numbered step is how a
correct learner loses 10 points. Every bound in the statement was enumerated and each is now defined
where it is introduced.

- **Task 2, `max_attempts`.** Counts **candidates reviewed**, one per `critique_query` call. Does not
  count draft turns, repair turns or executions. At the ceiling the loop **stops**; it does not ask
  for one more repair. So `max_attempts` reviews imply at most `max_attempts - 1` repair turns and at
  most one execution.
- **Task 3, `max_attempts`.** Counts **queries run**, one per `execute_sql` call. Does not count
  draft turns or repair turns. At the ceiling the loop **stops**, the same way.
- **The two resolve in the same direction, and the statement now says so in the same sentence.**
  Symmetry is assumed unless denied, and these two count different operations, which is exactly the
  case where a learner needs it spelled out. Task 3's Requirements say: "it resolves the same way as
  Task 2's ceiling ... The two tasks count different operations, but both stop at the ceiling rather
  than doing one more thing."
- **A worked arithmetic line for each.** Task 2 with `max_attempts=4` and a question that never
  converges: one draft turn, four reviews, three repair turns, `attempts=4`. Task 3 with
  `max_attempts=3` and a draft that fails twice: three `execute_sql` calls, two repair turns,
  `attempts=3`.
- **`error_memory` length is derived rather than left to inference:** `attempts - 1` when the last
  run succeeded, `attempts` when every run was rejected.
- **The guard count is four**, fixed by `GUARD_NAMES`, with no cap semantics. `guards` always holds
  four entries, including for a guard whose reply could not be parsed.
- **No other counting noun appears in a numbered step.** "One model turn" is a count of one, not a
  cap, and it is stated per step.

The same two cap definitions were added as comments in `reference-solution/solution.py` and as
docstring lines in `app/solution_stub.py`, so the unit is visible at the place the learner writes the
loop and not only nine lines away.

## What each check is anchored on

Every check couples a returned value to a side effect the endpoint recorded, so no assertion can be
satisfied by a value alone.

This record is the only home for the material below. `SOLUTION.md` was reduced to a walk-through
of the model answer, so the check anchoring, the score rows, the probe names and the concurrency
thresholds live here and in `README.md` rather than being restated to an instructor reading the
solution.

- **TC01** — `valid=false` with the reason **string-equal** to the oracle's (which names the missing
  column and the real one to use instead, both derived from the live schema), `valid=true` for the
  second candidate, `kinds.critique >= 2`, at least one recorded review request whose SQL contains
  the unpublished bad column, and `executed | length == 0`.
- **TC02** — the result **string-equal** to the database-true value of the correct query,
  `attempts == 2`, `accepted == true`; for the unanswerable question `attempts == 3`,
  `accepted == false` and an empty result; at least one recorded repair where `used_feedback` is
  true; `>= 1` successful execution and **exactly 0** failed ones.
- **TC03** — the result string-equal to the oracle value, `attempts == 3`, `succeeded == true`,
  exactly **2** error-memory entries whose serialised form contains both database error texts, at
  least one recorded repair request whose prompt contains the **first** error, at least one
  containing **both**, and exactly **2** rejected executions on record.
- **TC04** — the four returned categories equal to the four oracle categories **in order**, the four
  returned desk lines equal to the four oracle desk lines, exactly 4 classifications recorded whose
  categories match the same ordered list, and `>= 4` successful desk queries.
- **TC05** — `blocked == true` with `blocked_by` string-equal to the oracle's, 4 guard verdicts whose
  names equal the oracle's sorted list, `blocked == false` with 4 clear guards for the second
  candidate, exactly **8** guard calls seen by the endpoint, and an overlap factor `>= 25` tenths for
  **each** candidate separately.

## Fact preservation for the statement rewrite

The statement was rewritten end to end. A list of **71** grader-visible literals was built from
`test-cases/scripts/*.sh` and `app/` (every callable name, every argument name, every returned key,
the four category names, the four guard names, every provided public name, the project path, the
endpoint URL and port, the file names, the table names, the `ERROR: ` prefix, the four desk prefixes,
the model name) and checked against the new text:

```
total facts: 71  missing: 0
```

The complete list is in `gen_tests.sh`'s graded-input block and in the check scripts; the check that
produced the count is a `grep -qF` loop over each literal.

Structure changes:

- **"How you are graded" was deleted entirely**, including the five check descriptions and the points
  arithmetic. It handed the learner a reverse-engineering map. It is replaced by a short **"Before you
  submit"** block: which file is assessed, the command to run first, and one line saying the grader
  uses its own inputs.
- **"The pieces you are given" now documents every public name in all six `grid_kit` modules** with
  a signature, a return type, one or two sentences, and a **real** usage snippet with real output.
  Every snippet output in that section was captured from a run against a seeded database, including
  the `execute_sql` error strings and `run_sql`'s tuple.
- **"Project layout" is a literal tree** with an inline marker per entry, and one line under it
  saying the learner opens `solution.py` and nothing else.
- **"The data" is new**: four tables with their real columns, row counts, the values each categorical
  column holds, the join keys, and a plain statement that a question can name something the schema
  does not record, which is why Task 2 has to stop at its limit.
- **Every task now has Goal / Steps / Requirements / Example**, with Requirements as an explicit list
  pinning the return type, every edge case, what is fixed versus free, and the cap arithmetic.

Style: 0 em dashes, 0 markdown table lines, no banned construction, none of the banned words.

### Every "must" has a check, or is not a rule

Every *must / required / do not / never* in the new statement was enumerated and traced.

Backed by a check: the candidate query appearing in the review message (TC01 `saw_candidate`); not
executing anything in `critique_query` (TC01 `ran == 0`); the reason passed through unchanged (TC01
string equality); the repair carrying the review reason (TC02 `used_feedback`); nothing rejected being
executed (TC02 `ran_bad == 0`); the attempt counts (TC02, TC03); the error message reaching the
memory and the repair (TC03); the accumulated memory reaching the second repair (TC03
`carried_both`); returning the classified category (TC04, both sides); one classification turn per
request (TC04 `traced == 4`); the desk line unmodified (TC04 string equality); all four guards asked
(TC05 `guards_seen == 8`); all four in flight together (TC05 overlap); the four returned key sets
(every check reads them).

**Demoted from rule to specification**, because no check enforces them and none can fire under
grading: the four JSON-parse fallbacks (Tasks 1, 4, 5) and the unroutable-category branch. They are
now written as return-value specification ("Edge case, a reply that is not JSON: the return value
is ... rather than an exception") rather than as policed imperatives, so a learner cannot read them
as a rule they might be punished for.

**Reworded**, because the checked property was not the one being commanded:

- "Build a dispatch table, not a chain of conditionals" led a bullet, but what TC04 checks is that
  the desk called matches the returned category. The bullet now leads with that, and the dispatch
  table follows as the shape that holds.
- "Exactly one `execute_sql` call is allowed" was stronger than TC02, which requires at least one
  success and zero failures. It is now phrased as description: "The one query this function runs is
  the candidate that passed review."
- Task 5 no longer requires `concurrent.futures` specifically. The check measures overlap and
  nothing else, so mandating the module was an unenforced rule. See Gate 4.

## Still to confirm on the real image

The grading path is fully validated on the authoring host, which is where every number above comes
from. These can only be observed on the portal image.

1. **The ownership invariant with the checks actually running as root.** This is the first thing to
   check, and it is the one that changed most in this pass. Grade a fresh VM, then
   `find /home/user/ashford-grid ! -user user` must print nothing, **and** `cd
   /home/user/ashford-grid && python3 check_local.py` must still work as `user`. Repeat after a
   **partial** grading run killed before check 5. The gate is now `id -u user`, which fires on the VM
   and did not fire in any local harness, so the VM run is the **first time this code path has ever
   executed**. Off-VM the assertion itself is vacuous. Note that `/home/user/.bashrc` can be
   root-owned on a pristine image, which is why the invariant is scoped to the project directory.
2. **A real submission renders rows in the "Test Case Results:" panel.** The whole judge-fidelity
   migration is aimed at this, and the negative control proves the mechanism, but the panel itself
   cannot be observed off-portal. Submit the untouched starter first, deliberately: that is the path
   that was being voided, and it must now show the "still the untouched starter" row rather than an
   empty panel.
3. **`curl` and `jq` in the foreground on the real image.** Both are present on this host, so the
   foreground took the `command -v` path and cost nothing. If the image lacks `jq`, the new bounded
   `apt-get` attempt runs on the critical path. Confirm with
   `grep -E 'have (curl|jq)|installing the grading tools' /var/log/ashford-lab/setup.log` and check
   the total in `tail -1 /var/log/ashford-lab/setup.log`.
4. **The foreground fits inside the portal's status-poll window.** Measured at 6 to 7 s in a sandbox
   on this host with the apt block skipped. On the image `python3` is present so that block is
   skipped there too, but the number has not been taken on the image.
   `IMAGE=jrei/systemd-ubuntu ./setup-timing.sh --image` takes it.
5. **The `ashford-gridd` systemd unit comes up** rather than falling through to the detached
   fallback. `grep '^WARN' /var/log/ashford-lab/setup-status` is the whole check; it should print
   nothing. Either path works for grading, since the checks start the endpoint on demand, but the
   unit is the one that survives a reboot.
6. **The `run_bounded()` coreutils branch.** Locally only the shell-watchdog fallback runs, because
   macOS ships no `timeout(1)`. On Ubuntu the `timeout -k 5 55` branch executes. Confirm one check
   still scores normally there.
7. **The concurrency margin on a 2-core VM.** 80 measurements here showed no variance, and the delay
   is a `time.sleep` on the endpoint rather than CPU work, so contention should not reach it. Worth
   one confirmation that TC05 still reads 40 tenths on the image.

Also worth confirming once, as hygiene rather than grading: **where the platform leaves the setup
script.** It carries the endpoint source inline, including the grader key, the question bank and the
oracle endpoint. The endpoint itself is installed `root:root` mode `0700`, so the only exposure is
the platform's own copy of `Setup.zip` and the expanded script. The practical impact is small,
because every check couples returned values to side effects the endpoint recorded, which is why
`_cheat_hardcode` and `_cheat_no_endpoint` both score 0/50.

## Claims from the previous record that this pass disproved

- **"`_defect1_critique_executes` — 40/50 (TC01 only)"** and the three rows like it. True of the
  local harness, false of the portal, which breaks at the first failing case: `_defect1` scores
  **0/50** there. Corrected above, and `sweep.sh` now prints both numbers so the distinction is
  visible in the data rather than only in prose.
- **"the ownership rows cannot be proven off-VM, but the mechanism is present in all five
  scripts."** The mechanism was present and **could not fire** in any environment the pack tests,
  because it was gated on `LAB_DIR` starting with `/home/user` while every harness uses `/tmp`.
  Corrected.
- **"`test-cases/scripts/common.sh` — local `print_status` stub."** Accurate as a description, wrong
  as a validation posture: a helper easier to satisfy than the real one is why the ERR-trap bug was
  invisible here. Replaced with the faithful replica.
- **"`./build.sh` — all eleven guards pass."** They do, but `build.sh` itself had a pipefail race
  that failed a correct `TestCase.zip`. It fired on the first run of this pass. Fixed.
- **"Python 3.14.6"** in the old header. This pass ran on Python 3.13 in the review venv. Corrected
  rather than carried forward.
- **"Two full back-to-back sweeps ... four full agreeing sweeps in total."** Those runs were real but
  predate every change here, so they are superseded by the two sweeps recorded in Gate 2, taken after
  the last edit.
