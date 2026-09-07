# Instructor setup — `norbury-flow`

## Portal configuration

- **Image:** systemd Ubuntu (Ubuntu 25.04 / Python 3.13.3).
- **Setup script:** `dist/Setup.zip`. **Test cases:** `dist/TestCase.zip`.
- **Number of test cases:** 5. **Points per test case:** 10. **Max Score: 50.**
- **Problem statement:** `problem-statement.md`.

## What provisioning does

1. Installs `python3` in the foreground and nothing else.
2. Detaches a job that installs `curl` and `jq`, warms one tool call, then
   publishes `/var/log/norbury-lab/deps.ready`. No pip package is needed.
3. Writes `/home/user/norbury-flow`: `flow_kit/`, two exports under `flows/`,
   `check_local.py`, three starters, and an empty `runs/` owned by `user`.
4. Writes `NORBURY_API_KEY` into `/etc/profile.d/norbury.sh` so the learner's
   shell carries a credential. **The check scripts set it themselves** — the
   judge is a non-login root shell and never sources `profile.d`.
5. Writes the model endpoint to `/opt/norbury-svc/flowsvc.py` as `root:root
   0700` and starts it on `127.0.0.1:8788`.

## The model endpoint

`flowsvc.py` decides what to do next from the conversation it is shown rather
than by sampling, so the same flow always takes the same path: it reaches for
`arxiv_search`, then `web_search`, then `summarise`, using only the tools it was
offered, and produces a briefing once it has them. A question about what came
earlier is answered from the conversation itself, which is what makes "memory
was wired in" measurable rather than asserted.

It refuses a call carrying no credential, or one carrying the `***` placeholder
an export contains, with a `401` — and it counts both.

Grader-only endpoints sit behind an `X-Grader-Key` header under `/__nb6f` and
return a plain 404 without it: `/trace?run=`, `/reset?run=`, `/replies`. The
graded flows are written by the checks into a root-only directory, so they never
appear in the learner project.

## Marking notes

- **Many shapes pass.** The validator may be a sequence of checks or a list of
  rules; `plan` may use Kahn's algorithm or a depth-first walk; the runtime may
  be a dict or an object; `flowctl.py` may use `argparse` or hand-rolled
  `sys.argv`. All five alternatives in `reference-solution/` score 50/50.
- **Naming either end of a circle is accepted.** Kahn's algorithm names both
  nodes in the cycle and a depth-first walk names one; check 1 accepts either.
  This was a false negative caught by writing the second implementation.
- The plan contract fixes two things — first node is the `ChatInput`, last is
  the `ChatOutput` — because several topological orders are otherwise valid.
  The statement says so.
- Check 3 reads what the endpoint was handed, so a `flowctl.py` that answers
  from a canned string scores 20/50 (`_cheat_canned_reply`).

## Before the first cohort

Run once **as root on the image**:

    ./validation/permutations.sh

Off the VM its ownership rows self-report as vacuous, which is why this one run
matters.
