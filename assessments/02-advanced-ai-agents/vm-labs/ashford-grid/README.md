# Ashford Grid — VM Lab Pack

Execution-graded lab on the **self-improvement layer and the workflow patterns that sit on top of
a working agent loop**. Module 2, Class 2 (Advanced Agent Concepts). The learner writes only
`solution.py`; the configured client, the grid operations database, the persona, the four system
prompts, the three SQL tools and the four desks are provided. Grading runs the learner's functions
and inspects both what came back and what the system actually did.

- **Points:** 50 (5 scripts × 10) — the platform accepts at most 5 test scripts
- **Docker required:** no
- **Third-party libraries the learner needs:** `openai` only, with the raw SDK — no framework
- **Deterministic at grade time:** yes — a local endpoint, no hosted model

## Content covered

Grounded in `modules/02-advanced-ai-agents/markdown/L2_Advanced_Agent_Concepts.md`, both halves.

| Lecture material | Task | Check |
|---|---|---|
| Critique prompt + `critique_sql()`, the FEEDBACK step of Self-Refine (§8.1) | Task 1 | TC01 |
| Evaluator–Optimizer: generate → evaluate → refine → re-evaluate, bounded, with a deterministic stop (Workflow 4) | Task 2 | TC02 |
| `refine_sql()` with feedback-conditioned prompting (§9.1); `execute_sql_safe()` and execution-aware feedback (§9.2); Reflexion-style `error_memory` and `_build_memory_context()` (§9.3, §10.1) | Task 3 | TC03 |
| Routing: classification then dispatch through a lookup table (`SUPPORT_ROUTES`), Workflow 2 | Task 4 | TC04 |
| Parallelization: sectioning + a guard that blocks delivery, `ThreadPoolExecutor`, aggregation (Workflow 3, §2 Example A and §4.1–4.3) | Task 5 | TC05 |

Every construct a solution needs is taught by that lecture: `from openai import OpenAI`,
`client.chat.completions.create(model=..., temperature=0.0, messages=[...])`, an `llm_call`
wrapper, JSON replies parsed with fence stripping and a parse-failure fallback, a bounded
`for`/`while` retry loop, a dispatch dict keyed by category, and
`concurrent.futures.ThreadPoolExecutor` with `as_completed`.

**Deliberately excluded**, because Class 1's lab (`kilnbrook-foundry`) covers it: writing the three
SQL tools, the OpenAI tool-schema list, and the ReAct orchestration loop. This lab assumes a
working loop and grades the layer above it. No LangChain or LangGraph anywhere — the lecture uses
no framework, and three existing labs already cover those.

## Layout

```
ashford-grid/
  problem-statement.md          learner-facing
  README.md                     this file
  INSTRUCTOR-SETUP-GUIDE.md     portal configuration + troubleshooting
  VALIDATION.md                 what was executed, with results
  SOLUTION.md                   walk-through of the model answer
  build.sh                      regenerates setup_script.sh + dist zips, runs every guard
  gen_tests.sh                  regenerates script_01..05 from one preamble
  sweep.sh                      grades every candidate on its own port and lab dir
  setup-timing.sh               measures the setup foreground wall clock
  validation/permutations.sh    (written) x (ran) x (grading) ordering matrix
  app/                          provided learner-visible sources
    grid_kit/{__init__,client,db,handlers,persona,prompts,tools}.py
    solution_stub.py            shipped to the VM as solution.py
    check_local.py
  service/
    gridd.py                    HIDDEN endpoint (installed to /opt/ashford-svc, 0700 root)
    seed_db.py                  HIDDEN database seeder (same place, same mode)
  setup/
    setup_script.template.sh    source of truth; FILE markers are expanded by build.sh
    scripts/setup_script.sh     GENERATED - do not hand-edit
  test-cases/scripts/
    script_01..05.sh            GENERATED, self-contained; ONLY these ship in TestCase.zip
    common.sh                   FAITHFUL REPLICA of the platform judge helper
                                (run-all only, NOT shipped)
    run-all.sh                  local validation harness (NOT shipped)
  reference-solution/
    solution.py                 model answer
    alt1_class_agent.py         one stateful agent class, no system role at all
    alt2_map_and_json_mode.py   json_object response format, pool.map, regex unfencing
    alt3_futures_wait_recursive.py  futures.wait, recursion, registry-by-name dispatch
    alt4_two_roles_tuples.py    separate Reviewer/Repairer objects, tuple memory, generator loop
    alt5_partial_and_multiturn.py   three-message conversations, functools.partial fan-out
    alt6_raw_threads_queue.py   raw threading.Thread + queue.Queue, no concurrent.futures
    alt7_default_pool_dictcomp.py  ThreadPoolExecutor() with no max_workers
    _defect1_critique_executes.py   probe: the review step runs what it approved
    _defect2_runs_rejected.py       probe: the loop runs every candidate, not only the accepted one
    _defect3_drops_error.py         probe: the database error never reaches the repair step
    _defect4_ifchain_routing.py     probe: routing by a keyword chain instead of the classification
    _cheat_hardcode.py              probe: every published value pasted in
    _cheat_no_endpoint.py           probe: the whole layer reimplemented locally, no model turns
    _cheat_sequential_guards.py     probe: the guards run one after another
    _cheat_two_workers.py           probe: a two-worker pool, so the guards overlap only in pairs
    _cheat_no_critique_forward.py   probe: the repair request omits the review reason
    _envprobe_numpy.py              regression: a module-scope numpy import
    _envprobe_hang.py               regression: a stalled call inside one function
  dist/                         Setup.zip + TestCase.zip (the two portal artifacts)
```

