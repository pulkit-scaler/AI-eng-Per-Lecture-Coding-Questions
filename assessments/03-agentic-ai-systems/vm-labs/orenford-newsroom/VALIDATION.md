# `orenford-newsroom` — validation record

Everything below was **run**. Where a number could not be obtained on the
authoring host, this file says so.

Authoring host: macOS. Two venvs, each holding the exact pin set the lab
installs (`langchain 1.2.15`, `langchain-core 1.3.0`, `langgraph 1.1.9`,
`langgraph-checkpoint-sqlite 3.0.3`, `pydantic 2.13.3`):

- **CPython 3.13.13** — matches the target VM's 3.13.3 to the minor version.
  Every headline number below is from this one.
- **CPython 3.14.6** — the whole sweep and the ordering matrix were run again on
  it. Identical results, so nothing here depends on the interpreter's minor
  version.

Target VM: *systemd Ubuntu*, Ubuntu 25.04 / Python 3.13.3.

## 1. Reference solution

`PY=<venv313> ./test-cases/scripts/run-all.sh`

```
SCORE: 50/50   (passed 5, failed 0)
slowest test case: 2s   (portal limit is about 120s)
```

The reference service was also driven by hand across every special assignment,
and each answer matched the wire oracle field for field: a normal assignment
(3 findings, 6 calls), a desk out of service (2 findings, 5 calls), a draft never
accepted (2 revisions, 10 calls, `published_with_reservations`), a barred source
(2 findings, the third recorded as excluded), and one round of rework (8 calls).

## 2. Alternative shapes — all 50/50

- `alt1_supervisor` — a supervisor walking the desks one at a time instead of a
  fan-out.
- `alt2_flat` — the three desks as top-level nodes, no nested team graph.
- `alt3_plain_research` — the research pass in plain Python, the newsroom still a
  graph.
- `alt4_dedupe_at_the_end` — accumulate everything, dedupe once at the end,
  instead of a deduplicating reducer.
- `alt5_class_newsroom` — the compiled graph held as an object by the service.
- `alt6_no_graph` — **no LangGraph at all**: functions calling functions, a list
  for the findings, a `while` loop for the night editor. Added because the README
  claimed a plain Python solution scores full marks and no such submission had
  actually been graded. It does: **50/50**.

Five genuinely different topologies, two different merge strategies, and one
submission that never imports the framework, all at full marks. That is the
intended outcome — the checks grade the outcome, not the topology — and the
statement, the README and the instructor guide all say so.

## 3. Defect probes

Single-theme losses:

- `_defect2_no_containment` — the desk step does not catch `WireError`.
  **40/50, `script_02`.**
- `_defect3_unbounded_critic` — no cap on the night editor loop. **40/50,
  `script_03`.**
- `_defect4_cite_blocked` — a barred source is cited. **40/50, `script_04`.**
- `_defect5_guessed_accounting` — the accounting block is written out in advance.
  **40/50, `script_05`.** This probe originally scored 50/50 because it happened
  to guess the graded assignment correctly; `script_05` now commissions a second
  assignment that takes a round of rework, so no fixed block of numbers is right
  for both.
- `_defect8_missing_key` — a correct briefing that omits one documented response
  key (`audit`). **40/50, `script_01`.** Added when the requirement sweep found
  that the response-key list was stated as a rule and graded nowhere.

Honest multi-theme losses:

- `_defect6_one_role` — every call booked to the planner. **30/50,
  `script_03` and `script_05`**, because the role tags are what both checks read
  their call counts from.
- `_defect7_two_desks` — only two of the three desks ever consulted.
  **10/50**, losing checks 1, 2, 4 and 5, because most of the briefing depends on
  the third desk.

And one instructive total loss:

- `_defect1_no_reducer` — the findings key given no reducer at all. **0/50**:
  LangGraph refuses a fan-out whose parallel branches write an unreduced key, so
  the service returns 500 on every commission.

## 4. Fabrication probe

