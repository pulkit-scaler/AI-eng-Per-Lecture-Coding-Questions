# Instructor Setup Guide — Ashford Grid

## Portal configuration

- **Setup file:** `dist/Setup.zip`
- **Test Case zip:** `dist/TestCase.zip`
- **Number of checks:** 5 (the platform accepts no more than five)
- **Points per check:** 10
- **Max Score:** 50
- **Time limit:** 60–75 minutes
- **Duration:** 90 minutes
- **Image family:** **systemd Ubuntu** — recon-confirmed as Ubuntu 25.04 / Python 3.13.3, x86_64,
  2 cores / 3.7 GB, `python3` present but **no pip and no `ensurepip`**, `EXTERNALLY-MANAGED`
  present (PEP 668), `sudo` present but needs a password, no gcc/make/git/Docker, and `timeout`,
  `curl`, `wget`, `jq`, `vim` present. The Ubuntu 20.04 image ships no `python3` at all; the Alpine
  image is musl and is for Docker labs.

Both zips contain a `scripts/` **and** a `data/` folder at the root; `data/` is empty here but must
be present. `build.sh` creates both and fails the build if either is missing.

## Coexisting with the Class 1 lab

This lab is designed to sit beside `kilnbrook-foundry` (Module 2, Class 1) without collision. Every
shared namespace is distinct:

- project directory `/home/user/ashford-grid/` (Class 1 uses its own)
- endpoint port **8836**, service name **`ashford-gridd`**, install directory `/opt/ashford-svc`
- grader key **`ashford-grader-q7w2`** on the prefix **`/__agq7w2/`**
- environment prefix **`ASHFORD_`** (`ASHFORD_PORT`, `ASHFORD_DB`, `ASHFORD_BASE_URL`,
  `ASHFORD_RUN_ID`, `ASHFORD_AUDIT_URL`, `ASHFORD_MODEL`, `ASHFORD_API_KEY`,
  `ASHFORD_GUARD_DELAY`)
- log directory `/var/log/ashford-lab/`, timing log `/tmp/ashford_timing.log`

## Prerequisites for the image

- **Outbound HTTPS at setup time only**, to install `openai` from PyPI. Grading itself never leaves
  the VM.
- `python3` (3.10+). Setup installs it if it is missing, then installs `python3-pip`, `curl` and
  `jq` in a detached job.
- A terminal editor (`nano` or `vi`). The learner writes one Python file.

## What the learner sees

- `/home/user/ashford-grid/` — `grid_kit/` (provided), `data/grid_ops.db` (the grid operations
  database), `check_local.py` (provided) and `solution.py` (the stub they fill in). `solution.py` is
  written only if absent, so re-running setup never destroys work in progress.
- Nothing else. The endpoint and the seeder live at `/opt/ashford-svc/`, `root:root`, mode `0700`.

## What setup does

