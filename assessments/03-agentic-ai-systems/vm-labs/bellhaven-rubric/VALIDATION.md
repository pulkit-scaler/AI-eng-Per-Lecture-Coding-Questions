# `bellhaven-rubric` — validation record

Run on macOS, CPython 3.14.6 in a virtualenv with `sympy` 1.14.0, against the
pack's own harnesses. Numbers are observed.

## 1. Reference solution

    PY=<venv>/bin/python bash test-cases/scripts/run-all.sh
    SCORE: 50/50   (passed 5, failed 0)
    slowest test case: 1s   (portal limit is about 120s)

Check 5 makes three interpreter starts (two gate runs plus a probe); the rest
make one each. The shared `HARD_DEADLINE` is 100s.

## 2. Alternative correct shapes — all 50/50

- `alt1_sorted_dataset` — a stable ordering, no randomness anywhere.
- `alt2_equals_metrics` — `.equals()` instead of simplifying a difference, and a
  float comparison in `exact_match`.
- `alt3_scanner_judge` — a JSON scanner instead of patterns, and the prompt laid
  out in a different order.
- `alt4_counter_ensemble` — kappa via `collections.Counter`.
- `alt5_manual_gate` — hand-rolled `sys.argv`, an extra `thresholds` section in
  the report.

## 3. Defect probes

Four lose exactly their own theme at 40/50:

- `_defect1_drops_stress` — stress tests sampled like everything else → check 1.
- `_defect3_no_trace` — the working left out of the grading prompt → check 3.
- `_defect4_kappa_degenerate` — kappa returns 1.0 where it is not computable
  → check 4.
- `_defect5_no_kappa_gate` — the gate never looks at agreement → check 5.

Three are honest two-theme losses at 30/50, each for a reason worth stating:

- `_defect2_no_symbolic` — the second metric is the first one renamed. Loses
  check 2, and check 5 as well, because the report then claims the symbolic
  metric recovered nothing.
- `_defect6_majority_vote` — a disagreement resolved by taking the first
  grader. Loses check 4, and check 5, because the review queue comes out empty.
- `_defect7_parse_optimistic` — an unreadable reply scored as correct. Loses
  check 3, and check 5, because that one reply moves kappa and the queue.

## 4. Fabrication probe

- `_cheat_hardcoded_report` — writes the report with the right numbers baked in,
  reading `--min-kappa` so even the failing arm looks right. **40/50**: check 5
  reads the desk's own record and reports "the desk was sent 0 grading prompts
  for a report covering 12 items with two graders".

## 5. The numbers the checks are built on

Confirmed by running the reference gate against the graded pool:

    exact_match 0.333   symbolic_match 0.750   ensemble_strict 0.750
    judge_nyx 0.833     judge_vale 0.750
    kappa 0.750         observed 0.9166...     review ["bh-104"]

and against the shipped sample pool, which a learner has to be able to pass:

    size 8   exact_match 0.250   symbolic_match 0.625   ensemble_strict 0.625
    kappa 0.7142...  observed 0.875   review ["sm-205"]   exit 0

The sample pool is sized so **both** graders use both labels. An earlier draft
had every sample verdict identical, which made kappa undefined and meant a
correct solution could never get a clean local run.

## 6. Ordering matrix

    ./validation/permutations.sh
    rows: 7   failures: 0

Rows: starters untouched (0/50) · written but never run (50/50) · learner ran
the gate first (50/50) · grading killed after three checks (30/50) · graded a
second time (50/50) · report deleted between runs (50/50) · `reports/` removed
entirely (50/50). Every row that can also asserts the learner can still run
their own gate afterwards, and all of those passed.

## 6b. The empty portal panel, 2026-08-31 — and what fixing it uncovered

A learner submitting on the portal saw an empty *Test Case Results:* list: a
green tick, no rows, no messages. The cause is the judge's ERR trap, already
written up in `vm-labs/DESIGN-NOTES.md` for seven other packs on 2026-08-26 —
a migration this pack never received.

The platform helper at `/usr/local/bin/judge/test/common.sh` ends with

    trap 'handle_script_error $LINENO $? "$BASH_COMMAND"' ERR

and sourcing it installs that trap inside the check's own shell. It fires on any
non-zero simple command regardless of `set -e`, a deliberate `return 1` from a
guard included, and its handler prints an internal error and exits. `main.sh`
grades `tail -n 1` of stdout+stderr, so the verdict is discarded and the
submission is posted with no results array.

Measured, on the refusal path, against a faithful replica of the real helper —
all five checks:

    INTERNAL_ERROR: An error occurred at line 421: 'return' exited with status '1'
    INTERNAL_ERROR: An error occurred at line 393: 'return' exited with status '1'
    ... one per check, each landing after a correct verdict

**Fixed** in the shared preamble: `trap - ERR` and `set +eE` immediately after
sourcing the helper, and `exec 2>>/tmp/bellhaven_tc${TC}.err` so a stray line on
stderr cannot become the graded line either.

