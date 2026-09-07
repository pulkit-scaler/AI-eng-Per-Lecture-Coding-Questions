# Instructor setup — `ashcombe-intake`

## Portal configuration

- **Image:** systemd Ubuntu (Ubuntu 25.04 / Python 3.13.3).
- **Setup script:** `dist/Setup.zip`. **Test cases:** `dist/TestCase.zip`.
- **Number of test cases:** 5. **Points per test case:** 10. **Max Score: 50.**
- **Problem statement:** `problem-statement.md`.

## What provisioning does

1. Installs `python3` in the foreground and nothing else.
2. Detaches a job that installs `python3-pip`, `curl`, `jq` and
   **`pymupdf==1.24.14`** (falling back to the current series), warms a document
   open, then publishes `/var/log/ashcombe-lab/deps.ready`.
3. Writes `/home/user/ashcombe-intake`: `intake_kit/`, three module starters
   under `intake/`, `check_local.py`, and an empty `inbox/`, `out/` and
   `ledger.jsonl`, all owned by `user`.
4. Writes the intake desk to `/opt/ashcombe-svc/` as `root:root 0700` — both
   `intakesvc.py` and the generated `corpus.py` — and starts it on
   `127.0.0.1:8777`.
5. **After** the desk is up, pulls the three sample documents from the desk's
   unauthenticated `/v1/samples` endpoint into `inbox/` and chowns them to
   `user`. The documents are binary, so this keeps ~25 KB of base64 out of the
   setup script and guarantees the files match the plans the desk holds.

## The intake desk

`intakesvc.py` is the parsing API. It takes a document and a strategy and
returns typed elements. It recognises a document by the SHA-256 of the bytes it
was sent, so the learner's code has to actually read the file: a request that
carries something else gets a `422` and is counted.

The three strategies differ in what they can see and what they cost per page —
`fast` 1, `hi_res` 5, `ocr_only` 8 — and `fast` on a page with no text layer
returns nothing at all. That asymmetry is the lab.

Grader-only endpoints sit behind an `X-Grader-Key` header under `/__ac5t` and
return a plain 404 without it: `/trace?run=`, `/reset?run=`, `/corpus?set=`,
`/expected?sha=`. The five graded documents are served from there, so they never
appear in the learner project or in the setup script.

There is no hosted model anywhere in this lab and no key to supply.

## Marking notes

- **Many shapes pass.** Triage may count characters or text blocks; the chunker
  may buffer a string or accumulate parts; routing may be a table or a branch;
  "already done" may be read from the ledger or from the artefacts; the worker
  may write an extra manifest. All five alternatives in `reference-solution/`
  score 50/50.
- **The check scripts never write into the learner project.** They drain a spool
  under a root-only temporary directory, so a learner's own `inbox/`, `out/` and
  `ledger.jsonl` come through grading untouched. The ordering matrix asserts
  that rather than assuming it.
- Each check clears its own run on the desk before it starts counting, because a
  second grading run on the same VM meets a desk that remembers the first.
- Check 2 reads what the API was asked to do, so a worker that invents elements
  instead of parsing scores 40/50 (`_cheat_no_parse`).

## Before the first cohort

Run once **as root on the image**:

    ./validation/permutations.sh
    ./validation/vm-e2e.sh --here

`permutations.sh` covers the ordering matrix; `vm-e2e.sh --here` provisions the
lab from `dist/Setup.zip` and grades with **nothing overridden**, which is the
only harness that exercises the paths and ports the checks actually ship with.
Both are green in a cold `ubuntu:25.04` container, but that container has no
systemd — so on the first real VM also confirm:

    systemctl status ashcombe-desk        # should be active (running)
    tail -5 /var/log/ashcombe-lab/setup.log

If the desk is down, `/var/log/ashcombe-desk.log` says why in one line.
