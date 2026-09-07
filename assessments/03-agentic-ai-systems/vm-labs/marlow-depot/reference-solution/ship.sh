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
