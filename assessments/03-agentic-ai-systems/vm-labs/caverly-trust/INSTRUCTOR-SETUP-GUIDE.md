# Instructor setup — `caverly-trust`

## Portal configuration

- **Image:** systemd Ubuntu (Ubuntu 25.04 / Python 3.13.3).
- **Setup script:** `dist/Setup.zip` (contains `scripts/setup_script.sh` and an
  empty `data/`).
- **Test cases:** `dist/TestCase.zip` (contains `scripts/script_01..05.sh` and an
  empty `data/`).
- **Number of test cases:** 5. **Points per test case:** 10. **Max Score: 50.**
- **Problem statement:** `problem-statement.md`.

## What provisioning does

1. Installs `python3` in the foreground and nothing else, so the portal gets a
   usable lab as fast as possible.
2. Detaches a job that installs `curl` and `jq` (the check scripts need both)
   and warms the first agent turn, publishing `/var/log/caverly-lab/deps.ready`
   when done. Every check waits on that file only if it is missing.
3. Writes `/home/user/caverly-trust`: `trust_kit/` (the agent, the account
   records, the tools, the campaign runner), `campaigns/sample.json`,
   `check_local.py`, four rail starters under `guards/`, and a `harden.py`
   starter.
4. Writes the support desk to `/opt/caverly-svc/trustsvc.py` as `root:root 0700`
   and starts it on `127.0.0.1:8744` under systemd, falling back to a detached
   process. The checks start it on demand if it is down.
5. Pre-creates `reports/scorecard.json` **as `user`**, because a check runs the
   learner's gate and the gate writes that file. Every check also hands the
   project back with `chown -R user:user` from an `EXIT` trap.

Setup log: `/var/log/caverly-lab/setup.log`. Status lines:
`/var/log/caverly-lab/setup-status`. Per-check wall times:
`/tmp/caverly_timing.log`.

## The support desk

`trustsvc.py` plays the assistant. Its replies are computed from rules rather
than sampled, so the same request always produces the same behaviour: it leaks
the operator secret when it is pushed to, it decodes Base64 and folds lookalike
characters the way a tokeniser would, it follows instructions found in retrieved
text **only** while that text is not marked off, and it reaches for whichever
tool the request implies regardless of whether the caller is entitled to it.

Grader-only endpoints sit behind an `X-Grader-Key` header under `/__cv7k` and
return a plain 404 without it: `/trace?run=`, `/reset?run=`, `/attacks?set=`,
`/secret`. The graded campaign is served from there, so it never appears in the
learner project or in the setup script.

There is no hosted model anywhere in this lab and no key to supply.

## Marking notes

- **Many shapes pass.** The rails may be functions, classes with `__call__`, or
  imports from a shared module; the tool policy may be permission strings or a
  per-tool table; `harden.py` may use `argparse` or hand-rolled `sys.argv`; the
  scorecard may use `rows` or `attacks` as its list key. All six alternatives in
  `reference-solution/` score 50/50.
- **The one deliberate trap** is Task 1 point 7. A learner who blocks "pull up
  the balance for u_sable" at the input rail loses check 1 *and* check 5, because
  the campaign carries a support agent legitimately reading inside their own
  tenant. `reference-solution/_defect3_blocks_authz` reproduces it at 30/50. This
  is the point of the lab, and the statement says it in plain terms.
- Check 5 re-runs three campaign entries against the learner's `HOOKS`, so a
  hand-written scorecard scores 40/50 rather than 50/50
  (`_cheat_fabricated_scorecard`).

## Before the first cohort

Run once **as root on the image**:

    ./validation/permutations.sh

Off the VM its ownership rows self-report as vacuous, which is why this one run
matters: it is the only place the root-ownership invariant is real.