## The five graded themes

- **TC01** — the review gate rejects a bad query **by name** and never runs it. A candidate naming
  a column the schema does not have comes back invalid with the reason that names it and suggests
  the real column; a candidate over real columns comes back valid; and the audit trail for that
  run holds **zero** executed queries.
- **TC02** — the evaluator–optimizer loop converges and is bounded. A question whose first draft
  fails review reaches the database-true result in exactly 2 reviewed candidates, at least one
  repair request carried the review reason, one query ran successfully and **nothing that failed
  review ran at all**; and a question the schema cannot answer stops at `max_attempts` with no
  result.
- **TC03** — execution-aware feedback recovers from a real database error, carrying it forward. The
  graded question has **two** bad column names, so the database rejects it twice; the endpoint saw
  a repair request carrying the first error, then one carrying **both** errors together, and the
  third run returns the oracle-true value. The returned error memory holds both failures.
- **TC04** — routing classifies and dispatches. Four control-room requests, none of which contains
  its category name, reach the right desk; the returned category equals the one the endpoint
  recorded for that request, in order; and every desk answered from the database.
- **TC05** — the guards really run in parallel. All eight guard calls (four per candidate) reached
  the endpoint, and for **each** candidate the endpoint's own receive/emit timestamps put the
  busy-time-over-elapsed-span factor at or above 2.5 — measured at 4.0 for every concurrent
  candidate and 1.0 for the sequential probe. One failing guard blocks the aggregate verdict; an
  all-clear candidate passes it.

## Regenerating and validating

```bash
./gen_tests.sh          # rebuild the test scripts from the shared preamble
./build.sh              # run every guard, regenerate setup_script.sh, restage dist/
PY=<venv>/bin/python ./test-cases/scripts/run-all.sh                      # -> expect 50/50
PY=<venv>/bin/python ./sweep.sh                                           # the whole matrix
PY=<venv>/bin/python ./validation/permutations.sh                         # ordering matrix
PATH=<venv>/bin:$PATH ./setup-timing.sh                                   # foreground wall clock
```

`build.sh` refuses to ship the pack when any of these is true:

- more than five test scripts;
- a test script missing `SVC_WAIT`, `RUN_BUDGET`, `CURL_MAX`, `DEPS_WAIT`, the
  `report()`/`trap on_exit EXIT` single-verdict guarantee, the `chown -R user:user` handback, or
  `PYTHONDONTWRITEBYTECODE=1`; or one that uses `set -e`/`set -u`;
- **a test script missing `trap - ERR`, `set +eE` or `exec 2>>`** — the platform's own
  `common.sh` installs an ERR trap inside the check's shell, and its handler prints a second line
  after the verdict. The judge grades the last line, so that second line discards the verdict and
  the portal reports the submission as having no test cases at all;
- a test script gating its ownership repair on `LAB_DIR` rather than on `id -u user`, or still
  splicing the dead `trace_hint` stub into a message, or lacking `run_evidence`;
