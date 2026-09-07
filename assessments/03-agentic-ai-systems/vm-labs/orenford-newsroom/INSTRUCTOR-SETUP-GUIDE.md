# Instructor setup — `orenford-newsroom`

## Portal configuration

- **Lab image:** *systemd Ubuntu*. Do not substitute: the pack targets
  Python 3.13 with no pip and PEP 668, and its setup script is written for that.
- **Setup script:** `dist/Setup.zip` (`scripts/setup_script.sh` + empty `data/`).
- **Test cases:** `dist/TestCase.zip` (`scripts/script_01..05.sh` + empty
  `data/`).
- **Max Score: 50.** Five test cases, **10 points each**.
- **Problem statement:** `problem-statement.md`, pasted as-is. No markdown
  tables.

## What provisioning does

Foreground, in seconds:

1. Installs `python3` if missing, writes `/etc/pip.conf` with
   `break-system-packages`, and bridges `~/.local` into the admin site directory
   so anything the learner installs is importable by the root judge.
2. Writes `/home/user/orenford-newsroom/` — `news_kit/`,
   `data/assignments.json`, `check_local.py`, the `serve.py` starter — and
   **chowns it to `user` immediately**.
3. Installs the newsroom wire to `/opt/orenford-svc` as `root:root 0700` and
   starts it under systemd on port 8317, with a detached-process fallback.

Detached, publishing `/var/log/orenford-lab/deps.ready`:

4. `apt-get python3-pip curl jq`, then the pinned wheels
   (`langchain==1.2.15`, `langchain-core==1.3.0`, `langgraph==1.1.9`,
   `langgraph-checkpoint-sqlite==3.0.3`, `pydantic==2.13.3`) with
   `--only-binary=:all:`, then a warm-up that imports langgraph and makes one
   wire call so the first graded run is not a cold start.

Nothing under the learner project is created by grading: the service logs to
`/tmp` and the briefings come back over HTTP. Every check still hands ownership
of the project back from an `EXIT` trap.

## The learner's service

The statement shows them how to run it by hand:

```
pkill -f serve.py
nohup python3 serve.py > serve.log 2>&1 &
```

Grading does not depend on any of that. Every check stops whatever is listening
and starts `serve.py` as it stands on disk, into a log it truncates first. That
is running their program, not writing it — an untouched starter is still refused
in about a second, by the sentence the starter carries — and it settles two
things that used to cost learners hours. A process left running from before an
edit no longer gets graded in place of the file, and the log a failure names can
no longer be a traceback from an earlier submission: a log another process
opened cannot be truncated by the checks, so before this the same stale
traceback came back edit after edit until the VM itself was restarted. Verified: the ordering matrix covers
service-not-running, learner-started, and killed-between-runs.

## Time budgets

- Setup foreground: seconds. Internal deadline **95 s**.
- Each check: 25 (deps) + 12 (wire) + 20 (service start) + a shared
  **100 s `HARD_DEADLINE`** across every briefing the check commissions. The
  heaviest check commissions two, and two independent per-request bounds would
  add up past the portal cap even with no slow request.
- Each check appends its wall time to `/tmp/orenford_timing.log`.

## Marking notes

**Topology is not graded, and that is deliberate.** All of these scored 50/50
during authoring:

- the three desks as a nested fan-out subgraph (the reference);
- the three desks as top-level nodes of one graph;
- a supervisor walking the desks one at a time;
- the research pass in plain Python with the newsroom still a graph;
- accumulate-everything-then-dedupe-once instead of a deduplicating reducer;
- the compiled graph held as an object by the service.

What is graded is the outcome: all three desks consulted, findings merged, a
failure contained *and recorded*, the loop capped, claims traceable, accounting
matching the wire. If a learner asks why their supervisor scored the same as a
fan-out, that is the answer.

Single-theme losses observed:

- a desk failure not caught → check 2 only;
- no cap on the night editor loop → check 3 only;
- a barred source cited → check 4 only;
- accounting written out in advance → check 5 only (the second assignment in that
  check takes a round of rework, so one fixed block of numbers cannot be right
  for both).

Two multi-theme losses, both honest:

- booking every call to one role loses checks 3 and 5, because the role tags are
  what the call counts are read from;
- consulting only two desks loses checks 1, 2, 4 and 5, because most of the
  briefing depends on the third.

And one instructive 0/50: giving the findings key **no reducer** makes LangGraph
refuse the fan-out, so the service returns 500 on every commission. Worth showing
in review — the framework prevents the silent version of that bug.

A service that prints correct briefings without contacting the wire scores
**0/50**: every theme cross-checks the wire trace, including check 4, which
requires the barred source's desk to have actually been asked.

## Before the first cohort

Run `validation/permutations.sh` **as root on a provisioned VM** once. Six rows;
on a real VM its ownership assertions stop being vacuous. `VALIDATION.md` says
exactly what is and is not proven.
