# `thistledown-mill` — validation record

Everything below was **run**. Authoring host: macOS, CPython **3.13.13**,
`crewai 0.203.2` / `litellm 1.74.9` / `pydantic 2.13.4` in a venv.
Target VM: *systemd Ubuntu*, Ubuntu 25.04 / Python 3.13.3.

## 1. The dependency is installable on the target interpreter

`pip install --only-binary=:all: "crewai>=0.130,<1.0" python-dotenv` on
**Python 3.13**:

- resolved to **crewai 0.203.2**, natively in **66 s**;
- the same install inside `python:3.13-slim` on **linux/amd64** (the VM
  architecture, under emulation here) took **2 m 41 s** and produced **643 MB**
  of site-packages.

That is why it is in the detached job and why the checks wait on a readiness
file.

## 2. How CrewAI actually calls a model — established by experiment

A minimal one-agent crew was pointed at the pack's model and the request body
captured:

```
keys: ['messages', 'model', 'stop', 'temperature']
tools offered: []
n messages: 2
```

**No function calling.** The tools are described in the system prompt and the
text protocol is expected back. Three consequences, all now handled:

1. The first attempt at detecting "a tool has reported back" looked for
   `Observation:` — which **appears in CrewAI's own format instructions**, so the
   model answered the very first turn as if the work were done: `calls: 1,
   tool_calls: 0`. Now decided on the shape of the conversation instead.
2. The tool-less planner agent was being handed a query to run, which it cannot
   do. The model now checks the offered tool list first.
3. The planning note quoted **itself**: the extractor picked the first line
   containing the yarn code and two numbers, which was the previous summary
   (`Order TM-4312 ... 1200 metres`). It now skips any line carrying the order
   number.

After those three fixes, a two-agent sequential crew runs in **2 s** with
`calls: 3, tool_calls: 1`, and the note carries the real stock row
`YN-CT08 | 51 | 30`.

## 3. Reference solution

```
SCORE: 50/50   (passed 5, failed 0)
slowest test case: 4s   (portal limit is about 120s)
```

## 4. Alternative shapes — all 50/50

- `alt1_block_scalars` — block scalars and different wording in both YAML files.
- `alt2_decorator_tools` — the `@tool("run_query")` decorator instead of
  `BaseTool` subclasses.
- `alt3_authorizer_guard` — the text guard plus a driver-level
  `set_authorizer` deny-by-default.
- `alt4_extra_tool` — a third tool (`loom_lookup`) on the analyst.
- `alt5_loop_build` — the agents built in a loop over the configuration.
- `alt6_implicit_context` — **no `context=` on the note task.** This began as a
  defect probe and scored 50/50, because a sequential CrewAI crew already hands
  the previous task output to the next one. The probe was reclassified and the
  statement now says either is fine. Worth knowing before marking.

## 5. Defect probes — each loses exactly its own theme

- `_defect1_raises` — a database error raised instead of returned. **40/50,
  `script_01`.**
- `_defect2_no_guard` — whatever the agent writes goes to the database. **40/50,
  `script_02`.** The read-only connection means a `DELETE` fails anyway, but with
  a driver error rather than a refusal, which is what the check reads.
- `_defect3_hardcoded_config` — agents and tasks written into the Python.
  **40/50, `script_03`.**
- `_defect4_both_tooled` — both agents given the database. **40/50,
  `script_03`.**
- `_defect5_no_max_iter` — the analyst uncapped. **40/50, `script_03`.**
- `_defect6_single_task` — only the stock check on the crew. **40/50,
  `script_03`.**

## 6. Fabrication probe

`_cheat_canned_tools` answers from a table written out by hand and never opens
the database. **40/50, losing `script_01` only.**

That is the intended outcome and worth stating plainly: the probe genuinely
implemented the guard, the configuration, the crew and the run, so it keeps those
four themes. It loses the data-source theme because two of the six calls in
check 1 are queries nothing could have prepared for — a `COUNT(*)` over the looms
and one column of one row. Those two assertions were added **because** an earlier
version of this probe scored 50/50.

## 7. Ordering matrix

`./validation/permutations.sh` — **7 rows, 0 failures**, re-run 2026-08-26 on
python 3.13.13 with crewai 0.203.2 (the version a live lab reports), after
fixing the verdict parser described in §9b. The earlier "6 rows, 0 failures"
recorded here was not a real result: every row scored 0 and only the row that
expects 0 was satisfied.

1. starters untouched → 0/50, refused fast.
2. **partially written — `crew.py` and `agents.yaml` only, then submitted →
   0/50, and the verdict names `mill/tools.py` and `config/tasks.yaml`**
   (the production report of §9b).