`_cheat_hardcode` returns a correct-looking briefing for every graded
assignment — right sub-questions, right sources, right exclusions, right
accounting — computed locally, and never contacts the wire.

**0/50.** Every theme cross-checks the wire trace. Check 4 is the one that had to
be strengthened for this: it originally asserted only on the response and the
probe passed it, so it now also requires that the barred source's desk was
actually asked.

## 5. Ordering matrix

`PY=<venv313> ./validation/permutations.sh` — **6 rows, 0 failures**:

1. starter untouched → 0/50, refused in about a second.
2. written, service not running → 50/50 (the checks start it).
3. the learner started it, then graded → 50/50.
4. grading killed after three checks → 30/50.
5. graded a second time → 50/50.
6. service killed between grading runs → 50/50.

Rows 2, 3, 4 and 6 then start a service as the learner and run `check_local.py`
against it, which is the no-lockout assertion: grading takes its own service down
on the way out, so the port is free for them.

**A previous edition of this file claimed the same 6/0 and was wrong.** The
harness grepped each check's output for `RESULT:success`, the fallback format
used only when the platform helper is missing; with the replica `common.sh` in
place the checks emit JSON, so `grade()` could never see a success and every row
that expected 50/50 was scoring 0. The row list looked plausible and the matrix
had not really been run. `grade()` now reads the JSON verdict and accepts the
fallback too.

## 6. Bugs found and fixed

Earlier rounds:

- **`bounded` wrapped around `curl` raced the command substitution.** The
  background job and the closing subshell produced an empty body with a **zero**
  exit — indistinguishable from a service that answered nothing. `curl` carries
  its own bound with `-m`, so the wrapper is gone.
- **`setsid` does not exist on macOS**, so the service start silently never
  started anything and every check burned its whole 20 s wait. Both this pack and
  `westmere-claims` now go through a `spawn_detached` helper that falls back to
  `nohup`.
- **The starter was not recognised as untouched**, because the refusal required
  the absence of `get_chat_model` and the starter's own docstring mentions it.
  Now keyed on the sentinel sentence alone.
- **Four graded assignments appeared in the worked examples.** `build.sh` caught
  it; three new assignments were added so the statement can show a desk-out case,
  a never-accepted case, a barred-source case and a one-round-of-rework case
  without naming an assignment the checks use.

This round — everything below was found by grading real learner attempts and by
a requirement-by-requirement sweep of the statement:

- **The service under test was not restarted, so grading could grade code that
  was no longer on disk.** A learner who edited `serve.py` without restarting the
  process was graded on the version still in memory. Every check now stops
  whatever is listening and starts `serve.py` as it stands, so the file on disk is
  always what gets marked.
- **`/tmp/orenford_serve.log` went stale and stayed stale.** The checks only
  opened it when they had to start the service themselves; with the learner's own
  service up it was never reopened, so a failure pointed at a traceback from an
  earlier submission — the same one, edit after edit, until the VM was restarted.
  Each check now truncates it before starting the service it owns.
- **Every failure said "returned nothing (exit 0)".** `LAST_RC` was assigned
  inside a command substitution, so the caller never saw it; a 500, a timeout and
  a refused connection all printed the initial 0. The verdict now names which,
  and carries the exception from the 500 body (`curl -f` had been throwing that
  body away).
- **Killing the service by command-line pattern would have killed a learner's
  editor.** `pkill -f serve.py` matches `vim serve.py`. The kill is now by port,
  with a python-and-filename pattern only as a last resort.
- **Grading would have left a root-owned service holding port 8300.** The learner
  is `user` and could neither kill it nor bind over it: their next
  `python3 serve.py` would have died on an address already in use with no way out.
  Each check now takes its service down from the `EXIT` trap.
- **The kit silently dropped extras passed to `.invoke()`.** A submission that
  passed `desk=` to `invoke` instead of to `with_structured_output` sent a body
  with no desk in it and got a 422 saying the wire did not know which desk — while
  the learner could see the desk in their own code. Both spellings now reach the
  wire.
