# Instructor setup — `thistledown-mill`

## Portal configuration

- **Lab image:** *systemd Ubuntu*.
- **Setup script:** `dist/Setup.zip`. **Test cases:** `dist/TestCase.zip`.
- **Max Score: 50.** Five test cases, **10 points each**.
- **Problem statement:** `problem-statement.md`, pasted as-is. No tables.

## The dependency, and what it means for the learner

`crewai` is the heaviest install of any lab in this module: **643 MB of
site-packages**, and about **a minute** to resolve and install on a fast
connection. It is installed by the detached setup job, so provisioning still
returns in seconds, but there is a real window at the start of the lab where
`import crewai` fails.

What that means in practice:

- The statement tells the learner to check with
  `python3 -c 'import crewai; print(crewai.__version__)'`.
- `check_local.py` waits for crewai itself, up to **240 s**, printing what it is
  waiting for. It runs before it touches `mill/tools.py`, so a learner in the
  first minute is never shown a `ModuleNotFoundError` that looks like a bug in
  their own file. If the sentinel appears without crewai behind it, the install
  failed and it says so and points at `pip.log`.
- Every check waits up to **30 s** on `/var/log/thistledown-lab/deps.ready`, and
  only when crewai is genuinely missing. A learner who has run their crew even
  once is long past that point.
- A learner who submits within the first minute gets *the packages are not
  installed yet* rather than five confusing failures.

If the cohort is large and the network is slow, warn them that the first minute
is not usable.

## What provisioning does

Foreground, in seconds: python3 if missing, `/etc/pip.conf`, the project
(`mill/millkit.py`, `mill/main.py`, the four starters, `data/orders.json`), the
mill database built from `build_db.py`, `out/` — **all chowned to `user`
immediately** — the planning model installed to `/opt/thistledown-svc`
(`root:root 0700`) and started under systemd on 8433, and
`/etc/profile.d/thistledown.sh`.

It also pre-creates `~/.local/share/thistledown-mill/.crewai_user.json` marked
`first_execution_done`. **Do not remove this.** CrewAI otherwise asks, once per
project directory, whether the user wants to view execution traces and waits 20 s
for an answer — on a graded run that is 20 s of nothing, on every check.

Detached: `python3-pip curl jq`, then `crewai>=0.130,<1.0` and `python-dotenv`
with `--only-binary=:all:`, then a warm-up that imports crewai and opens the
database.

## Environment, in two places

`/etc/profile.d/thistledown.sh` exports `OPENAI_API_KEY`, `OPENAI_API_BASE`,
`CREWAI_TRACING_ENABLED=false` and `OTEL_SDK_DISABLED=true` for the learner
shell. **The check scripts export the same values themselves**, because the judge
is a non-login root shell and never reads a profile script. `build.sh` refuses to
ship a check that is missing them.

There is **no API key to obtain**. The mill runs its own planning model on the
VM, and `millkit.planning_llm()` is already pointed at it.

## Time budgets

- Setup foreground: seconds. Internal deadline 95 s.
- Each check: 30 (deps) + 12 (model) + a shared **100 s `HARD_DEADLINE`** across
  every interpreter start the check makes. Observed slowest check on the
  authoring host: **6 s**.
- Each check appends its wall time to `/tmp/thistledown_timing.log`.

## What the checks touch

`out/` and nothing else. Check 2 asserts the mill database is byte for byte
unchanged after six write attempts, and the ordering matrix asserts the same
across three grading passes. Every check chowns the project and the crewai state
directory back from an `EXIT` trap.

## Marking notes

See `README.md` for the full list. The short version: six structurally different
correct shapes all score 50/50, six defect probes each lose exactly one theme,
and a crew whose tools answer from a hand-written table loses check 1 only —
because two of the six calls in that check are queries nothing could have
prepared for.

## Before the first cohort

Run `validation/permutations.sh` **as root on a provisioned VM** once. Six rows,
including one that asserts the database survives three grading passes unchanged.
On a real VM its ownership assertions stop being vacuous. `VALIDATION.md` records
what is and is not proven.
