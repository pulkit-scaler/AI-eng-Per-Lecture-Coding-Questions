# Marlow Depot — Ship the Parts Adviser

## Overview

Marlow Depot runs a small service that turns a maintenance complaint into a part
number. A fitter types *"conveyor drive belt slipping badly"*, the service
ranks the catalogue, and an adviser backend writes the one-line recommendation
that goes on the picking slip.

The service works. It has never been containerized. Today you package it and
run it as a Compose stack: a one-shot index build, the API itself, and the
adviser backend it talks to.

**You write no Python.** Every line of application code is already on the
machine. Your deliverables are a `Dockerfile`, a `.dockerignore`, a
`docker-compose.yml` and a small release script — and each one is judged by
what happens when it is actually built, started and handed to somebody else.

## Learning objectives

- Write a **multi-stage** Dockerfile whose shipping image carries the finished
  dependencies but none of the toolchain that produced them.
- Order layers so that a one-line change to application code does **not**
  reinstall the dependency set.
- Keep the build context clean with `.dockerignore`, and know exactly which
  files must never reach an image.
- Inject a credential at **run time** and prove it is absent from the image, its
  configuration and its build history.
- Compose a stack where a **one-shot job** populates a named volume before a
  long-running service is allowed to read it.
- Drop privileges in the shipping image, including making a mounted volume
  writable by the user the container runs as.
- Move a finished image to another machine with `docker save` and `docker load`,
  with no registry involved.

## Environment

The VM is already provisioned — you install nothing.

- **Docker 20.10.11** with the **`docker compose` v2.1.1** plugin. Use
  `docker compose` (two words); there is no `docker-compose` binary.
- The builder is the **classic** one: `docker buildx` is not installed, so
  BuildKit-only Dockerfile syntax such as `RUN --mount=type=cache` or
  `COPY --link` will not parse. Ordinary Dockerfile instructions are all you
  need.
- The Docker daemon is already running and your account can use it without
  `sudo`.
- There is **no Python on the host**. Every Python process in this lab runs
  inside a container; do not try to run `app.py` directly.
- **The VM has internet access.** Your builds may install from PyPI.
- Three images are already on the machine, so nothing large has to download
  while you work. Check with `docker images`:
  - `python:3.11` — a full build environment, including a C compiler.
  - `python:3.11-slim` — the same interpreter without the build tooling.
  - `ai-lab/depot-llm:1.0` — the adviser backend, listening on port 9000.
- Work in `/home/user/marlow-depot`. Run every `docker compose` command from
  that directory so the project is picked up correctly.
- `vim` and `nano` are installed. If a full-screen editor will not display in
  your terminal, write the file straight from the shell instead — this works
  everywhere:

```
cat > docker-compose.yml <<'END'
services:
  llm:
    image: ai-lab/depot-llm:1.0
END
```

## What is provided

Under `/home/user/marlow-depot/`:

```
depot-api/
  app.py              the API: GET /health, GET /whoami, POST /match
  indexer.py          one-shot index build; writes to DEPOT_INDEX_DIR, then exits
  matching.py         the token scoring both of those share
  catalog/parts.json  the depot catalogue
  vendor/depot_hash/  the fingerprint routine, compiled from C at install time
  requirements.txt    pinned dependencies
  version.txt         the version string /health reports
  .env                DEPOT_API_KEY
  local_index/        a stale index from somebody running things by hand
  .venv/              a local virtualenv, likewise
  __pycache__/        compiled bytecode, likewise
README.md             how the two processes fit together
dist/                 empty; your release archive goes here
```

Two facts about the application drive most of the work:

1. **`requirements.txt` includes `./vendor/depot_hash`**, a C extension. It has
   to be compiled during the build, so whatever installs the dependencies needs
   a C compiler. The compiled result is a single `.so` — the compiler itself is
   not needed afterwards.
2. **`app.py` checks for `manifest.json` in `DEPOT_INDEX_DIR` before it imports
   anything else, and exits with status 3 if it is not there.** There is no
   retry and no empty-catalogue mode. `indexer.py` writes `manifest.json` last,
   after the two index files.

## Interface contract

Your files are free in every respect except the names and addresses the depot
already publishes. Fix these exactly:

- Project root is `/home/user/marlow-depot`. Your files go at
  `depot-api/Dockerfile`, `depot-api/.dockerignore`, `docker-compose.yml` and
  `ship.sh`.
- The Compose services are named exactly **`depot-api`**, **`indexer`** and
  **`llm`**.
- The image built from `depot-api/` is tagged **`marlow-depot/depot-api:latest`**
  (set it with the `image:` key on the services that build it).
- `depot-api` listens on container port **8000** and is published on host port
  **8000**, so `http://127.0.0.1:8000/health` answers.
- `llm` uses the image **`ai-lab/depot-llm:1.0`** and publishes container port
  **9000** on host port **9000**.
- A named volume called **`depot-index`** is mounted at **`/index`** in both
  `indexer` and `depot-api`, and both get `DEPOT_INDEX_DIR=/index`.
