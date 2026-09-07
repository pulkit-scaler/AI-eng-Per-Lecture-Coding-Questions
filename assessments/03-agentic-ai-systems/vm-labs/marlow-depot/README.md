# `marlow-depot` — Containerization with Docker for AI Engineering (M3-L4)

A VM lab in which the learner writes **no Python at all**. They are handed a
working parts-adviser service and must package it: a multi-stage `Dockerfile`, a
`.dockerignore`, a three-service `docker-compose.yml` and a release script. Each
of the five checks builds, starts, measures or reloads the thing they wrote.

- **Target image:** *Alpine Docker* (`nestybox/alpine-docker`) — Alpine 3.15,
  musl, busybox coreutils, **Docker 20.10.11 + Compose v2.1.1**, classic builder
  (no buildx), **no `python3` on the host**. It is the only portal image with a
  Docker daemon.
- **Max Score 50 = 5 checks × 10.**
- **Project:** `/home/user/marlow-depot`. **API on host port 8000**, adviser
  backend on **9000**.

## What the learner writes

- `depot-api/Dockerfile`
- `depot-api/.dockerignore`
- `docker-compose.yml`
- `ship.sh`

## The five themes

1. **Cold start** — from a *cleared* volume, the one-shot `indexer` service runs
   to completion and only then does `depot-api` start; the API serves all 24
   parts and 118 tokens, reports the catalogue fingerprint the compiled C
   extension produces, and answers a `/match` whose note came from the adviser
   backend (the backend request counter moves).
2. **Shipping image** — under half the size of `python:3.11` measured on the
   same daemon, no `gcc`/`cc`/`g++` on its `PATH`, and it still imports
   `fastapi`, `pandas` and the compiled `depot_hash` module, which returns the
   expected fingerprint.
3. **Credential handling** — the running container reports the fingerprint of
   the key in `.env`, runs as a non-zero uid, and neither `Config.Env`,
   `docker history` nor the image filesystem holds the key, the local virtualenv
   or the stale local index.
4. **Layer ordering** — the grader edits one line of application source and
   rebuilds; the rebuild must finish inside 30 s and the running service must
   report the change.
5. **Release archive** — `ship.sh` tags `:1.0` and writes
   `dist/depot-api-1.0.tar`; the grader clears the tag, loads the archive on its
   own, and that image indexes a fresh volume and answers correctly on an
   isolated network.

## Why the ordering check clears the volume

A stack that has run once has an index on its volume, so an API that starts too
early finds an index anyway and the mistake is invisible. `script_01.sh`
therefore runs `docker compose down -v` before `up -d`. That is the only way the
`service_completed_successfully` requirement is actually earned, and it is why
the provided `app.py` exits 3 rather than serving an empty catalogue.

## Why `requirements.txt` contains a C extension

`vendor/depot_hash` is a small C extension. It makes the multi-stage split
load-bearing rather than decorative: the stage that installs the requirements
needs a compiler, and the check for a lean shipping image would fail if that
compiler travelled. Learners can satisfy it with two stages, or with one stage
that installs and purges the toolchain inside a single layer — both score 50.

## Pack layout

```
app/            everything provided to the learner
service/        the adviser backend source + its Dockerfile (baked to an image,
                then deleted from disk by setup - the learner only ever gets
                ai-lab/depot-llm:1.0, whose Python is compiled-only)
setup/          setup_script.template.sh -> scripts/setup_script.sh (generated)
reference-solution/
                the model answer, five alternative correct shapes, six defect
                probes and one fabrication probe
test-cases/scripts/
                script_01..05.sh (shipped), plus common.sh and run-all.sh
                (authoring only, never shipped)
validation/     the ordering matrix
dist/           Setup.zip + TestCase.zip
```

## Authoring commands

```bash
./gen_tests.sh                  # regenerate the five checks from one preamble
./build.sh                      # verify every invariant, restage both zips
./test-cases/scripts/run-all.sh # grade the reference
./sweep.sh                      # grade every candidate
./validation/permutations.sh    # the ordering matrix (run as root on the VM once)
```

See `VALIDATION.md` for observed numbers and the one item a non-VM host cannot
settle.