**Why sections 1 to 6 said 50/50 throughout.** The local `common.sh` was a
convenience stub — `echo "RESULT:$1 | $2"`, no ERR trap, no JSON — and both
harnesses looked for a verdict *anywhere* in the output. A stub easier to satisfy
than the real helper makes validation worthless. Now: `common.sh` is a
byte-for-byte copy of the replica, `run-all.sh` grades the **last** line as JSON
and flags an unparseable one, and `permutations.sh` asserts the **shape** of the
last line on every row — separately from the score, because a voided verdict and
an honest failure both score zero.

Proven negative: with `trap - ERR` removed, row 1 of the matrix reports all five
checks ending on `INTERNAL_ERROR` and goes red, while the reference solution
still scores 50/50 in that state — which is exactly why the happy path never
caught this.

### Two more defects, both found by fixing the harnesses

1. **`jq` arrived too late to print a verdict.** The helper builds its one line
   with `jq -n`, and `jq` came only from the *detached* install job, which
   finishes after the learner can already press Submit. A check running before it
   lands cannot emit a verdict at all: another empty panel from a different
   direction. Setup now installs `curl` and `jq` in the **foreground** (14s total
   against a 95s budget), `ensure_deps` no longer treats their presence as a
   proxy for "the install resolved", and a new `require_sympy` guard reports a
   missing `sympy` as an environment fault naming `deps.log` rather than as the
   learner's module failing to import.

2. **The checks left a root-owned report in the learner's project.** This is the
   hazard this file's own §6 header warned about, and the matrix was written to
   catch it — but the assertion was **vacuous on the authoring host**, and the
   `on_exit` hand-back was gated on `case "$LAB_DIR" in /home/user/*)`, which the
   matrix's own `/tmp` path never matched. So the one harness meant to catch a
   root-owned project could not. Run as root on Ubuntu with a real `user`
   account, rows 6 and 7 failed: after the learner deletes `reports/eval.json`,
   TC05 ran the gate with `--out reports/eval.json` *inside the project*, root
   recreated it, and the learner could never rewrite it again.

   Fixed at both layers, as `grading-integrity.md` requires. **Prevention:** the
   graded run now writes to `${WORK}/reports/eval.json`, a directory the check
   owns — the gate still has to create it, so `--out` is tested more honestly
   than before, and nothing lands in the project at all. **Repair:** `on_exit`
   hands ownership back whenever a `user` account exists, rather than only when
   the project happens to sit under `/home/user`.

## 6c. The VM end-to-end row — with nothing overridden

    ./validation/vm-e2e.sh            # cold ubuntu:25.04 container
    ./validation/vm-e2e.sh --here     # as root on the VM itself

    failures: 0   (setup 14s foreground)

Provisions a cold root filesystem from `dist/Setup.zip`, installs the **replica**
helper at the platform's own path, submits the untouched starter straight away,
writes the reference solution as `user`, submits again, and asserts the learner
still owns their project. **Nothing is overridden** — `LAB_DIR`, `DESK_URL` and
`DESK_BIN` keep the values the checks ship with, which `run-all.sh`, `sweep.sh`
and `permutations.sh` all export and therefore never exercised once.

Observed: setup returns in 14s; the desk answers `/health` straight out of
provisioning; `jq` is present before any check runs; the untouched starter
scores 0/50 with every check naming the starter and **every check ending on a
parseable verdict**; the reference solution then scores 50/50; nothing under
`/home/user` is root-owned after two grading runs, and the learner can still run
their own gate.

### The ordering matrix, no longer vacuous

    rows: 7   failures: 0

Run as root in `ubuntu:25.04` with a real `user` account and `sympy` installed.
Every ownership row now reports *nothing under the project is root-owned*
instead of self-reporting as vacuous, and every row also asserts the verdict
shape. This closes the first open item in §7.

## 7. Open items

- ~~The root-ownership invariant is vacuous off the VM.~~ **Closed, and it was
  hiding a real bug** — see §6b defect 2. `validation/permutations.sh` now runs
  as root on Ubuntu 25.04 with a real `user` account: rows 7, failures 0, with
  every ownership row asserting rather than self-reporting.
- ~~The setup script's wall clock on the real image is unmeasured.~~ **Measured
  enough to ship.** 14s of foreground time in a cold `ubuntu:25.04`, against a
  95s internal budget; `curl` and `jq` are now part of that foreground cost.
  The detached `sympy` install resolves a further ~10s later, which is what the
  first submission waits on — 12s, measured. Still read
  `/var/log/bellhaven-lab/setup.log` on the first real provisioning run: the
  portal image is not this container.
- The container has no systemd, so phase 6's unit path is exercised only by
  `build.sh`'s static check and the desk comes up through the `nohup` fallback.
  Confirm `systemctl status bellhaven-desk` on the first real VM.
