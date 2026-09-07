# Instructor Setup Guide — Kilnbrook Foundry

## Portal configuration

- **Setup file:** `dist/Setup.zip`
- **Test Case zip:** `dist/TestCase.zip`
- **Number of checks:** 5 (the platform accepts no more than five)
- **Points per check:** 10
- **Max Score:** 50
- **Time limit:** 60–75 minutes (the lab is five functions in one file; 60 is comfortable)
- **Duration:** match the time limit
- **Image family:** **systemd Ubuntu** — recon-confirmed as Ubuntu **25.04**, Python **3.13.3**, no
  pip and no `ensurepip`, `/usr/lib/python3.13/EXTERNALLY-MANAGED` present (PEP 668), `sudo` present
  but needing a password, no gcc/make/git/Docker, and `timeout`/`curl`/`wget`/`jq`/`vim` present.
  The ttyd Ubuntu 20.04 image ships no `python3` at all and its apt Python is 3.8; the Alpine
  Docker image is musl and has no `python3`. Neither can host this lab.

Both zips contain a `scripts/` **and** a `data/` folder at the root; `data/` is empty here but must
be present. `build.sh` creates both and fails the build if either is missing.

## Prerequisites for the image

- **Outbound HTTPS at setup time only**, to `apt` for `python3-pip`/`curl`/`jq` and to PyPI for the
  `openai` wheel. Grading itself never leaves the VM.
- `python3` (3.9+). Everything else setup installs itself.
- A terminal editor (`nano` or `vi`). The learner writes one Python file.

## What the learner sees

- `/home/user/kilnbrook-foundry/` — `kiln_kit/` (provided), `data/foundry.db` (provided),
  `check_local.py` (provided) and `solution.py` (the starter they fill in). `solution.py` and the
  database are written only when absent, so re-running setup never destroys work in progress.
- Nothing else. The endpoint lives at `/opt/kilnbrook-svc/foundryd.py`, `root:root`, mode `0700`,
  and the database builder runs from `/tmp` and is deleted in the same phase.

## What setup does

Phases, in the order they run, with what is deliberately **not** in the foreground:

1. **Base packages (foreground).** `python3` only, and only if absent. Everything else is a consumer
   that comes later. Also symlinks `/usr/local/bin/python` → `python3` and writes `/etc/pip.conf`
   with `break-system-packages = true`, since the image is externally managed.
2. **Runtime dependencies (detached).** A generated job launched under `setsid` installs
   `python3-pip`, `curl` and `jq` (with `--no-install-recommends`, which avoids pulling
   `build-essential`), then `pip install --only-binary=:all: openai==3.1.0`, falling back to
   unpinned `openai` and recording `pinned`/`latest`/`failed` in
   `/var/log/kilnbrook-lab/deps.state`. It bridges `~/.local` into the admin site directory with a
   `.pth` file, warms the import and fires one real request, then publishes
   `/var/log/kilnbrook-lab/deps.ready`.
3. **Project skeleton and database (foreground).** Writes `kiln_kit/`, `check_local.py` and the
   `solution.py` starter, builds `data/foundry.db` with the stdlib-only builder, and **chowns the
   project to `user` immediately** — before the riskier steps — so a later failure can never leave
   the learner with read-only files.
4. **Endpoint files.** `/opt/kilnbrook-svc/foundryd.py`, `root:root`, `0700`.
5. **Starting the endpoint.** A `kilnbrook-foundryd` systemd unit, falling back to a detached
   background process where `systemctl` is unavailable. The health probe is `python3` + `urllib`,
   not `curl`, because `curl` is not on the foreground path.
6. **Grading tools and dependency hand-off.** Installs `curl` and `jq` in the **foreground** if they
   are absent, since every check shells out to both and a submission made while the detached job is
   still running would otherwise have no way to tell a missing tool from a wrong answer. This sits
   at phase 6 on purpose: the project, the database and the endpoint are already in place by then,
   so the essentials never queue behind an apt call. Measured on `ubuntu:25.04`: on an image that
   already ships `curl` and `jq` (the portal image does) nothing is installed and the whole
   foreground is 4s; on a bare image with neither, plus no `python3`, the endpoint is up at t+33s and
   the foreground finishes at 54s. Then a 2-second grace so an already-finished pip install is
   reported accurately, and nothing more. The pip install continues in the background afterwards.