- `depot-api` gets `DEPOT_LLM_URL=http://llm:9000/v1`.
- `indexer` runs `indexer.py` once and exits; `depot-api` serves the API.
- `DEPOT_API_KEY` reaches the `depot-api` container from
  `depot-api/.env` **at run time**.
- `ship.sh` is run from the project root. It tags
  **`marlow-depot/depot-api:1.0`** and writes **`dist/depot-api-1.0.tar`**.

Anything not on that list is yours: how many build stages, which base image each
stage uses, whether you use a virtualenv or wheels, how you name the runtime
user, and how you lay the image out internally.

---

### Task 1 — Write `depot-api/Dockerfile`

Package the service so the image that ships is small, self-contained and
unprivileged.

1. Install the pinned dependencies from `requirements.txt`. One of them is
   compiled from C, so the stage that installs it needs a compiler.
2. Arrange the build so that the **shipping** image contains the installed
   dependencies but **no C compiler** — no `gcc`, no `cc`, no `g++` on its
   `PATH`.
3. Keep the shipping image **under half the size of `python:3.11`**. Compare
   with `docker images`.
4. Copy in the application files the two processes need: `app.py`,
   `indexer.py`, `matching.py`, `version.txt` and `catalog/`.
5. Order the instructions so that editing `app.py` or `version.txt` does **not**
   invalidate the layer that installed the dependencies.
6. Create an unprivileged user and switch to it with `USER` before the default
   command. The API must not run as uid 0.
7. Create `/index` in the image and make it **owned by that unprivileged user**.
   Docker seeds a new named volume from the image directory it is mounted over,
   ownership included; skip this and the index build will not be able to write.
8. Default the container to serving the API:
   `uvicorn app:app --host 0.0.0.0 --port 8000`. Use the exec form (a JSON
   array) so the process receives stop signals.

**Requirements.** Both processes read `catalog/parts.json` and `version.txt`
relative to the working directory, so set a `WORKDIR` and copy those in
relative to it (or set `DEPOT_CATALOG` and `DEPOT_VERSION_FILE`). A
`HEALTHCHECK` is optional; if you add one, remember that anything it installs
counts against the size ceiling in step 3. Never put the credential in an `ENV`
line or a build argument — that is checked, in the image environment and in the
build history.

**Example.** With the image built, this is what a correct one looks like from
outside:

```
$ docker run --rm --entrypoint sh marlow-depot/depot-api:latest -c 'command -v gcc'
$ echo $?
1
$ docker run --rm --entrypoint python marlow-depot/depot-api:latest \
      -c 'import fastapi, pandas, depot_hash; print(depot_hash.fingerprint("marlow"))'
e867e47617a728d5
```

---

### Task 2 — Write `depot-api/.dockerignore`

The build context is a working checkout, and a working checkout is full of
things that must not travel.

1. Exclude `.env`. A credential inside an image is readable by anyone who ever
   pulls that image, and there is no way to take it back.
2. Exclude the local virtualenv `.venv/` — it holds binaries built for the
   host, not for the image.
3. Exclude `local_index/`, the stale index left over from a manual run. The real
   index is built by the `indexer` service into the volume.
4. Exclude compiled bytecode: `__pycache__/` and `*.pyc`.
5. Exclude anything else that is checkout noise rather than application input,
   such as `dist/` and `.git/`.

**Requirements.** `requirements.txt`, `vendor/`, `catalog/`, `version.txt` and
the three `.py` files must all still reach the build. Excluding one of those
breaks the build instead of tightening it.

Excluding `.env` here does **not** hide it from Task 3. `.dockerignore` controls
only what the *build* is allowed to see; the file stays on disk, and Compose
reads it from disk when it starts the container. Excluding it from the build and
reading it at run time are both required, and they do not conflict.

**Example.** After building, nothing on this list exists anywhere in the image:

```
$ docker run --rm --entrypoint sh marlow-depot/depot-api:latest \
      -c 'find / -xdev \( -name ".env" -o -name "local_index" -o -name ".venv" \)'
$
```

---

### Task 3 — Write `docker-compose.yml`

Three services, one volume, and a start order that the index build actually
controls.

1. Define `llm` from `ai-lab/depot-llm:1.0`, publishing container port 9000 on
   host port 9000.
2. Define `indexer`: built from `depot-api/`, tagged
   `marlow-depot/depot-api:latest`, running `indexer.py` once with
   `DEPOT_INDEX_DIR=/index` and the `depot-index` volume mounted at `/index`.
   It is a job, not a server: it exits when the index is written. Leave its
   restart policy alone — a service Compose keeps restarting never reaches the
   completed state that step 4 waits for.
3. Define `depot-api`: the same image, serving the API, with
   `DEPOT_INDEX_DIR=/index`, `DEPOT_LLM_URL=http://llm:9000/v1`, the same volume
   at `/index`, and container port 8000 published on host port 8000.
