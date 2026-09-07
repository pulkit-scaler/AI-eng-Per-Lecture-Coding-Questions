# Larkspur Transit — Instructor Setup Guide

## 1. Portal configuration

- **Lab image:** "systemd Ubuntu". Confirmed by recon to be **Ubuntu 25.04, Python 3.13.3**,
  x86_64, 2 cores / 3.7 GB, `python3` present but **no pip and no `ensurepip`**, PEP 668 marked
  externally managed, `sudo` present but needs a password, no `gcc`/`make`/`git`, and `timeout`,
  `curl`, `wget`, `jq`, `vim` present. Do **not** pick the ttyd 20.04 image (Python 3.8, below the
  SDK floor) or the Alpine Docker image (musl, no python3).
- **Setup file:** `dist/Setup.zip`
- **Test Case zip:** `dist/TestCase.zip`
- **Max Score:** **50**  (5 checks × 10 points)
- **Time Limit:** 60 minutes is comfortable. Grading itself takes seconds; the limit is about the
  learner's working time.
- **Duration:** 120 minutes.

Both zips contain `scripts/` **and** `data/` at the root. `data/` is empty in both, and must still
be present — the platform rejects the older scripts-only shape.

## 2. What provisioning does

`setup_script.sh` runs once, as root, in seven phases, and prints `t+<n>s` at each boundary.