- `test-cases/scripts/common.sh` not being a faithful replica of the platform helper (it must carry
  the ERR trap, the exiting internal-error handler and the `jq -n` output);
- **an apostrophe inside any `<<'PY' … PY` heredoc body** — that heredoc lives inside a `$( )`
  command substitution and bash counts quotes while scanning for the matching paren, so one
  apostrophe makes the file unparseable on a line that looks fine;
- the shared preamble having drifted between two scripts;
- the `shared:formatter` block differing between `app/grid_kit/tools.py` and `service/gridd.py`, or
  the `shared:desks` block differing between `app/grid_kit/handlers.py` and `service/gridd.py` —
  the learner renders results with the toolkit while the grader computes expected values with the
  endpoint, so a drift there makes a correct solution fail on formatting;
- a dispatch marker in `service/gridd.py` that is absent from `app/grid_kit/prompts.py`, or the
  guard-name lists disagreeing;
- `problem-statement.md` containing a markdown table (the portal renderer has no GFM tables);
- a provided source under `app/` mentioning lecture, course, class, grading, grader, mock, canary,
  sentinel or oracle;
- `TestCase.zip` containing `common.sh`, `run-all.sh` or `.DS_Store`, or either zip missing
  `scripts/` or `data/` at its root.

Test scripts ship log-free; `TEST_LOGGING=on ./gen_tests.sh` regenerates them with per-check logs
in `/tmp/ashford-lab-logs/` for a debugging session. The single-verdict `EXIT` trap is in both
modes — it is a correctness property, not a debugging one. Every check appends its own wall time to
`/tmp/ashford_timing.log`, so a cap hit is diagnosable from the VM. Setup always logs to
`/var/log/ashford-lab/setup.log`; `grep '^WARN' /var/log/ashford-lab/setup-status` is the fastest
check that provisioning was clean.

`run-all.sh` accepts `SOLUTION`, `LAB_DIR`, `LOG_DIR`, `SVC_URL` and `PY`. It **aborts with
`WRONG-FILE-GRADED`** if the assembled `solution.py` is not the candidate named in `SOLUTION` —
omitting `SOLUTION` otherwise grades the reference while appearing to grade the candidate, which
produces a full sheet of perfect scores.

## How the offline endpoint works

`grid_kit.make_client()` returns a real `openai.OpenAI` client pointed at `gridd`, a stdlib HTTP
service on `127.0.0.1:8836` installed outside the learner's directory at `/opt/ashford-svc`
(`root:root`, `0700`). It speaks `POST /v1/chat/completions` and returns a valid OpenAI
chat-completion envelope, so the SDK's own validation is satisfied; it also answers `GET /v1/models`
and emits a well-formed `tool_calls` message (arguments as a JSON **string**) for a caller that
registers tools, though no graded path needs one.

Everything it returns is **computed from the real SQLite schema, never sampled**. It dispatches on
which of the five provided prompts appears in the request:

- **review** (`SQL quality reviewer`) — parses the candidate, resolves aliases, strips string
  literals so `WHERE status = 'active'` is not read as a column, and validates every table and
  column against `PRAGMA table_info`. An unknown name is rejected by name, with the closest real
  column suggested when one shares a word with it and **no suggestion at all** when nothing does —
  which is what makes a genuinely unanswerable question unanswerable.
- **draft** (`SQL generation specialist`) — the correct query for the matched question, with one or
  two column names corrupted where the bank says a first pass should get it wrong.
- **repair** (`SQL repair specialist`) — takes its **own last emitted query** for this session and
  question, and corrects it using only the feedback the caller actually sent: bad names named by
  `column 'X' does not exist` or `no such column: X` are substituted for their closest real
  counterpart. A caller that forwards no reason and no error gets its query back unchanged, and
  that query still fails. This is what TC02 and TC03 ride on.
- **classify** (`grid operations request classifier`) — a fixed request bank plus a keyword
  fallback, over the request itself rather than the surrounding prompt.
- **guard** (`grid analytics guard named <name>`) — one rule per guard, held for a fixed 0.7 s and
  stamped with receive and emit times.

`POST /v1/audit/query` is the operations audit trail: `grid_kit.tools.run_sql` writes one line per
statement it runs, which is how the checks know whether a query was executed and whether the
database accepted it.

