# Instructor setup — `westmere-claims`

## Portal configuration

- **Lab image:** *systemd Ubuntu*. Do not substitute: this pack targets
  Python 3.13 with no pip and PEP 668, and its setup script is written for
  exactly that.
- **Setup script:** `dist/Setup.zip` (`scripts/setup_script.sh` + empty `data/`).
- **Test cases:** `dist/TestCase.zip` (`scripts/script_01..05.sh` + empty
  `data/`).
- **Max Score: 50.** Five test cases, **10 points each**.
- **Problem statement:** `problem-statement.md`, pasted as-is. No markdown
  tables — the portal renderer shows them as literal pipes.

## What provisioning does

Foreground, in seconds:

1. Installs `python3` if it is missing, and nothing else. Writes
   `/etc/pip.conf` with `break-system-packages` so PEP 668 does not block the
   learner later, and bridges `~/.local` into the admin site directory so a
   package the learner installs is importable by the root judge.
2. Writes `/home/user/westmere-claims/` — `claim_kit/`, `data/claims.json`,
   `check_local.py`, the `claimctl.py` starter — and **chowns it to `user`
   immediately**, before any step that could fail.
3. Installs the desk to `/opt/westmere-svc` as `root:root 0700` and starts it
   under systemd on port 8571, falling back to a detached process.
4. **Pre-creates `state/claims.db` owned by `user`.** This is not cosmetic: the
   checks run the learner program as root, opening a SQLite store *creates* it,
   and a root-owned store gives the learner `attempt to write a readonly
   database` for the rest of the session.

Detached, publishing `/var/log/westmere-lab/deps.ready` when done:

5. `apt-get python3-pip curl jq`, then the pinned wheels
   (`langchain==1.2.15`, `langchain-core==1.3.0`, `langgraph==1.1.9`,
   `langgraph-checkpoint-sqlite==3.0.3`, `pydantic==2.13.3`) with
   `--only-binary=:all:`, then a warm-up that imports langgraph and makes one
   desk call so the first graded run is not a cold start.

The learner can read the statement and start writing immediately. Every check
waits on `deps.ready` for at most 25 s and only when the packages are genuinely
missing.

## Time budgets

- Setup foreground: seconds. Internal deadline **95 s**, on expiry it prints a
  summary and exits 0 rather than being killed.
- Each check: 25 (deps) + 12 (desk) + **100 (all learner runs together)**. The
  learner-run bound is a *shared* deadline rather than a per-call one, because
  the heaviest check starts the interpreter five times; five independent 30 s
  bounds would add up past the portal cap even with no single slow call.
- Every check appends its wall time to `/tmp/westmere_timing.log`.

## Marking notes

- **Many shapes score 50.** Verified during authoring: structured output with
  and without an LCEL chain; `Command(goto=...)` instead of a conditional edge;
  hand-rolled `sys.argv` parsing instead of `argparse`; the loop in a graph with
  the dispatch in plain Python; the settlement retry as a class. If a learner
  clamps the step counter in Python rather than in a reducer, that also passes —
  the check grades the number, and the statement asks for the behaviour.
- **A hand-rolled store passes too**, as long as it is at `state/claims.db`,
  survives the process, isolates threads and does not replay. The statement asks
  for a checkpointer because that is the primitive worth learning, but the check
  grades persistence, not the class name.
- Single-theme losses observed: routing on narrative text (check 2); no attempt
  cap, or a step counter that does not clamp (check 3); a retry budget larger
  than the desk allows (check 4); an in-memory saver, one shared thread id, or
  replaying earlier turns (check 5).
- A program that prints answers it worked out itself scores **0/50** — every
  theme cross-checks the desk trace, and a desk that saw no requests cannot have
  answered any.

## What the checks touch

Only `state/claims.db` and whatever the learner program writes. Every check
hands ownership of the whole project back from an `EXIT` trap, so a run killed
at the cap still leaves a usable VM. The checks never modify `claimctl.py` or
anything under `claim_kit/`.

## Before the first cohort

Run `validation/permutations.sh` **as root on a provisioned VM** once. Its seven
rows cover the starter untouched, written-but-never-run, run-then-graded, a
partial grading run, two repeats, and a deleted store — and on a real VM its
ownership assertions stop being vacuous. `VALIDATION.md` says exactly what is
and is not proven.