- **The wire dispatches on the model's class name and nothing said so.** A
  finding model called `Evidence` failed with "the desk does not fill in that
  record". The names are now in the interface contract, in the kit docstring, and
  in the error itself. The missing-desk error names the three desks too.
- **`kit.research_prompt` was the one prompt helper whose signature the statement
  never gave** — the other three appear in full in their own tasks. It is now in
  Task 2, `note` and all.
- **`cited=<the findings>` did not say the extras are JSON.** Passing model
  objects raised `TypeError: Object of type Finding is not JSON serializable`.
  Task 3 now says plain dicts.
- **The oracle contradicted the wire on a barred source.** `brief_expectation`
  reported `researcher: len(findings)` while the wire had really received one call
  per desk that answered, so on `OR-4171` / `OR-4224` the accounting check's two
  assertions could not both hold — not even for the reference solution. The
  oracle now counts desks that answered, and because that figure is a design
  choice on those assignments rather than a rule, **`build.sh` asserts the
  accounting check only ever grades assignments with no desk down and no source
  barred.** Verified the assertion fires: pointing check 5 at `OR-4171` fails the
  build.
- **Two rules were stated and graded nowhere.** The documented response keys are
  now checked by `script_01` (`_defect8_missing_key` proves it discriminates).
  "Make the reducer drop a source already reported" is demoted to what is actually
  graded — no duplicate sources in the findings — since `alt4` dedupes on the way
  out and scores full marks.

## 7. Interpreter starts and requests per check

Each check starts the service once and stops it on the way out: five starts per
grading run, about a second each on the authoring host. Briefings commissioned
per check: 1, 1, 2, 1, 2 — seven in total, each one HTTP request. The wire trace,
not a second commission, supplies the call counts. Per-check wall clock on the
authoring host is 1–2 s (`/tmp/orenford_timing.log`); one outlier of 9 s was
recorded once on a cold sweep, against a cap of about 120 s.

## 8. Curriculum alignment

The lab is **M3-L6, Multi-Agent Systems: Patterns & Orchestration**. Every API a
learner must write is taught at or before that class:

| Construct | Taught in |
|---|---|
| `StateGraph`, `START`, `END`, `add_node`, `add_edge`, `.compile()` | L4 LangChain & LangGraph Deep Dive; L5 Multi-Agent Systems |
| `add_conditional_edges` | L4; L5 |
| `TypedDict` state, `Annotated[list, reducer]` | L4; L5 |
| `operator.add` as a reducer, and "`Annotated[..., fn]` picks a custom reducer" | L4 |
| `with_structured_output(Schema)` | L4; L5 |
| `BaseModel`, `Field(min_length=…, max_length=…)` | L2 Pydantic; L5 |

(Markdown `L<n>` is curriculum `n+1` from L3 on, so markdown L5 is this class.)
Nothing in the reference solution or the starter uses a construct that only
appears in lecture output rather than as an API to call.

## 9. Not settled on this host

- **Root ownership.** The matrix asserts nothing under the project is root-owned
  after full, partial and repeated runs, but with no `user` account those rows
  **self-report as vacuous**. Run it as root on a provisioned VM once. Grading
  creates nothing under the project, and the service the checks start now runs as
  root only for the length of one check, but the `EXIT`-trap chown is still not
  optional.
- **The port is free after grading — proven only here.** The `EXIT` trap stops the
  service, and rows 2/3/4/6 start a learner service afterwards and drive it. On
  the VM the process being stopped is root-owned; confirm on the first real run
  that nothing is left listening on 8300.
- **Cold-import cost on the VM.** Checks finish in 1–2 s on a warm authoring
  host. On the VM the first `import langgraph` is several seconds, which is why
  setup warms it; the 20 s service-start wait is sized for that. With five service
  starts per run instead of one, per-check wall clock on the image is the number
  to watch — each check records its own in `/tmp/orenford_timing.log`.
- **Setup wall clock on the real image** and the pinned install duration on the
  portal network.