3. written, never run by the learner → 50/50.
4. learner ran it first, then graded → 50/50.
5. grading killed after three checks → 30/50.
6. graded a second time → 50/50.
7. graded a third time → 50/50 **and the mill database is byte for byte
   unchanged**.

Rows 3, 4, 5 and 7 each ran the learner's own crew afterwards and it succeeded.
The ownership assertions are vacuous on the authoring host (no `user` account)
and still need one run as root on a provisioned VM — see §10.

## 8. Interpreter starts per check

1, 1, 1, 1 (plus the crew's own subprocess), 2. An earlier version made one
interpreter start per tool call and check 2 took **28 s**; batching six calls
into one start brought the slowest check to **4–6 s**. On this platform that
matters more than any computation in the checks.

## 9. Bugs found and fixed during validation

- **A heredoc piped into `python3 -` arrives empty** when the shell has no
  `timeout(1)` and the watchdog path backgrounds the command: a background job in
  a non-interactive shell has stdin on `/dev/null`. Every tool call silently
  returned nothing, with a zero exit. The helpers now write the body to a file
  and run the file.
- **jq precedence.** `[.a[].x] | sort == ([.b[].x] | sort)` evaluates the
  right-hand side against the *piped* value, not the root, so it compared an
  array against null and the reference solution failed its own configuration
  check. Both sides are now bracketed.
- **Helpers called inside `$( )` cannot export a log path**, because a command
  substitution is a subshell — every failure message named an empty file. The log
  path is now derived from the check number alone.

## 9b. Found in production (2026-08-26)

Reported from a real submission: a learner wrote `mill/crew.py` and
`config/agents.yaml`, left `mill/tools.py` and `config/tasks.yaml` as the
starters, and submitted. The single verdict read

    stock_lookup and run_query and run_query and run_query and run_query and run_query is not written yet

Reproduced exactly, then fixed on both layers:

- **`require_started` joined its two YAML gates with `&&`**, so filling one
  excused the other, and it had **no gate at all for `mill/tools.py`**. A
  half-written project therefore passed the gate and failed at the tool probe,
  which names tools rather than files. Now one gate per file, collecting every
  untouched starter into one verdict that names them: *these are still the
  untouched starters in …: mill/tools.py config/tasks.yaml*. Verified against
  three partial states, and against the reference plus all six alternates to
  prove none of them trips it.
- **Every jq join over per-probe results lacked `unique`**, so a tool probed
  five times was named five times. Three joins deduped (two in check 1, one in
  check 2). The same input now reads *run_query and stock_lookup is not written
  yet*, and a partially written `tools.py` reads *run_query is not written yet*.
- The reported sequence is now **row 2 of the ordering matrix**, asserting the
  score is 0, that the verdict names both unwritten files, and that no verdict
  repeats a tool name.

Found while re-running the ordering matrix, and the most serious of the three:
**the matrix itself was vacuous.** `grade()` scored a check by grepping its
output for `^RESULT:success`, which is the format of the *fallback stub* the
preamble installs only when no judge helper is found. `test-cases/scripts/
common.sh` — the faithful replica of the platform helper — is present during
authoring, so the checks emitted `{"status": "success", ...}` and the grep
matched nothing. Every row scored 0/50. The one row that expects 0/50 passed,
which is why it went unnoticed, and the "6 rows, 0 failures" recorded in §7
below could not have come from this code path. `permutations.sh` now parses the
last line as JSON exactly as `run-all.sh` does, with the `RESULT:` form kept as
a fallback, so the two harnesses cannot disagree about what the platform sees.

Found while reproducing, unrelated to the report: **every crewai release this
lab can use requires python <3.14.** On an image whose python is newer, the
pinned rung finds nothing and the unpinned fallback resolves to a 0.11-series
release with no `crewai.tools` in it — pip reports success, the readiness file
appears, and every correct solution scores zero at import. The warm-up now
exits 3 on a missing `crewai.tools`, `deps.state` records `unusable`, and setup
warns loudly instead of reporting a good install. The VM in production is
python 3.13 and resolves 0.203.2, confirmed by `crewai --version` on a live
lab, so this is a guard against a future image rather than a live failure.

## 10. Not settled on this host

- **Root ownership**: vacuous with no `user` account. Run the matrix as root on a
  provisioned VM once.
- **The real install duration on the portal network**, and the first-minute
  window before `import crewai` works. Measured only on the authoring host and in
  an emulated amd64 container.
- **CrewAI version drift.** The lab pins `crewai>=0.130,<1.0` and resolves to
  0.203.2 today. If a future release switches to native function calling, the
  model already answers that convention — but the text-protocol path is the one
  exercised here, so re-run `sweep.sh` after any resolver change.
