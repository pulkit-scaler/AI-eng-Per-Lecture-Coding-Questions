#!/bin/sh
# Release tag built straight from the context, then piped to a file.
set -eu
cd "$(dirname "$0")"
docker build -t marlow-depot/depot-api:1.0 ./depot-api
mkdir -p dist
docker save marlow-depot/depot-api:1.0 > dist/depot-api-1.0.tar
echo "release archive written"