7. **Permissions and summary.** Re-chowns, and prints either a ready banner or `LAB NOT READY` with
   the blockers named.

Setup never fails the provisioning step. Every problem is recorded as a `WARN` line in
`/var/log/kilnbrook-lab/setup-status`; the full log is `/var/log/kilnbrook-lab/setup.log`, and the
pip log is `/var/log/kilnbrook-lab/pip.log`.

## Grading behaviour worth knowing about

**Scoring is a prefix, not a sum.** The platform's `main.sh` breaks out of its loop at the first
check that does not report success, so a submission that fails check 1 never runs checks 2 to 5 and
is awarded 0, not 40. The five checks are ordered by how little each one depends on, so partial
credit tracks how far a learner got: TC01 needs Tasks 1 and 2 only (the check sends the request
itself, so `run_agent` is not involved), TC02 needs Task 3 only, TC03 grades the loop, TC04 the
shared conversation, TC05 the guard driven through the loop. `sweep.sh` prints both numbers, `SCORE`
for the per-theme sum and `PORTAL` for the prefix.

**A learner who completes all five tasks scores 50/50 on their first submission.** No check is
expected to fail on a first attempt and no resubmission is required. No check depends on the
learner having run anything beforehand — every check runs their code itself — so submitting before
running `check_local.py` still scores full marks.

Each check runs the learner's code in **one** fresh `python3` process from
`/home/user/kilnbrook-foundry` with a distinct `KILN_SESSION`, so the session record the check reads
back from the endpoint belongs to that check alone. Five checks means five interpreter starts and
nothing more.

Each script starts the endpoint on demand (`ensure_service`) if it is not answering, so a check
never fails merely because the unit was restarted, and calls `ensure_deps` **before** anything that
shells out to `curl` or `jq` — the readiness marker gates those two as well as `openai`.

Grading runs as **root** while the learner is `user`. Every check exports
`PYTHONDONTWRITEBYTECODE=1` and hands ownership back with `chown -R user:user` from an `EXIT` trap,
so a run killed at the time cap still leaves a usable VM. The repair is gated on the `user` account
existing (`id -u user`), not on where `LAB_DIR` points; the earlier form fired only for
`/home/user/*`, and every local harness runs with `LAB_DIR=/tmp/...`, so the repair never ran in the
environment that tests it. The `case` arm still refuses an empty variable and a bare `/`. `build.sh`
refuses to ship a check missing either.

**Judge fidelity.** The platform's `/usr/local/bin/judge/test/common.sh` installs
`trap 'handle_script_error ...' ERR` in the check's own shell. Left in place it prints an
`INTERNAL_ERROR` line after the verdict, and since `main.sh` grades the **last** line of stdout and
stderr combined, the verdict is discarded and the learner sees an empty "Test Case Results:" panel.
Every check therefore runs `trap - ERR`, `set +eE` and `exec 2>>/tmp/kilnbrook_tc<NN>.err` in its
preamble, and `build.sh` refuses to ship one that does not. `test-cases/scripts/common.sh` in this
pack is a faithful replica of the platform helper, not a convenience stub, so local validation sees
the same behaviour the portal does.

## Time budgets

The portal kills a setup script or a single test case that runs much beyond two minutes and reports
a blocking process instead of a score. Both paths are bounded and both report their own timing.

- **Test cases.** Every wait sits under one of four constants in each script's preamble —
  `SVC_WAIT=12`, `RUN_BUDGET=55` (the bound around the one learner run), `CURL_MAX=5`,
  `DEPS_WAIT=20` — for a worst case near 107s. `build.sh` refuses to ship a script missing them.
  `RUN_BUDGET` is enforced by `run_bounded()`, which uses coreutils `timeout` where it exists and a
  shell watchdog where it does not, so the bound is never silently inert. Measured on the authoring
  host every check finishes in ≤1s; each check appends its own wall time to
  `/tmp/kilnbrook_timing.log` on the VM.
- **Setup.** `foundryd.py` and the database builder are pure standard library, so nothing the
  foreground does needs pip. The measured foreground is in `VALIDATION.md`. Each phase logs
  `t+<n>s` and the script ends with `total setup time: <n>s` — **read that line after the first
  provisioning on the real image.**

## The endpoint, for when you need to look inside

