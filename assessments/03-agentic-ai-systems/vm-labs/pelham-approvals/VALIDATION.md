# `pelham-approvals` — validation record

Run on macOS, CPython 3.14.6 in a virtualenv with `langgraph` 1.2.11 and
`langchain-core` 1.6.0, against the pack's own harnesses. Numbers are observed.

## 1. Reference solution

    PY=<venv>/bin/python bash test-cases/scripts/run-all.sh
    SCORE: 50/50   (passed 5, failed 0)
    slowest test case: 1s   (portal limit is about 120s)

Also verified **cold**, with no service running at all, so every check had to
start and stop its own: five successes, and the port free afterwards.

## 2. Alternative correct shapes — all 50/50

- `alt1_closure_nodes` — the three stages carried on an object, wired in as
  bound methods.
- `alt2_dispatch_server` — a different routing style in the service.
- `alt3_reducer_state` — `Annotated[..., operator.add]` on the audit log and the
  intentions, so nodes return only what they added.
- `alt4_verbose_audit` — audit entries in a completely different house style,
  which is what confirms the log is graded on the stages it records rather than
  on its wording.
- `alt5_envelope_server` — extra fields in both responses.

**One candidate was dropped rather than accommodated.** `StateGraph(dict)` looks
like a reasonable alternative schema and scores **20/50**: the fields are not
retained, so beliefs come back empty and the interrupt payload is `{}`. That is
a real limitation of the framework, not a false negative in the checks, so the
alternative was removed instead of the assertions being loosened.

## 3. Defect probes

Five lose exactly their own theme at 40/50:

- `_defect1_thin_beliefs` — beliefs omit the policy the decision was measured
  against → check 1.
- `_defect2_model_desires` — desires generated from the analysis, so they change
  per claim → check 1.
- `_defect3_amount_only` — routing on the threshold alone, ignoring the
  analyst → check 2.
- `_defect6_replay_allowed` — a decided thread resumed again → check 5.
- `_defect7_unknown_accepted` — a callback for a thread that does not exist
  answered `200` → check 5.

Two are honest two-theme losses at 30/50:

- `_defect4_premature_status` — a final status written before the pause. Loses
  check 3, and check 5 as well, because a claim awaiting an unrecognised
  decision then already carries a status.
- `_defect5_log_replaced` — `finalize` returns a fresh log instead of appending.
  Loses check 4, and check 1, because the log then holds one entry.

An eighth probe was written and **discarded**: setting `state["final_status"]`
before calling `interrupt()` inside `human_review` is not expressible — a node's
return value is only produced after the resume, so the mutation never reaches
the graph. It scored 50/50, which is what sent us looking. The defect had to
move into `deliberate` to be real.

## 4. Fabrication probe

- `_cheat_no_graph` — an approval service that keeps claims in a dict and never
  runs an agent. **30/50**: it passes the pause, resume and callback-safety
  themes, and fails checks 1 and 2, which require the analyst to have been
  consulted. Worth stating plainly: three of the five themes here are about
  service behaviour and a careful fake can reproduce them. The two that need a
  model call are what separate them.

## 5. The port, and what grading must not take away

The first version of the ordering matrix reported, on rows 4 and 6, that
something was still listening on the learner's port after grading. The cause was
in the harness, not the checks:

    ( cd X && VAR=1 cmd >log 2>&1 & echo $! >pid )

records the pid of the **wrapper list**, not of the program. Killing it left the
service running; every later row then reused a service nobody owned.
`( cd X && exec env VAR=1 cmd >log 2>&1 ) &` followed by `echo $!` records the
program. The check scripts were always correct here — their `&` sits inside
`spawn_detached` and applies to the command alone — but the same mistake in a
harness is what made the bug visible.

## 6. Ordering matrix

    ./validation/permutations.sh
    rows: 6   failures: 0

Rows: starters untouched (0/50) · written but never run (50/50) · **learner left
their own service running** (50/50, and that service is still running
afterwards) · grading killed after three checks (30/50) · graded a second time
(50/50) · graded a third time with thread ids that must not collide (50/50).
Every row that can also asserts the learner can start their own service on the
port afterwards, and all of those passed.

## 6b. The VM end-to-end row - with nothing overridden

    ./validation/vm-e2e.sh            # cold ubuntu:25.04 container
    ./validation/vm-e2e.sh --here     # as root on the VM itself

    failures: 0   (setup 15s foreground, deps +60s detached)

Provisions a cold root filesystem from `dist/Setup.zip`, waits for the detached
LangGraph install to publish its readiness file, submits the untouched starter
straight away, writes the reference solution as `user`, submits again, and
asserts the learner still owns their project and their port. **Nothing is
overridden** - `LAB_DIR`, `SVC_URL`, `DESK_URL` and `DESK_BIN` keep the values
the checks ship with.

Observed: setup returns in 15 to 20s of foreground time; `jq` is already present
when it does, so a check can print a verdict; `/var/log/pelham-lab/deps.ready`
arrives 40 to 60s later with `deps.state` = `pinned`, and `langgraph` then
imports; the desk answers `/health` on 8766 straight out of provisioning; the
untouched starter scores 0/50 with all five checks naming the starter; the
reference solution then scores **50/50** in 10 to 11s; nothing under
`/home/user` is root-owned after two grading runs; port 8767 is free again and the learner can
start their own service on it.

This row exists because sections 1 to 6 above are all blind to the defect that
mattered most in this pack. All three of `run-all.sh`, `sweep.sh` and
`permutations.sh` export `LAB_DIR`, so the shipped default was never once
exercised - and that default read `/home/user/pelham-rubric`, a project
belonging to a different lab, while setup builds `/home/user/pelham-approvals`. Every local
harness was green while the portal could only ever have reported five missing
files.

The row also fails loudly on the empty-panel shape. With `trap - ERR` and
`set +eE` stripped out of the five checks, the harness reports **1 failure** and
prints the reason:

    script_01.sh   LAST LINE IS NOT A VERDICT: INTERNAL_ERROR: An error occurred at line 468: 'return' exited with status '1'

Note which run catches it: the reference solution still scores 50/50, because
the happy path never returns non-zero from a guard. It is the learner whose code
is refused who gets no results at all, which is exactly why no run-the-solution
harness could see this.

## 7. Open items

- The root-ownership invariant is **vacuous off the VM** in
  `permutations.sh` - no `user` account on this host. `vm-e2e.sh` covers it
  instead: the container it spawns gets the `user` account setup creates, so the
  row asserting nothing under `/home/user` is root-owned is real there. Run
  `validation/permutations.sh` as root on the image once before the first cohort
  all the same. In this pack the on-disk exposure is small (the learner writes no
  files), and the port rows are the ones carrying the weight.
- The setup script's wall clock on the real image is still unmeasured; the 15 to
  20s above is a container with no systemd behind it. This pack has the heaviest
  install of the five — `langgraph` plus `langchain-core` — so its
  `deps.ready` arrives latest and the check-side `DEPS_WAIT` is 90s to match.
  Read the number off `/var/log/pelham-lab/setup.log` on the first provisioning
  run.
