# `westmere-claims` — validation record

Everything below was **run**. Where a number could not be obtained on the
authoring host, this file says so rather than implying it was.

Authoring host: macOS, CPython **3.13.13** in a venv holding the exact pin set
the lab installs. Target VM: *systemd Ubuntu*, Ubuntu 25.04 / Python 3.13.3.

## 1. The pin set installs on the target interpreter

```
langchain 1.2.15
langgraph 1.1.9
langchain-core 1.3.0
langchain-openai 1.1.16
langgraph-checkpoint-sqlite 3.0.3
openai 2.32.0
pydantic 2.13.3
```

`pip install --only-binary=:all:` of that set on **Python 3.13** resolved with
no conflicts in **59 s** including the pip upgrade. `langchain-openai` and
`openai` are not needed by the lab — the kit ships its own `BaseChatModel` — and
are not in the setup script's install list.

Verified directly against the pinned stack before any lab code was written:
`add_messages`, `operator.add` and a custom clamping reducer all behave as the
tasks require, and `SqliteSaver.from_conn_string` persists across a reopen
(`run1 steps 1` → `run2 steps 2`, six checkpoints in the history, 20 480-byte
store).

## 2. Reference solution

`PY=<venv> ./test-cases/scripts/run-all.sh`

```
SCORE: 50/50   (passed 5, failed 0)
slowest test case: 2s   (portal limit is about 120s)
```

## 3. Alternative correct shapes — all 50/50

- `alt1_no_lcel` — structured output with no prompt template and no pipe.
- `alt2_command_router` — `Command(goto=..., update=...)` from the classify node
  instead of a second conditional edge.
- `alt3_manual_argv` — no `argparse`; a hand-rolled flag scanner.
- `alt4_two_graphs` — only the re-triage loop in a graph; classify and dispatch
  in plain Python, with the clamp applied by `min()` rather than by a reducer.
- `alt5_class_desk` — the settlement retry as a class.

Five shapes, four of them structurally different from the reference, all full
marks. `alt4` is the interesting one: it clamps in Python rather than in a
reducer and still scores 50, because the check grades the number reported, not
how it was produced.

## 4. Defect probes — each loses exactly its own theme

- `_defect1_text_router` — branches on the word *fraud* in the narrative.
  **40/50, `script_02`** (WM-3185 routed to `fraud_review`).
- `_defect2_no_cap` — no attempt cap on the re-triage loop. **40/50,
  `script_03`.**
- `_defect3_no_clamp` — step counter reducer is plain addition. **40/50,
  `script_03`** (reports 5 where the ceiling is 4).
- `_defect4_settle_overrun` — retry budget of six instead of three. **40/50,
  `script_04`.**
- `_defect5_memory_saver` — `InMemorySaver` behind a stand-in that still creates
  the file. **40/50, `script_05`**: *the second turn on the same thread reported
  turn=1 instead of 2*.
- `_defect6_shared_thread` — ignores `--thread`. **40/50, `script_05`.**
- `_defect7_replay` — re-sends every earlier human turn before the new one.
  **40/50, `script_05`** (desk answered 6 turns, not 3).
- `_defect8_tool_args` — hands `claim_id` to all three branch tools; two of them
  take other arguments and raise. **30/50, `script_02` and `script_03`.** Added
  from a real submission (see §8); it is the fixture the diagnostics row of the
  ordering matrix runs against.

Eight probes. Seven lose exactly one theme; `_defect8` loses two because the
same mistake sits in two branches, and both routing checks reach one of them. A
learner who gets four themes of five loses 10 points, not 50.

## 5. Fabrication probe

`_cheat_hardcode` prints the correct record, route, audit trail, settlement and
notes for every graded claim, written out by hand, and never contacts the desk.

**0/50.** Every theme cross-checks the desk trace: a desk that received no
requests cannot have produced any record, no tool ran on any branch, the
structured-request count is zero where the attempt count says otherwise, and no
thread state exists to recall.

## 6. Ordering matrix

`./validation/permutations.sh` — **8 rows, 0 failures**:

1. starter untouched → 0/50, refused in about a second.
2. written but never run by the learner → 50/50 (the checks run the program
   themselves; nothing here is bootstrapped *for* them, it is simply executed).
3. the learner ran it first, then graded → 50/50.
4. grading killed after three checks → 30/50, and the learner can still write to
   their own store.
5. graded a second time → 50/50.
6. graded a third time → 50/50, store grown to 81 920 bytes, score unmoved.
7. store deleted between runs → 50/50, recreated from scratch.
8. a submission that crashes inside one branch (`_defect8_tool_args`) → the
   verdict is `failed`, it reports the real non-zero exit status, it names a log
   file that exists, and that log holds the traceback from the branch that
   crashed. This row is the regression guard for the last two entries in §8;
   against the pre-fix scripts
   it fails three of its four assertions.

Rows 4, 6 and 7 each additionally ran the learner program **as the learner**
afterwards and it succeeded, which is the check that a root grading pass has not
taken ownership of the store.

## 7. Interpreter starts per check

Counted, because on this platform grading cost is interpreter starts rather than
computation:

- `script_01` 3, `script_02` 3, `script_03` 2, `script_04` 2, `script_05` 4.

