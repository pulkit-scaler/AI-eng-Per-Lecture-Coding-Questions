# Instructor setup — `pelham-approvals`

## Portal configuration

- **Image:** systemd Ubuntu (Ubuntu 25.04 / Python 3.13.3).
- **Setup script:** `dist/Setup.zip`. **Test cases:** `dist/TestCase.zip`.
- **Number of test cases:** 5. **Points per test case:** 10. **Max Score: 50.**
- **Problem statement:** `problem-statement.md`.

## What provisioning does

1. Installs `python3` in the foreground and nothing else.
2. Detaches a job that installs `python3-pip`, `curl`, `jq`,
   **`langgraph==1.2.11`** and **`langchain-core==1.6.0`** (falling back to the
   current series), warms the imports and one model call, then publishes
   `/var/log/pelham-lab/deps.ready`. Checks wait on that file only when it is
   missing; the wait is 90s because LangGraph is the heaviest install in the
   collection after CrewAI.
3. Writes `/home/user/pelham-approvals`: `pelham_kit/`, two starters under
   `bdi/`, a `server.py` starter and `check_local.py`.
4. Writes the analysis desk to `/opt/pelham-svc/expensesvc.py` as `root:root
   0700` and starts it on `127.0.0.1:8766`.
5. Pre-creates **nothing on disk for the learner**, because this lab keeps its
   state inside the running service. What has to survive grading is the **port**
   — see below.

## The port is the thing grading can take away

The deliverable is a long-running service on `127.0.0.1:8767`, and the checks
have to talk to one. So each check:

- uses the learner's service if one is already answering, and **leaves it
  alone**;
- otherwise starts one itself and **stops the one it started** from its `EXIT`
  trap.

Without that second half, grading leaves a root-owned process holding the
learner's port and they cannot start their own service again. Rows 2, 4, 6 and 7
of the ordering matrix assert the port is free afterwards, and row 3 asserts a
service the learner started is still running.

Check scripts also use per-run thread ids (a nonce), because the service keeps
its threads for as long as it is up and a thread decided on the previous grading
run is not waiting for anybody.

## The analysis desk

`expensesvc.py` plays the analyst. Its verdicts are computed from the claim text
rather than sampled: a category off the approved list, or a description carrying
wording a finance team reviews by hand (`gift card`, `cash advance`, `no
receipt`…), comes back as invalid or higher-risk every time. That is what makes
"a small claim in a valid category still went to a person" a stable assertion.

It counts every analysis call, so "deliberation really consulted the analyst"
and "reading a claim back did not re-run the agent" are both measurable. The
checks measure **deltas** on the default run rather than tagging a run id,
because the model call happens inside the learner's service process and the
checks must not have to reach into its environment.

Grader-only endpoints sit behind an `X-Grader-Key` header under `/__pm3x` and
return a plain 404 without it: `/trace?run=`, `/reset?run=`, `/expected?text=`.

There is no hosted model anywhere in this lab and no key to supply.

## Marking notes

- **Many shapes pass.** Nodes may be module functions or bound methods of an
  object; the state may be a `TypedDict` or a `TypedDict` with `Annotated`
  reducers on the growing fields; the service may route with an if-chain or a
  dispatch, and may return extra fields. All five alternatives in
  `reference-solution/` score 50/50.
- **`StateGraph(dict)` does not work** and is not accepted as an alternative:
  the fields do not survive being read back. That was tried, measured at 20/50,
  and dropped rather than worked around.
- **The audit log is graded as append-only**, so a `finalize` that returns a
  fresh list rather than adding to one loses check 4 (and check 1, because the
  log then holds a single entry).
- Check 1 asserts the analyst was consulted, so a service with no graph behind
  it scores 30/50 (`_cheat_no_graph`) — it passes the pause, resume and safety
  themes and fails the two that need a model call.

## Before the first cohort

Run once **as root on the image**:

    ./validation/permutations.sh
    ./validation/vm-e2e.sh --here

`permutations.sh` covers the ordering matrix; off the VM its ownership rows
self-report as vacuous, while its port rows are real everywhere and are the ones
that matter most in this pack. `vm-e2e.sh --here` provisions the lab from
`dist/Setup.zip` and grades with **nothing overridden**, which makes it the only
harness that exercises the paths and ports the checks actually ship with - the
one that would have caught `LAB_DIR` pointing at another lab's project. Both are
green in a cold `ubuntu:25.04` container, but that container has no systemd, so
on the first real VM also confirm:

    systemctl status pelham-desk          # should be active (running)
    tail -5 /var/log/pelham-lab/setup.log