**Grader-only endpoints** live under `/__agq7w2/` and require the header
`X-Grader-Key: ashford-grader-q7w2`. Without it they return a plain 404, so a learner probing the
port cannot read expected answers. They expose a per-session trace (turn counts by kind, the
verdicts issued, the full text each repair request carried, the classifications, the executed
statements, and per-guard receive/emit timestamps with a computed overlap factor) and an oracle that
computes the true critique verdict, the true guard report, the true routing category and desk line,
and the database-true result of a question's correct query.

## Anti-cheat posture

- **Every check couples a returned value to a side effect the endpoint recorded.** `_cheat_hardcode`
  and `_cheat_no_endpoint` produce plausible-looking values with no round trips and score **0/50**.
- **The review verdict cannot be guessed.** The reason names the offending column *and* the real
  column to use instead, both derived from the live schema, and the graded candidates are
  unpublished.
Scores below are quoted as `harness / portal`. The harness runs all five checks; the platform's
`main.sh` **breaks at the first failing case**, so the score a learner receives is the leading run
of passes. A probe that fails only TC01 scores 40/50 here and **0/50** there.

- **Non-execution is observable.** TC01 requires the audit trail for its run to be empty, so a
  review step that peeks at the database loses the check (`_defect1`, 40/50 harness, 0/50 portal).
- **The gate has to be a gate.** TC02 requires zero failed executions, so running a rejected
  candidate loses the check (`_defect2`, 40/50 harness, 10/50 portal).
- **Feedback has to be forwarded.** The repair engine keys on what the prompt carries, so omitting
  the review reason (`_cheat_no_critique_forward`, 40/50 harness, 10/50 portal) or the database
  error (`_defect3`, 40/50 harness, 20/50 portal) leaves the loop unable to converge.
- **The classification has to be used.** TC04 compares the returned category against the one the
  endpoint recorded, and the graded requests never contain their category name, so a keyword chain
  misroutes them (`_defect4`, 40/50 harness, 30/50 portal).
- **Concurrency is measured, not asserted.** The endpoint timestamps every guard request and the
  check reads back how much of the four requests overlapped in time. `_cheat_sequential_guards`
  returns the right verdict and still loses TC05 (40/50 on both, because TC05 is last), and
  `_cheat_two_workers` shows the boundary: a two-worker pool overlaps the guards in pairs, measures
  20 tenths against a required 25, and loses the same check.
- **No published example is a graded case.** Every question, request and candidate query in
  `problem-statement.md` and `check_local.py` is disjoint from every graded one.
- The endpoint and the seeder are `0700 root:root`; nothing under `/home/user/ashford-grid/`
  reveals them. The grader key and the question bank live only in `service/gridd.py`, the generated
  setup script and the test scripts — none of which land in the learner's home directory.

## Validation record

See `VALIDATION.md` for the full log. Summary — Python 3.13.13 with `openai==3.1.0`, every row
observed in **two full back-to-back sweeps on different port bases (9300 and 9330) whose SCORE and
PORTAL cells agreed row for row**:

Quoted as `harness / portal`, where portal is the prefix score `main.sh` awards.

- `reference-solution/solution.py` — **50/50 / 50/50**
- `alt1_class_agent` … `alt7_default_pool_dictcomp` — **50/50 / 50/50** each (seven shapes)
- untouched `solution_stub.py` — **0/50 / 0/50**
- `_defect1_critique_executes` — 40/50 / **0/50** (loses TC01)
- `_defect2_runs_rejected` — 40/50 / **10/50** (loses TC02)
- `_defect3_drops_error` — 40/50 / **20/50** (loses TC03)
- `_defect4_ifchain_routing` — 40/50 / **30/50** (loses TC04)
- `_cheat_no_critique_forward` — 40/50 / **10/50** (loses TC02)
- `_cheat_sequential_guards` — 40/50 / **40/50** (loses TC05, which is last)
- `_cheat_two_workers` — 40/50 / **40/50** (loses TC05 on partial overlap)
- `_cheat_hardcode` — **0/50 / 0/50**
- `_cheat_no_endpoint` — **0/50 / 0/50**

Seven materially different but correct implementations at full marks, each defect losing precisely
the theme it breaks, and both no-round-trip shortcuts at zero: that is the evidence that behaviour
is graded rather than shape.