All numbers above were re-confirmed after those fixes: reference and all five
alternative shapes 50/50, the seven single-theme defect probes at 40/50 losing
exactly one theme each, `_defect8_tool_args` at 30/50, the fabrication probe
0/50.

Fourteen in total across a grading run, and never more than four in one check.
The learner program is executed once per graded case and never re-run to
re-observe something already recorded. The desk trace, not a second run, is what
supplies the call counts.

Because five per-call bounds would sum past the portal cap, `run_ctl` shares one
`HARD_DEADLINE` of 100 s across every invocation a check makes and shrinks each
call bound as that deadline approaches.

## 8. Bugs found and fixed during validation

- **The amount comparison was textual**, so a program returning `1180.0` where
  the desk quotes `1180` was marked wrong. Both sides are now compared as a
  number scaled to whole pence.
- **`WESTMERE_DESK_URL` was not exported into the learner run.** On the VM the
  default and the real desk are the same address so nothing showed, but any
  harness on another port had the program dialling 8571 while the check read a
  different desk — which reads as a broken candidate. The check now exports the
  desk address it is itself using.
- **`setsid` does not exist on macOS**, so `ensure_service` silently never
  started the desk and each check burned its whole wait budget before failing.
  Found while validating `orenford-newsroom`, where the same code cost a nine
  minute permutation run; fixed in both packs with a `spawn_detached` helper that
  falls back to `nohup`. Same class of bug as an inert `timeout`: a spawn that
  quietly does nothing.
- **The starter was not recognised as untouched.** The refusal required the
  absence of `get_chat_model`, and the starter's own docstring mentions it, so a
  learner who submitted immediately got five slow failures instead of one fast
  refusal naming the cause. Now keyed on the starter sentinel sentence alone.
- **`run-all.sh` silently reused a desk already on the port.** One sweep row was
  graded against a desk on its way out and reported 0/50 for a candidate that
  actually scores 40/50. It now refuses unless `REUSE_DESK=1`, and `sweep.sh`
  steps past any port that answers.
- **Reported from the portal: a failing verdict named neither the exit code nor
  the log.** A submission whose branch nodes handed `claim_id` to all three desk
  tools crashed inside `fraud_review`, and `script_02` reported *printed no JSON
  object (exit 0); its output is in* — a status that was never true and an empty
  path. Cause: every call site read the program's output as
  `got="$(run_ctl ...)"`, so the whole function ran in a subshell and `LAST_RC`,
  `LAST_LOG` and the `CALLN` counter all died with it. The counter never
  advancing had a second effect: all invocations of a check wrote to
  `/tmp/westmere_out_<tc>_1.log`, each clobbering the evidence from the one
  before. `run_ctl` now leaves the JSON in `RUN_OUT` and is called as a
  statement, and the counter is bumped inline instead of through
  `out="$(learner_log)"` — the same subshell trap one level down. Grading
  outcomes are unchanged (the sweep matrix is identical); only the diagnosis is.
- **The statement showed one tool call, and it was the odd one out.** The kit
  summary listed `kit.policy_lookup, kit.payout_table, kit.fraud_history` as
  bare names while giving every other kit entry its arguments, and the only
  worked tool call anywhere in the statement was Task 3's
  `kit.policy_lookup.invoke({"claim_id": ...})` — the one tool of three that
  takes a claim id. That is the wrong generalisation, and it is the one the
  reported submission made. All three call shapes are now in the kit summary.
- **`check_local.py` never exercised `fraud_review`.** Its two `route` cases hit
  `fast_track` and `adjuster`; no shown claim had a fraud score at or above 0.7,
  because both that did were graded. So the pre-flight the statement tells the
  learner to run could pass with a third of task 2 never executed — exactly how
  the reported submission reached the portal. Added `WM-3126` (theft, fraud
  0.76, shown but not graded) with its record, policy limit, quote and prior
  claims, and a `route` case for it. The local checker is now 9 cases and covers
  every branch; on the reported submission it reports two failing routes instead
  of one.
- **`permutations.sh` scored every row 0/50 and nobody noticed**, because
  `grade()` grepped for `^RESULT:success` — the fallback format the scripts emit
  only when no `common.sh` is found, and one always is. Every ordering row was
  therefore vacuous. It now reads the last line as JSON the way the judge and
  `run-all.sh` do; the eight rows genuinely assert their scores.

## 9. Not settled on this host

- **Root ownership.** The rows above assert that nothing under the project is
  root-owned after full, partial and repeated grading runs, but with no `user`
  account on the authoring host those assertions **self-report as vacuous**. Run
  the matrix **as root on a provisioned VM once** before the first cohort. The
  store is the specific risk: `state/claims.db` is pre-created as `user` in
  setup and every check chowns the project back from an `EXIT` trap.
- **Cold-import cost on the VM.** Every check here finished in 1–2 s on a warm
  authoring host. On the VM the first `import langgraph` is several seconds, which
  is why setup warms it in the detached job. The real per-check wall clock has
  not been measured on the image; each check records its own in
  `/tmp/westmere_timing.log`.
- **Setup wall clock on the real image**, and the actual duration of the pinned
  install on the portal network. The internal deadline is 95 s and the script
  prints `total setup time` on every run.
