#!/bin/bash
# Provision the pack inside a Linux container that stands in for the lab image,
# then run the real setup script as root and the ordering matrix on top of it.
#
# This is what makes the root-ownership assertions mean something: on the
# authoring machine the checks do not run as root and every such assertion is
# vacuous. The container is Ubuntu 25.04 (the release the target image actually
# runs, whatever its catalogue entry says), with no pip preinstalled, so the
# dependency ladder in setup is exercised rather than skipped.
#
#   ./validation/run-in-docker.sh              # setup + permutation matrix
#   ./validation/run-in-docker.sh setup        # just provision and report
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-all}"
IMAGE="caldon-wire-validate:1.0"

echo "=== building the stand-in image ==="
docker build -q -t "$IMAGE" - <<'DOCKERFILE'
FROM ubuntu:25.04
ENV DEBIAN_FRONTEND=noninteractive
# python3 only, deliberately: no pip, no curl, no jq. The setup script has to
# install them itself, which is the path the real image takes.
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends python3 ca-certificates \
 && rm -rf /var/lib/apt/lists/*
RUN useradd -m -s /bin/bash user
CMD ["sleep", "infinity"]
DOCKERFILE

NAME="caldon-validate-$$"
cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --name "$NAME" -v "$DIR:/pack:ro" "$IMAGE" >/dev/null
echo "container: $NAME"

echo
echo "=== running setup_script.sh as root ==="
START=$(date +%s)
docker exec "$NAME" bash -c 'cp -r /pack /pack-rw 2>/dev/null; bash /pack/setup/scripts/setup_script.sh' \
    2>&1 | tail -40
ELAPSED=$(( $(date +%s) - START ))
echo "--- foreground setup wall clock: ${ELAPSED}s ---"

echo
echo "=== what setup produced ==="
docker exec "$NAME" bash -c '
    echo "project:"; ls -la /home/user/caldon-wire | sed "s/^/    /"
    echo "ownership of anything root still holds under the project:"
    find /home/user/caldon-wire -user root | sed "s/^/    /" || true
    echo "wire desk health:"
    python3 -c "import urllib.request;print(urllib.request.urlopen(\"http://127.0.0.1:8794/health\",timeout=3).read().decode())" 2>&1 | sed "s/^/    /"
'

if [ "$MODE" = "setup" ]; then
    echo
    echo "setup-only mode; container removed."
    exit 0
fi

echo
echo "=== waiting for the detached dependency install ==="
docker exec "$NAME" bash -c '
    for i in $(seq 1 240); do
        [ -f /var/log/caldon-lab/deps.ready ] && { echo "deps ready after ${i}s"; exit 0; }
        sleep 1
    done
    echo "deps never became ready"; tail -20 /var/log/caldon-lab/pip.log; exit 1'

echo
echo "=== permutation matrix (as root, the way the judge runs) ==="
docker exec "$NAME" bash -c 'PACK=/pack bash /pack/validation/permutations.sh'