4. Make `depot-api` start **only after `indexer` has finished successfully**.
   Waiting for the container to have *started* is not enough — the index does
   not exist until the job has *exited*.
5. Supply `DEPOT_API_KEY` to `depot-api` from `depot-api/.env` at run time.
   Compose reads an env file for you. What is checked is where the key ends up:
   the running container must have it, and the image must not — not in its
   environment, not in a build argument, not in its history, not in its
   filesystem. Point Compose at the file rather than copying the key's value
   into your compose file: a credential written beside the service that uses it
   is the habit this task exists to break.
6. Declare the `depot-index` volume in the top-level `volumes:` section.

**Requirements.** This Compose is v2.1.1: `depends_on` with a condition is
supported, a top-level `name:` key is not. Do not rely on container names — this
version joins the project and service names with an underscore, and newer
versions use a hyphen.

**Example.** From a completely cold start, this is the sequence a correct stack
produces:

```
$ docker compose down -v          # nothing on the volume any more
$ docker compose up -d
 ... llm             Started
 ... indexer         Started
 ... indexer         Exited          <- the job finished
 ... depot-api       Started         <- only now
$ curl -s http://127.0.0.1:8000/health
{"status":"ok","version":"1.0.0","indexed_parts":24,"indexed_tokens":118,
 "catalog_fp":"12f0f145b74d574a"}
$ curl -s -X POST http://127.0.0.1:8000/match \
       -H 'Content-Type: application/json' \
       -d '{"need":"the hydraulic ram is weeping oil past the seal"}'
{"part_no":"PN-1077","name":"Hydraulic ram seal kit","bin":"A-05","stock":7,
 "score":15,"note":"Recommend PN-1077 (Hydraulic ram seal kit); 7 on hand in
 bin A-05. Ref 513c34aa.","need":"the hydraulic ram is weeping oil past the seal"}
```

---

### Task 4 — Write `ship.sh`

The depot has no registry. A release is a file somebody carries to the next
site.

1. Make the script runnable from the project root with `bash ship.sh`, and have
   it work regardless of which directory it is invoked from.
2. Refuse to continue, with a message and a non-zero exit, when
   `marlow-depot/depot-api:latest` has not been built yet.
3. Give the release a version tag: `marlow-depot/depot-api:1.0`. `latest` is not
   a version.
4. Write the tagged image to `dist/depot-api-1.0.tar` with `docker save`,
   creating `dist/` if it is not there and replacing any earlier archive.
5. Print what was written, so the person running it knows what to hand over.
   The wording is yours — nothing matches your output text.

**Requirements.** The archive must be loadable **on its own** — somebody with
only that file, plus `ai-lab/depot-llm:1.0`, has to be able to build an index on
a fresh volume and serve `/match`. You do not have to do anything extra to keep
the credential out of the archive: `docker save` writes exactly the image, so an
image without the key produces an archive without it. That is the point of
Task 1 and Task 2.

**Example.**

```
$ bash ship.sh
saved marlow-depot/depot-api:1.0 -> dist/depot-api-1.0.tar (101M)
$ docker rmi marlow-depot/depot-api:1.0 >/dev/null
$ docker load -i dist/depot-api-1.0.tar
Loaded image: marlow-depot/depot-api:1.0
```

---

## Run and verify before you submit

Bring your own stack up and confirm it answers. The checks read a stack you have
already built; they do not build one for you, and an unbuilt project is reported
as a missing image rather than graded.

```bash
cd /home/user/marlow-depot

docker compose up -d --build          # first build takes a couple of minutes
docker compose ps -a                  # indexer should be Exited (0)
curl -s http://127.0.0.1:8000/health
curl -s http://127.0.0.1:8000/whoami  # uid must not be 0, key_fp must be set

# the cold start, which is the one that proves your ordering
docker compose down -v
docker compose up -d
curl -s http://127.0.0.1:8000/health

# size and cleanliness
docker images marlow-depot/depot-api python:3.11
docker history marlow-depot/depot-api:latest | head

# the release
bash ship.sh
ls -l dist/
```

If something is wrong, `docker compose logs depot-api` and
`docker compose logs indexer` are the first place to look. Exit status 3 from
`depot-api` means it started before the index existed.

## How you are graded

Five checks, 10 points each, 50 in total. Each one builds, starts, measures or
loads what you wrote:

1. **Cold start.** From a cleared volume, the one-shot index build runs to
   completion and the API then serves the whole catalogue and answers a `/match`
   through the adviser backend.
2. **Shipping image.** It is under the size ceiling, has no C compiler in it,
   and can still import its dependencies including the compiled fingerprint
   module.
3. **Credential handling.** The running container has the key, and neither the
   image configuration, the build history nor the image filesystem does — and
   the process is not root.
4. **Layer ordering.** A one-line change to application source rebuilds quickly
   and the running service reports the change.
5. **Release archive.** `ship.sh` produces a tagged, saved image that, loaded
   from the archive alone, indexes a fresh volume and answers correctly.