1. **Base packages** — installs `python3` only if it is missing, symlinks `/usr/local/bin/python`,
   checks that `import sqlite3` works, and installs `curl` and `jq`. Every `apt-get`/`systemctl`
   call is wrapped in a pure-bash `cap` bound, and the apt-daily timers are stopped first so the
   dpkg lock cannot stall the run. `curl` and `jq` are in the **foreground** on purpose: every check
   shells out to both (the platform's own `print_status` builds its line with `jq -n`), so if they
   arrived late a check running early would read an empty string for every value it looked up and
   report a failure against the learner's code for a half-provisioned VM.
2. **Runtime dependencies, detached** — a `setsid`-detached job installs pip (via `get-pip.py`, then
   `apt --no-install-recommends python3-pip`), re-runs the `curl`/`jq` install as an idempotent
   retry, and then installs `mcp==1.9.4 pydantic-settings==2.14.0 openai==3.1.0` with
   `--only-binary=:all:`. The fallback rung is `mcp>=1.9,<2 pydantic-settings<2.15 openai>=3,<4`:
   all three are bounded, because `mcp` 2.x removed `mcp.server.fastmcp`, `pydantic-settings` 2.15
   warns on every FastMCP construction onto the stdio stream the client is reading, and an
   unbounded `openai` could move `chat.completions.create` under the learner. It writes
   `/var/log/larkspur-lab/deps.state` (`pinned` | `latest` | `failed`), warms the `mcp` and `openai`
   imports, and finally touches `/var/log/larkspur-lab/deps.ready`. Nothing in the foreground waits
   for it; every check waits on that sentinel instead.
3. **Project skeleton** — writes `transit_kit/`, `check_local.py`, the two starter files (only when
   they do not already exist), `transit_kit/service.url`, and builds `data/transit.db` with the
   inlined seeder. Pre-creates both `__pycache__` directories and chowns the whole project to
   `user` **immediately**, before anything that could fail.
4. **Operations service** — writes `opsd.py` to `/opt/larkspur-svc` as `root:root 0700`.
5. **Starting the service** — a systemd unit if `systemctl` works, otherwise a `setsid nohup`
   fallback; health-probed with `python3`/`urllib` rather than `curl`, so provisioning does not
   depend on the `curl` install in phase 1 having succeeded.
6. **Dependency hand-off** — a bounded 10s grace period, then it reports what the state file says
   and moves on.
7. **Permissions and summary** — re-chowns, then prints either the ready banner or
   `LAB NOT READY -<blockers>`.

A hard internal deadline (`SETUP_BUDGET`, default 95s) fires a `USR1` trap that prints the summary
and exits 0 rather than letting the portal kill the script. The project, the database and the
service are all in place before that point.

## 3. Why `mcp` is pinned to 1.9.4

`mcp` **2.0.0 removed the `mcp.server.fastmcp` module**, which is the API this lab (and the taught
material) is built on. 1.9.4 is the last 1.x release. The fallback rung is `"mcp<2"` for the same
reason, and `build.sh` refuses to ship a setup script that loosens either.

`pydantic-settings` is pinned to 2.14.0 because 2.15.0 emits an `IncompleteFieldDefinitionWarning`
every time a `FastMCP` instance is constructed. That warning lands on the stderr of every server
process the learner starts, and stdio servers inherit the client's stderr, so it would appear in the
middle of their own output for no reason.

Every package in the resolved tree has a wheel for cp313 on manylinux x86_64 — only `pydantic-core`
and `jiter` are compiled at all, and both ship `cp313` manylinux wheels. Checked against the PyPI
JSON API; see `VALIDATION.md` for the full table.

## 4. Grading

Five checks, 10 points each, all-or-nothing, one `print_status` per script.

- `script_01.sh` — the server speaks MCP and advertises its three tools correctly.
- `script_02.sh` — `tools/call` does real database work and both guards hold.
- `script_03.sh` — the resource is advertised and reads the live database.
- `script_04.sh` — the prompt is advertised and interpolates its argument.
- `script_05.sh` — the agent loop answers end to end over MCP.

Checks 1–4 build their own `ClientSession` and talk to the learner's `server.py` over stdio. Checks
2 and 3 seed a fresh database in root's own temp directory and start the learner's server with
`LARKSPUR_DB` pointing at it, so table sets, column lists and row counts are values the learner has
never seen and cannot have written down. Check 4 passes a value chosen at run time.

Check 5 is the only one that runs the learner's own code. Before it does, it resets the session
trace, asks the oracle for the true answer, then runs `run_agent_loop` in one interpreter start and
reads the trace back.

### Grader-only surface

The service exposes three grader-only paths behind the header
`X-Larkspur-Grader: larkspur-grader-k7q2`. Without that header they return the same plain 404 as
any unknown path, so the endpoint looks like nothing but an OpenAI-compatible endpoint from the
learner's side.

```bash
KEY='X-Larkspur-Grader: larkspur-grader-k7q2'
curl -s -H "$KEY" --get --data-urlencode 'q=Which route carried the most total boardings?' \
     http://127.0.0.1:8757/__grk7q2/oracle | jq
curl -s -H "$KEY" 'http://127.0.0.1:8757/__grk7q2/trace?session=tc05_1234' | jq
curl -s -X POST -H "$KEY" 'http://127.0.0.1:8757/__grk7q2/trace/reset?session=tc05_1234'
```

### Time budget

Four named constants bound every wait in every check: `SVC_WAIT=12`, `RUN_BUDGET=45`,
`CURL_MAX=5`, `DEPS_WAIT=20`, plus `MCP_WAIT=10` for the grader's own protocol reads. The paths are
mutually exclusive — a check that gives up on the dependencies or the service reports immediately
and never reaches the probe — so the realistic worst case is about 66s, well inside the portal's
~2-minute per-test cap. Measured on the authoring host with the service warm: **0.77–0.84s** for
checks 1–4 and **1.16–1.18s** for check 5. Every check appends its own wall time to
`/tmp/larkspur_timing.log`.

## 5. Ownership and stray processes

Grading runs as **root**; the learner is `user`. Two hazards, both handled:

- **Bytecode caches.** `mcp.client.stdio` rebuilds the stdio child's environment from
  `get_default_environment()`, a fixed whitelist (`HOME`, `LOGNAME`, `PATH`, `SHELL`, `USER`) that
  `PYTHONDONTWRITEBYTECODE` is not on. Explicit `env=` entries are merged over that whitelist, so
  the checks' own probes are safe, but a server the **learner's** client spawns is not: the learner
  passes `env=None`, and the child writes `transit_kit/__pycache__/*.pyc` into whatever directory it
  started in. Under grading that is root. Measured: 6 files.

  Handled in two places, prevention first:

  - **Prevention.** No check runs anything inside the project. Each one copies the project into its
    own `WORK` directory under `/tmp` (`stage_project`) and runs the probe there, so the bytecode
    lands in a directory the check deletes on the way out. Measured before and after: 6 files in the
    project, then 0.
  - **Repair.** Every check still chowns the project back from its `EXIT` trap, not from a success
    path. The gate is `id -u user`, whether a learner account exists, **not** where `LAB_DIR` points.
    It used to be `case "$LAB_DIR" in /home/user/*)`, which meant the repair was dead code in every
    environment that tests it, because every authoring harness runs with `LAB_DIR` under `/tmp`. A
    `case "$LAB_DIR" in /*/*)` guard is kept so an unset variable can never let the chown reach `/`.

  Setup still pre-creates both `__pycache__` directories owned by `user`. That is now belt and
  braces rather than the fix.
- **Stray servers.** If a probe is killed at its time bound, the server child can outlive it. Every
  check sweeps up, from the same `EXIT` trap, any process matching `server.py` that is **root-owned
  and whose working directory is either this lab or this check's own `WORK` directory** — conditions
  nothing the learner started can satisfy. `WORK` has to be in that set as well as the lab, because
  the probes now run against the staged copy.

After grading, verify:

```bash
find /home/user/larkspur-transit ! -user user | wc -l     # must be 0
pgrep -f 'server\.py'                                     # must print nothing
su - user -c 'cd ~/larkspur-transit && python3 check_local.py'
```

`find ! -user user` is necessary but **not sufficient**, and it is worth knowing why: it cannot see
this class of bug at all when provisioning has pre-created the file and root's write lands in place.
The invariant that actually covers it is in `validation/permutations.sh` row 10, which fingerprints
every file in the project (path, size, mode, content digest), grades twice, requires the
fingerprint unchanged both times, then deletes a learner-written file and requires that grading does
not recreate it. That row passes off-VM, where the ownership columns cannot be checked at all.

## 6. Diagnosing a report from a learner

```bash
cat /var/log/larkspur-lab/setup-status          # how far provisioning got
tail -40 /var/log/larkspur-lab/setup.log        # which rung of which ladder fired
cat /var/log/larkspur-lab/deps.state            # pinned | latest | failed
ls -l /var/log/larkspur-lab/deps.ready          # present once the install finished
tail -30 /var/log/larkspur-lab/pip.log          # the install itself, plus the warm-up line
cat /tmp/larkspur_timing.log                    # per-check wall time
curl -s http://127.0.0.1:8757/health
stat -c '%U %a %n' /home/user/larkspur-transit/*
```

For a verbose grading run, regenerate the checks with logging on and re-run one of them:

```bash
TEST_LOGGING=on ./gen_tests.sh
LARKSPUR_TRACE=1 bash test-cases/scripts/script_05.sh   # log under /tmp/larkspur-lab-logs
./gen_tests.sh                                          # back to the shipped, quiet form
```

Re-running `setup_script.sh` is safe and idempotent: it leaves an existing `server.py` or
`solution.py` alone, and rebuilds `data/transit.db` only when the file is missing or no longer holds
the three tables.

## 7. Known residues

- `_cheat_hardcode` scores **10/50**, not 0. Its `server.py` genuinely advertises three described
  tools with the right required parameters, a resource at the required URI and a prompt with the
  right argument, which is all check 1 claims to verify — the moment it is asked to *do* anything,
  checks 2, 3, 4 and 5 all fail. Deliberate, and recorded rather than papered over by widening
  check 1 beyond its theme.
- A learner who deletes `data/transit.db` scores **40/50**: checks 1–4 still pass (2 and 3 use their
  own seeded copies), and check 5 fails because the endpoint cannot compute the expected answer.
  Re-running setup restores the file. Check 5 is last, so 40/50 is also what the portal reports.
- **Partial credit on the portal is a prefix, not a per-theme sum.** `main.sh` breaks at the first
  failing case, so a solution that fails check 1 never runs checks 2 to 5. Measured portal scores:
  reference and all five alternatives 50, `_defect1` 0, `_defect4` 10, `_defect2` 20, `_defect3` 30,
  `_defect5` 40, `_cheat_hardcode` 10, `_cheat_bypass` 0, the starter stubs 0. The 40/50 figures in
  `SOLUTION.md` and `VALIDATION.md` are `run-all.sh` running all five regardless, which is the right
  number for judging that each defect loses only its own theme. The checks are ordered fundamental
  to advanced (does the server speak MCP at all, then do the tools work, then the resource, then the
  prompt, then the whole client and loop) so that the prefix a learner earns tracks how far they
  have got.
- A module-scope `import numpy` in `server.py` costs **all five** checks; the same import in
  `solution.py` costs **only check 5**. The Environment section of the problem statement warns about
  this explicitly.
