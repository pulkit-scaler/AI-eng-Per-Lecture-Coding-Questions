# Instructor smoke test - NOT shipped to the learner.
# Paste this whole block into the lab VM terminal to write the reference
# solution without an editor. Then:  docker compose up -d --build
# It is byte-identical to reference-solution/{Dockerfile,dockerignore,
# docker-compose.yml,ship.sh}; regenerate it with the recipe in VALIDATION.md.

cd ~/marlow-depot

cat > depot-api/Dockerfile <<'DF'
# Two stages. Everything needed to *build* the wheels - including the C
# toolchain the depot fingerprint extension needs - lives in the builder and
# never reaches the image that ships.

# ---------- stage 1: builder ----------
FROM python:3.11 AS builder

ENV PIP_DISABLE_PIP_VERSION_CHECK=1 \
    PIP_NO_CACHE_DIR=1

# An isolated virtualenv so stage 2 can copy one self-contained directory.
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

WORKDIR /build

# Dependencies FIRST, application code SECOND: this is the layer-caching trick.
# Nothing below this line changes when app.py does, so the pip layer is reused.
COPY requirements.txt ./requirements.txt
COPY vendor ./vendor
RUN pip install --no-cache-dir -r requirements.txt

# ---------- stage 2: runtime ----------
FROM python:3.11-slim AS runtime

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PATH="/opt/venv/bin:$PATH" \
    DEPOT_INDEX_DIR=/index

# Only the finished virtualenv crosses over. No compiler, no build headers, no
# pip download cache.
COPY --from=builder /opt/venv /opt/venv

WORKDIR /app

# Application code last, because it is what changes most often.
COPY matching.py indexer.py app.py version.txt ./
COPY catalog ./catalog

# The index directory has to be writable by the user the container runs as.
# Docker seeds a fresh named volume from this path, ownership included.
RUN useradd --create-home --uid 10001 depot \
    && mkdir -p /index \
    && chown -R depot:depot /index /app
USER depot

EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
DF

cat > depot-api/.dockerignore <<'DI'
# Keep the build context to what the image actually needs.
.env
.venv/
venv/
__pycache__/
**/__pycache__/
*.pyc
local_index/
dist/
.git/
.DS_Store
DI

cat > docker-compose.yml <<'DC'
version: "3.8"

services:
  # The adviser backend. Published on loopback only so it can be inspected from
  # this machine without being reachable from anywhere else.
  llm:
    image: ai-lab/depot-llm:1.0
    ports:
      - "127.0.0.1:9000:9000"

  # One-shot index build. Same image as the API, different command.
  indexer:
    image: marlow-depot/depot-api:latest
    build: ./depot-api
    command: ["python", "indexer.py"]
    environment:
      DEPOT_INDEX_DIR: /index
    volumes:
      - depot-index:/index
    restart: "no"

  depot-api:
    image: marlow-depot/depot-api:latest
    build: ./depot-api
    # The credential is read at run time. It is never a build argument and
    # never an ENV line in the Dockerfile.
    env_file:
      - ./depot-api/.env
    environment:
      DEPOT_INDEX_DIR: /index
      DEPOT_LLM_URL: http://llm:9000/v1
    ports:
      - "8000:8000"
    volumes:
      - depot-index:/index
    depends_on:
      indexer:
        condition: service_completed_successfully
      llm:
        condition: service_started

volumes:
  depot-index:
DC

cat > ship.sh <<'SH'
#!/bin/bash
# Tag the built image for release and save it as a portable tarball.
set -euo pipefail
cd "$(dirname "$0")"

SRC="marlow-depot/depot-api:latest"
TAG="marlow-depot/depot-api:1.0"
OUT="dist/depot-api-1.0.tar"

docker image inspect "$SRC" >/dev/null 2>&1 || {
    echo "$SRC is not built yet - run: docker compose build" >&2
    exit 1
}

docker tag "$SRC" "$TAG"
mkdir -p dist
rm -f "$OUT"
docker save -o "$OUT" "$TAG"

echo "saved ${TAG} -> ${OUT} ($(du -h "$OUT" | cut -f1))"
SH
chmod +x ship.sh
ls -la . depot-api/Dockerfile depot-api/.dockerignore