1. Ensures `python3` (skipped entirely on this image, which ships it), symlinks `python` →
   `python3`, writes `/etc/pip.conf` with `break-system-packages` so the learner's first `pip
   install` is not refused by PEP 668, and drops a `.pth` in the admin site directory pointing at
   `/home/user/.local/lib/pythonX.Y/site-packages` so a no-sudo user install is importable by the
   root judge.
2. **Detaches** the dependency job: `python3-pip`, `curl`, `jq` and
   `pip install --only-binary=:all: openai==3.1.0`, on a pinned → latest → failed ladder writing
   `/var/log/ashford-lab/deps.state`, then a warm-up (one import, one database query, one real chat
   request) and finally the `deps.ready` sentinel. Nothing in the foreground waits for it.
3. Writes `grid_kit/`, `check_local.py` and the `solution.py` stub, then **chowns the project to
   `user` immediately** — before the riskier steps — so a later failure can never leave the learner
   with read-only files.
4. Installs `gridd.py` and `seed_db.py` to `/opt/ashford-svc` as `root:root 0700`.
5. **Seeds `data/grid_ops.db`** and chowns the file *and its parent directory* to `user`. Opening a
   SQLite file creates it, so pre-creating it as the learner is what stops a root-run check from
   taking ownership of the learner's database.
6. Starts `gridd.py` on `127.0.0.1:8836` as the `ashford-gridd` systemd unit, falling back to a
   detached background process where `systemctl` is unavailable or `enable --now` fails.
7. Waits a bounded 5 s for the dependency sentinel and reports which ladder rung fired.
8. Re-chowns and prints a summary — or, if any essential is missing, prints
   **`LAB NOT READY - <blockers>`** instead of claiming success.

Setup never fails the provisioning step. Every problem is recorded as a `WARN` line in
`/var/log/ashford-lab/setup-status`; the full log is `/var/log/ashford-lab/setup.log`.

## Time budgets

The portal kills a setup script or a single test case that runs much beyond two minutes, and its
status-poll window gives up sooner than that. Both paths are bounded and both report their own
timing.

- **Setup.** Measured on the authoring host with the apt block skipped (which is also what happens
  on this image, since it ships `python3`): **6–7 s of foreground**, of which 5 s is the bounded
  dependency grace — base packages `t+0s`, project skeleton `t+0s`, database `t+1s`, endpoint
  `t+1–2s`, dependency handed off `t+6–7s`. Every phase logs `t+<n>s` and the last line is
  `total setup time: <n>s`. **Read that line after the first provisioning on the real image**: the
  apt install of `python3-pip`/`curl`/`jq` and the wheel fetch are the only steps whose duration
  depends on the VM's network, and both are detached.
- **Test cases.** Every wait sits under one of four constants in each script's preamble —
  `SVC_WAIT=12`, `RUN_BUDGET=55` (the bound around the one learner run), `CURL_MAX=5`,
  `DEPS_WAIT=20` — for a worst case near 117 s. `build.sh` refuses to ship a script missing them.
  Measured on the authoring host every check finishes in **1–3 s**, except TC05 at 2–3 s (it holds
  eight guard calls for 0.7 s each, four at a time) and a sequential submission at 6–7 s.
  `run-all.sh` prints per-script wall clock and the slowest case, and every check appends its own
  wall time to `/tmp/ashford_timing.log` on the VM.

## Grading behaviour worth knowing about

**A learner who completes all five tasks scores 50/50 on their first submission.** No check is
expected to fail on a first attempt and no resubmission is required. The checks execute the
learner's functions themselves, so a learner who never ran their own program is not penalised for
that — but the problem statement still tells them to run it, because a solution that has never been
executed has never been through even one round trip.

Each check runs the learner's code **once**, in a single fresh `python3` process from
`/home/user/ashford-grid`, with a distinct `ASHFORD_RUN_ID`. The provided client sends that id as
`X-Ashford-Session`, so the trace the check reads back belongs to that check alone. Learner calls
are wrapped in `timeout -k 5 55` where coreutils `timeout` exists and in a shell watchdog where it
does not, so a hang becomes a clean graded failure rather than an opaque "blocking process" kill.

Each script starts the endpoint on demand (`ensure_service`) if it is not answering, so a check
never fails merely because the unit was restarted. Each script also refuses an untouched project in
about a second with a message naming both plausible causes, rather than timing out.

Every check exports `PYTHONDONTWRITEBYTECODE=1` and hands ownership of the project back with
`chown -R user:user` from an **`EXIT` trap** — not from a success path — so a grading run killed at
the time cap still leaves a usable VM. The repair is gated on `id -u user`, so it fires wherever a
lab user account exists rather than only where `LAB_DIR` happens to point under `/home/user`. The
chown is still bounded by a `case` that refuses an empty or `/` value, so a mis-set variable cannot
reach the filesystem root.

### Judge fidelity (read this before editing a check)

The platform's `/usr/local/bin/judge/test/common.sh` ends by installing
`trap 'handle_script_error $LINENO $? "$BASH_COMMAND"' ERR`, and that trap lands inside the check's
own shell. Its handler prints `INTERNAL_ERROR: ...` and exits. `main.sh` grades the **last line** of
stdout plus stderr, so that second line discards the verdict, the run is reported as
`evaluated: false`, and the learner sees an **empty "Test Case Results:" panel with no rows at
all**.

Three lines in the generated preamble prevent it, and `build.sh` refuses to ship a check missing any
of them:

- `trap - ERR` drops the inherited trap;
- `set +eE` keeps errexit and errtrace off for the whole file;
- `exec 2>>"/tmp/ashford_tc<NN>.err"` sends the check's own stderr to a file, because a stray
  stderr line voids the verdict exactly the same way.

This is not theoretical for this pack. Before the migration, the **untouched-starter refusal path**
reproduced it: `preflight || return` made `Test<NN>` return 1, the trap fired at the top level, and
the verdict was followed by
`INTERNAL_ERROR: An error occurred at line 350: 'return' exited with status '1'`. The single most
common learner ordering would have shown an empty panel instead of the message telling them to write
the five functions.

`test-cases/scripts/common.sh` is a **faithful replica** of the platform helper, not a convenience
stub, for the same reason: a local helper easier to satisfy than the real one makes validation
worthless. `run-all.sh` grades the last line as JSON the way `main.sh` does, and reports
`[!!!!] UNPARSEABLE` when it is not a verdict.

### Prefix scoring

`main.sh` `break`s at the first failing case, so a learner's score is the **leading run of passes**,
not a per-theme sum. A submission that fails check 1 never runs checks 2 to 5 and scores 0/50, not
40/50. `run-all.sh` runs all five (which is what makes a defect diagnosable) and prints both
numbers: `SCORE` is the per-theme total, `PORTAL` is what the learner receives. `sweep.sh` shows
both columns.

The five checks are ordered fundamental to advanced for this reason. TC01 grades `critique_query`,
which TC02's loop is built on; TC02 grades that loop; TC03 grades the same draft-and-repair shape
driven by execution rather than review. TC04 and TC05 are independent of the first three, so they
sit last. A learner working the tasks in order therefore earns a prefix that matches their
progress: Tasks 1 and 2 finished scores 20, and the permutation matrix pins that row.

## Troubleshooting

- **Every check fails with "the model endpoint is not reachable".** `systemctl status
  ashford-gridd`, then `curl -s 127.0.0.1:8836/health`. If the unit is missing, the fallback
  background process was used and was killed; the test scripts restart it themselves, so this
  self-heals on the next submission.
- **Every check fails with a Python error.** Almost always the pip install:
  `grep '^WARN' /var/log/ashford-lab/setup-status` and `tail /var/log/ashford-lab/pip.log`.
- **Every check fails with "the Python dependency ... is not installed".** The detached job has not
  finished or failed. `cat /var/log/ashford-lab/deps.state` says which rung fired.
- **Every check fails with `no such table` or an empty database.** The seeder did not run:
  `ls -l /home/user/ashford-grid/data/grid_ops.db`, then
  `python3 /opt/ashford-svc/seed_db.py /home/user/ashford-grid/data/grid_ops.db` as root, followed
  by `chown -R user:user /home/user/ashford-grid/data`.
- **TC01 fails with the right reason but "1 queries run".** The submission is executing the
  candidate inside `critique_query`. That is the intended failure — the gate exists to stop the
  query reaching the database.
- **TC02 fails with `attempts=4` and no result on the answerable question.** The repair request is
  not carrying the review reason, so the same query comes back every time.
- **TC02 fails with "1 rejected queries run anyway".** The loop is executing every candidate rather
  than only the one that passed review.
- **TC03 fails with `attempts=3 succeeded=false`.** The database error is not reaching the repair
  request. If it fails with only **one** memory entry, the loop stopped after the first repair
  instead of running the corrected query again.
- **TC03 fails with "0 repair prompts carrying both".** The accumulated error memory is not being
  included in the second repair request — only the newest failure is.
- **TC04 fails with categories in the wrong order or the wrong desk lines.** The submission is
  deciding the category itself instead of using the classification it asked for.
- **TC05 fails with "overlap factors of 10 and 10".** The guards are being called one after
  another. Ten tenths means no overlap at all.
- **TC05 fails with "overlap factors of 20 and 20".** Partial concurrency: the pool has fewer than
  four workers, so the guards overlap in pairs. `_cheat_two_workers.py` is this exact case. Four
  requests in flight together measure 40 tenths and the threshold is 25, so 40 and 20 are separated
  by a 15-tenth margin on either side. Measured 80 times on the authoring host with no variance at
  all: every concurrent shape 40, every two-worker run 20, every sequential run 10.
- **A check fails with "This VM is missing the command-line tool(s)".** `curl` and `jq` are
  installed by the setup foreground now, and the detached job retries them. `grep '^WARN'
  /var/log/ashford-lab/setup-status` names which one, and `tail /var/log/ashford-lab/pip.log` has
  the apt output. This is an environment fault; the message says so, so a learner does not read it
  as a problem with their code.
- **A learner reports a read-only `solution.py` (`E45`).** Should be impossible — the project is
  chowned immediately after it is written and again at the end, and every check hands ownership
  back from an `EXIT` trap. Confirm with `find /home/user/ashford-grid ! -user user`, which must
  print nothing. Note that `/home/user/.bashrc` can be root-owned on a pristine image; that is the
  image, not this lab, which is why the invariant is scoped to the project directory.

## Rebuilding the artifacts

```bash
cd assessments/02-advanced-ai-agents/vm-labs/ashford-grid
./gen_tests.sh      # regenerate script_01..05 from the shared preamble
./build.sh          # run every guard, regenerate setup_script.sh, restage the zips
```

## Re-validating before publishing

```bash
python3 -m venv /tmp/ashvenv
/tmp/ashvenv/bin/pip install "openai==3.1.0"
PY=/tmp/ashvenv/bin/python ./test-cases/scripts/run-all.sh          # expect 50/50
PY=/tmp/ashvenv/bin/python ./sweep.sh                               # compare with VALIDATION.md
PY=/tmp/ashvenv/bin/python ./validation/permutations.sh             # expect PERMUTATIONS PASSED
PATH=/tmp/ashvenv/bin:$PATH ./setup-timing.sh                       # expect 6-8s foreground
```

Then, once on the real image:

```bash
IMAGE=jrei/systemd-ubuntu ./setup-timing.sh --image
```

and after provisioning a real lab VM:

```bash
grep '^WARN' /var/log/ashford-lab/setup-status     # should print nothing
cat /var/log/ashford-lab/deps.state                # should say: pinned
tail -1 /var/log/ashford-lab/setup.log             # total setup time
curl -s 127.0.0.1:8836/health
find /home/user/ashford-grid ! -user user          # should print nothing, before and after grading
cat /tmp/ashford_timing.log                        # per-check wall time
```

## Optional: an ungraded look at a real model

Nothing in the lab requires a hosted model, and grading must never depend on one. If you want to
demonstrate the same `solution.py` against a real provider in class, point the learner's client at
it without touching any code:

```bash
export ASHFORD_BASE_URL=https://api.openai.com/v1
export ASHFORD_API_KEY=sk-...
export ASHFORD_MODEL=gpt-4o-mini
cd /home/user/ashford-grid && python3 check_local.py
```

Tasks 4 and 5 behave; Tasks 1–3 will differ, because the draft, the review wording and the repair
all come from the model rather than from the local endpoint, and the graded values are keyed to the
local one. Do this as a demonstration only, and unset those variables before submitting.
