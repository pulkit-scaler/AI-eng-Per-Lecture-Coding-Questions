# Instructor setup — `bellhaven-rubric`

## Portal configuration

- **Image:** systemd Ubuntu (Ubuntu 25.04 / Python 3.13.3).
- **Setup script:** `dist/Setup.zip`. **Test cases:** `dist/TestCase.zip`.
- **Number of test cases:** 5. **Points per test case:** 10. **Max Score: 50.**
- **Problem statement:** `problem-statement.md`.

## What provisioning does

1. Installs `python3` in the foreground and nothing else.
2. Detaches a job that installs `python3-pip`, `curl`, `jq` and **`sympy`**
   (pinned to 1.13.3, falling back to the current series), warms the symbolic
   parser and the desk, then publishes `/var/log/bellhaven-lab/deps.ready`.
   Checks wait on that file only when it is missing; the wait is 90s because
   this pack has a wheel to install.
3. Writes `/home/user/bellhaven-rubric`: `eval_kit/`, `data/pool_sample.json`,
   `check_local.py`, four harness starters and a `gate.py` starter.
4. Writes the review desk to `/opt/bellhaven-svc/judgesvc.py` as `root:root
   0700` and starts it on `127.0.0.1:8755`.
5. Pre-creates `reports/eval.json` **as `user`**, because a check runs the
   learner's gate and the gate writes that file. Every check also hands the
   project back with `chown -R user:user` from an `EXIT` trap.

## The review desk

Two grading families, `nyx` and `vale`. Their verdicts are computed from a table
rather than sampled, so the same submission always gets the same grade. `nyx` is
the more forgiving of the two and gives the benefit of the doubt on one item
where there is no answer at all — which is the single disagreement the ensemble
theme is built on. One `vale` reply carries no JSON whatsoever, so a parser that
assumes JSON will crash on it.

The desk attributes a grading prompt to a submission by finding the problem text
inside it. That is what makes "the prompt actually carried the problem, the
reference answer, the working and the rubric" a measurable fact rather than a
claim.

Grader-only endpoints sit behind an `X-Grader-Key` header under `/__bh4r` and
return a plain 404 without it: `/trace?run=`, `/reset?run=`, `/pool`,
`/expected`. The graded pool is served from there, so it never appears in the
learner project or in the setup script. The sample pool the learner develops
against is known to the desk for attribution but is never served as the graded
one.

There is no hosted model anywhere in this lab and no key to supply.

## Marking notes

- **Many shapes pass.** `build_golden` may shuffle with a seed or use a stable
  ordering with no randomness at all; `symbolic_match` may simplify a difference
  or call `.equals()`; the reply parser may use patterns or a JSON scanner;
  `gate.py` may use `argparse` or hand-rolled `sys.argv`. All five alternatives
  in `reference-solution/` score 50/50.
- **The two subtle requirements** are the ones learners miss: kappa must be
  `None` when a grader used one label only (`_defect4_kappa_degenerate`, 40/50),
  and a disagreement must be escalated rather than resolved by taking a side
  (`_defect6_majority_vote`, 30/50).
- Check 5 reads the desk's own record of the run, so a hand-written report
  scores 40/50 (`_cheat_hardcoded_report`) with the message "the desk was sent 0
  grading prompts".

## Before the first cohort

Run once **as root on the image**:

    ./validation/permutations.sh

Off the VM its ownership rows self-report as vacuous, which is why this one run
matters.
