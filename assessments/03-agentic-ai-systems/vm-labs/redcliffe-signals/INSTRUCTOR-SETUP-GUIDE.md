# Instructor setup — `redcliffe-signals`

## Portal configuration

- **Lab image:** *systemd Ubuntu*.
- **Setup script:** `dist/Setup.zip`. **Test cases:** `dist/TestCase.zip`.
- **Max Score: 50.** Five test cases, **10 points each**.
- **Problem statement:** `problem-statement.md`, pasted as-is. No tables.

## The easiest pack in the module to provision

Nothing outside the standard library. The detached job installs only `curl` and
`jq`, which the check scripts shell out to — there is no wheel to download, no
`--only-binary` ladder and no first-minute window where the lab does not work.
If you are piloting the module on a slow network, start here.

Foreground: python3 if missing, the project (`signal_kit/`, `signalctl.py`,
`check_local.py`, the three starters), **chowned to `user` immediately**, and the
control desk installed to `/opt/redcliffe-svc` (`root:root 0700`), started under
systemd on 8622.

It also **pre-creates `store/signals.jsonl` owned by `user`**. That is not
cosmetic: the checks run the learner program as root, writing a note *creates*
the store, and a root-owned store means the learner cannot append to it again.

## Time budgets

Each check: 12 (desk) + a shared **100 s `HARD_DEADLINE`** across every
invocation. The memory check runs the program six times, which is why the
deadline is shared rather than per-call. Observed slowest check on the authoring
host: **1 s**. Each check appends its wall time to `/tmp/redcliffe_timing.log`.

## What the checks touch

`store/signals.jsonl` and nothing else, always under session names unique to the
run so a learner's own notes are never read or overwritten. Every check chowns
the project back from an `EXIT` trap.

## Marking notes

The full list is in `README.md`. The three worth having to hand:

- **Five structurally different correct shapes all score 50/50.** If a learner
  asks why their recursive reviewer loop scored the same as a `while`, that is
  why: the checks grade the counts and the outcomes, not the control flow.
- **A loop that never advances the step number loses checks 1 and 2.** That is
  honest rather than harsh — the desk reads `step`, so such a loop cannot make
  progress on any question.
- **The canned-answers probe scores 20/50**, losing checks 1, 2 and 3 on the desk
  trace. It keeps the two memory checks because its memory module is real. Worth
  showing in review: the parts of a run that are cross-checked against a service
  are the parts that cannot be faked.

## Before the first cohort

Run `validation/permutations.sh` **as root on a provisioned VM** once. Seven rows
including three grading passes and a deleted store. On a real VM its ownership
assertions stop being vacuous. `VALIDATION.md` records what is and is not proven.
