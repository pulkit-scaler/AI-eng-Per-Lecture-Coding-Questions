# `norbury-flow` — validation record

Run on macOS with CPython 3.14.6 against the pack's own harnesses. Standard
library only, so the system interpreter runs everything. Numbers are observed.

## 1. Reference solution

    bash test-cases/scripts/run-all.sh
    SCORE: 50/50   (passed 5, failed 0)
    slowest test case: 1s   (portal limit is about 120s)

Check 5 makes five command-line invocations plus a probe, the most of any check
in the five packs, and still lands at 1s.

## 2. Alternative correct shapes — all 50/50

- `alt1_rules_spec` — the refusals expressed as a list of rule calls.
- `alt2_dfs_plan` — the order found by a depth-first walk instead of Kahn's
  algorithm.
- `alt3_class_runtime` — the runtime as an object rather than a dict.
- `alt4_manual_ctl` — hand-rolled `sys.argv` and a fuller run log.
- `alt5_walk_loop` — the agent loop written as a countdown rather than a `for`.

**`alt2` caught a real false negative.** Kahn's algorithm names both nodes of a
cycle in its refusal; a depth-first walk names one. Check 1 demanded a specific
one and failed a correct solution. It now accepts either end of the cycle.

## 3. Defect probes

Seven lose exactly their own theme at 40/50:

- `_defect1_accepts_unknown` — any component kind accepted → check 1.
- `_defect3_sends_placeholder` — the export's `***` used as the credential
  → check 3.
- `_defect4_drops_temperature` — the temperature stays in the JSON → check 3.
- `_defect5_no_cap` — the loop runs until the model stops asking → check 4.
- `_defect6_raw_observation` — out of steps, the last tool output handed back
  raw → check 4.
- `_defect7_always_remembers` — the conversation carries over whether or not the
  flow wires memory → check 5.
- `_defect8_no_run_log` — nothing written down → check 5.

One is an honest two-theme loss at 30/50:

- `_defect2_file_order_plan` — the plan is the order the nodes happen to appear
  in the file. It loses check 2, and check 1 as well, because `validate` leans
  on `plan` to detect a circle and a plan that never fails cannot detect one.

## 4. Fabrication probe

- `_cheat_canned_reply` — validates the flow properly, then answers from a fixed
  string without calling the endpoint at all. **20/50**: checks 3, 4 and 5 all
  read what the endpoint was actually handed.

## 5. What the endpoint measures

Per run it records the model and temperature it was given, the system prompt it
saw, the tool list it was offered, how many times the export placeholder was
presented as a credential, and how many wrap-ups were requested. That is what
makes the following gradeable rather than assertable:

- configuration reached the runtime (model `norbury-14b`, temperature `0.15`);
- the prompt node's text reached the model;
- exactly the three wired tools were offered, no more and no fewer;
- the placeholder was never sent — observed `placeholder_seen: 0`;
- a flow capped at two steps made exactly two tool calls and then asked for a
  wrap-up.

## 6. Ordering matrix

    ./validation/permutations.sh
    rows: 7   failures: 0

Rows: starters untouched (0/50) · written but never run (50/50) · learner ran
their own flow first (50/50) · grading killed after three checks (30/50) ·
graded a second time (50/50) · run logs deleted (50/50) · `runs/` removed
entirely (50/50). Every row that can also asserts the learner can still run
their own flow and get a log afterwards, and all of those passed.

Session ids in the checks carry a per-run nonce, so a second grading pass on the
same VM does not meet its own earlier conversations.

## 6b. The VM end-to-end row, with nothing overridden

    ./validation/vm-e2e.sh            # cold ubuntu:25.04 container
    ./validation/vm-e2e.sh --here     # as root on the VM itself

    failures: 0   (setup 10s foreground)

Provisions a cold root filesystem from `dist/Setup.zip`, installs the **replica**
helper at the platform's own path, submits the untouched starter straight away,
writes the reference solution as `user`, submits again, and asserts the learner
still owns their project. **Nothing is overridden**: `LAB_DIR`, `DESK_URL`,
`DESK_BIN` and `DEPS_READY_FILE` keep the values the checks ship with, which
`run-all.sh`, `sweep.sh` and `permutations.sh` all export and therefore never
exercised once.

Observed on `ubuntu:25.04`, cold, with only `unzip` and `python3` preinstalled:
setup returns 0 in 10s of foreground wall clock with no `LAB NOT READY`; `jq` is
present before any check runs, so the helper can print a verdict at all; the
model endpoint answers `/health` on `127.0.0.1:8788` straight out of
provisioning; the untouched starter scores 0/50 with every check naming the
untouched starter and **every check ending on a parseable verdict**; the
reference solution then scores 50/50; `check_local.py` validates and runs both
shipped flows for the learner with no `BAD` line; nothing under `/home/user` is
root-owned after two grading runs, and the learner can still run their own flow
and write `runs/learner-after.json`. Each check records `0s` in the timing log,
so the whole submission is far inside the portal's 120s cap.

### The negative test this row was written for

Stripping `trap - ERR` and `set +eE` from the five checks in a throwaway copy of
the pack, and bypassing only that one `build.sh` guard so the broken scripts can
be packaged, turns the row red on the starter submission:

    script_01.sh   LAST LINE IS NOT A VERDICT: INTERNAL_ERROR: An error occurred at line 527: 'return' exited with status '1'
    FAIL 5 check(s) did not end on a verdict; the portal would show an empty panel

Two things are worth reading off that. The score is **still 0/50** and every
message still names the untouched starter, because a voided verdict and an
honest failure both score zero: only the last-line assertion can see the
difference. And the second submission, with the solution written, scores a clean
50/50 with parseable verdicts throughout, because the success path never returns
non-zero and so never trips the inherited trap. The defect is invisible unless a
harness grades the last line on the refusal path, which is precisely the shape
this pack shipped with.

## 7. Open items

- The root-ownership invariant is still **vacuous under
  `validation/permutations.sh` off the VM**, because that harness runs wherever
  it is invoked and an authoring host has no `user` account. It is no longer
  unverified, though: `validation/vm-e2e.sh` provisions a container that does
  have one, and it reports nothing root-owned under `/home/user` after two
  grading runs. `runs/` is the directory at risk here, because the checks run
  `flowctl.py` from inside the learner project and it writes there.
- The setup script's wall clock is now measured, but on `ubuntu:25.04` in a
  container rather than on the portal image: 10s of foreground time, with `curl`
  and `jq` fetched on that path. This is the lightest of the packs, with no pip
  package at all. Confirm the number off `/var/log/norbury-lab/setup.log` on the
  first real provisioning run.
- `validation/permutations.sh` row 3 runs a `gate.py --pool data/pool_sample.json`
  command line that belongs to a different pack and does not exist here. Its
  output is discarded, so the row degrades to a second copy of row 2 rather than
  testing what it names: the learner running their own flow before grading.
  `validation/vm-e2e.sh` covers that ordering honestly in the meantime.