`/opt/kilnbrook-svc/foundryd.py` serves `POST /v1/chat/completions` (OpenAI-compatible) and
`GET /health` openly, plus a restricted surface behind the header
`X-Kiln-Audit: kilnbrook-audit-q7z2` which returns a plain 404 without it:

- `GET /__kbz7q/trace?session=<id>` — the session record: chat turns, the system prompts received,
  the verdict on the persona and on each tool schema, the steps planned per question, each
  observation with whether its `tool_call_id` matched, and whether the turn cap was hit.
- `GET /__kbz7q/oracle?q=<question>` — the true answer for a known question, computed by running its
  read-only SQL against the database.
- `GET /__kbz7q/query?sql=<select>` — the true cell values of any read-only query.
- `GET /__kbz7q/schema[?table=<name>]` — the real table and column names.
- `POST /__kbz7q/trace/reset?session=<id>` — forget one session.

It opens the database **read-only** (`file:...?mode=ro`), so the endpoint itself can never alter the
file the learner's tools work against — which is what makes TC05's byte-for-byte comparison mean
something.

Useful one-liners on the VM:

```bash
curl -s 127.0.0.1:8781/health
K='X-Kiln-Audit: kilnbrook-audit-q7z2'
curl -s -H "$K" '127.0.0.1:8781/__kbz7q/schema?table=pours' | jq .
curl -s -H "$K" '127.0.0.1:8781/__kbz7q/trace?session=local' | jq .
```

## Troubleshooting

- **Every check fails with "The model endpoint is not reachable".** `systemctl status
  kilnbrook-foundryd`, then `curl -s 127.0.0.1:8781/health`. If the unit is missing, the nohup
  fallback was used and the process was killed; the checks restart it themselves, so this should
  self-heal on the next submission.
- **Every check fails with "The lab Python dependencies are not installed".** The pip install did
  not finish: `cat /var/log/kilnbrook-lab/deps.state` and `tail -40
  /var/log/kilnbrook-lab/pip.log`. `failed` there means no wheel resolved — check outbound HTTPS.
- **TC01 fails with `persona_complete=false`.** The failure message lists exactly which parts were
  missing (`role`, `rule3`, `instructions`, `output_format`). The comparison ignores all layout: it
  lowercases and collapses whitespace, so only genuinely absent text can fail it.
- **TC01 fails with `tool_schemas_valid=false`.** The message carries the endpoint's own complaints,
  e.g. `table_name is not in required` or `description is empty`. Note this also fails TC03, TC04
  and TC05 by design — a schema the endpoint cannot act on means no tool is ever called.
- **TC03 fails with `results_matched_to_their_call_id=0/3`.** The submission is feeding results back
  under an identifier it made up instead of `call.id`.
- **TC04 fails with `second_question_tools=["list_tables","get_table_schema","execute_sql"]`.** The
  submission is starting a fresh conversation per question, so nothing carries over.
- **TC05 fails with `database_unchanged=no`.** The read-only guard let a data-modifying statement
  through. Restore the database with a fresh provisioning, or delete
  `/home/user/kilnbrook-foundry/data/foundry.db` and re-run the setup script, which rebuilds it.
- **A learner reports `E45: readonly option is set`.** That would mean the project was left
  root-owned. `find /home/user/kilnbrook-foundry -user root` should print nothing; if it does, the
  `EXIT`-trap `chown` in the checks did not run, which is a pack bug worth reporting.
- **The learner sees an empty "Test Case Results:" panel with no rows.** That is the judge grading a
  line that is not a verdict, not a scoring problem. Read `/tmp/kilnbrook_tc<NN>.err` on the VM for
  the check's own stderr, and confirm the shipped scripts still carry `trap - ERR` and the
  `exec 2>>` redirect.
- **A check fails with "This VM is not ready to be graded".** The message names which of `curl`,
  `jq` or `openai` is missing. `cat /var/log/kilnbrook-lab/deps.state` and
  `tail -40 /var/log/kilnbrook-lab/pip.log`.

## Optional: pointing the lab at a real model

Nothing in the learner's code is specific to the local endpoint — it is the ordinary
`chat.completions` API. Setting `KILN_ENDPOINT` and supplying a real key in
`kiln_kit/client.py` would make a correct `solution.py` run against a hosted model unchanged. That
is a demonstration, not a graded mode: a hosted model's tool selection is not reproducible enough
to grade against, so the checks stay on the local endpoint.
