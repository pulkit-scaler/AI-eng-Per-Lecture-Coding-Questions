# Instructor setup — `marlow-depot`

## Portal configuration

- **Lab image:** *Alpine Docker* (`nestybox/alpine-docker`). This is not
  optional: it is the only image on the portal with a Docker daemon, and the
  other two ship no Docker at all. Installing an engine during provisioning is
  the failure class that produces *"Unable to Load the Lab"*.
- **Setup script:** `dist/Setup.zip` (root has `scripts/setup_script.sh` and an
  empty `data/`).
- **Test cases:** `dist/TestCase.zip` (root has `scripts/script_01..05.sh` and
  an empty `data/`).
- **Max Score: 50.** Five test cases, **10 points each**. Set the per-case score
  to 10 in the portal.
- **Problem statement:** `problem-statement.md`, pasted as-is. It has no
  markdown tables, because the portal renderer shows them as literal pipes.

## What provisioning does

Foreground, in a few seconds:

1. Verifies the Docker CLI, the daemon and the `docker compose` plugin, and that
   `user` is in the `docker` group.
2. Writes `/home/user/marlow-depot/` — the service, the index builder, the
   catalogue, the vendored C extension, `requirements.txt`, `version.txt`,
   `.env`, the project `README.md`, and the three pieces of local-checkout
   clutter (`local_index/`, `.venv/`, `__pycache__/`) that make
   `.dockerignore` a real task. **Chowned to `user` immediately**, before any
   step that could fail.
3. Pre-creates `dist/` owned by `user`, because that is where the checks make
   the learner write their release archive.

Detached, publishing `/var/log/marlow-lab/images.ready` when done:

4. Pulls `python:3.11-slim`, builds `ai-lab/depot-llm:1.0` from a root-only
   staging directory, **deletes that directory**, then pulls `python:3.11`.

The learner can start on the Dockerfile immediately; the pulls land behind them.
Every check waits on `images.ready` only when the images are actually missing,
so the normal cost of that wait is one `docker image inspect`.

## Time budgets

- Setup foreground: a few seconds. Hard internal deadline **95 s**, on expiry it
  prints a summary and exits 0 rather than being killed.
- Each check: bounded so the worst case is about **111 s** against the portal's
  ~120 s cap. The cold-start check is the expensive one (`down -v` + `up -d` +
  health wait). Observed on the authoring host: 13 s.
- Every check appends its wall time to `/tmp/marlow_timing.log`, so a cap hit is
  diagnosable from the VM instead of re-measured by guesswork.

## What the checks will not do

They will **not build the learner's image**. If `marlow-depot/depot-api:latest`
does not exist, every check refuses in about a second with a message telling
them to run `docker compose up -d --build` and confirm `/health` first. That is
deliberate: a first build takes a couple of minutes, which is most of a test
case, and a check that quietly does the learner's work also hides whether their
Dockerfile works.

`script_01.sh` runs `docker compose down -v`, which discards the index volume.
That is the point of the check, and the same `up` rebuilds it. `script_04.sh`
edits `depot-api/version.txt` and writes the original value back afterwards.
`script_05.sh` clears the `:1.0` tag and restores it from the learner's own
archive. Nothing else the learner owns is touched, and every check hands
ownership of the project back from an `EXIT` trap rather than from a success
path — so a run killed at the cap still leaves a usable VM.

## Marking notes

- Two shapes both score 50: two stages (builder on `python:3.11`, runtime on
  `python:3.11-slim`), or one stage on slim that installs and purges the
  toolchain inside a single `RUN`. Both were graded during authoring.
- A learner who copies the application code in before installing the
  requirements loses **check 4 only** (the rebuild exceeds its ceiling).
- A learner who forgets `service_completed_successfully` loses **check 1**, and
  will usually lose checks 3 and 4 with it, because on a cold volume their API
  is not running at all and those themes cannot be observed. That is honest
  rather than harsh: the service is down.
- A learner who never drops root, or whose `.dockerignore` lets `.env` through,
  loses **check 3 only**.
- A `ship.sh` that tags but never saves loses **check 5 only**.

## Before the first cohort

Run `validation/permutations.sh` **as root on a provisioned VM** once. It is the
only place the root-ownership invariant is not vacuous: on an authoring host
with no `user` account those rows self-report as vacuous instead of passing
silently. `VALIDATION.md` records exactly what is and is not yet proven.
