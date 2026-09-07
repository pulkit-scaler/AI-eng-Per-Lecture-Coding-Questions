#!/bin/bash
# Measure the setup script FOREGROUND wall clock on the target image family.
#
# The portal front end gives up if it cannot read the lab status within its polling
# window, and that window is unknown and tighter than the old ~120s assumption. So
# the number that matters is how long the foreground takes to hand over a usable
# lab, not how long the whole provisioning takes: pip, curl, jq and the openai wheel
# are installed by a detached job that keeps running after this returns.
#
#   ./setup-timing.sh                 # ubuntu:25.04 (the portal image family)
#   IMAGE=ubuntu:24.04 ./setup-timing.sh
#   TARGET=20 ./setup-timing.sh       # tighten the pass mark
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

IMAGE="${IMAGE:-ubuntu:25.04}"
TARGET="${TARGET:-30}"
RUNS="${RUNS:-2}"

command -v docker >/dev/null 2>&1 || {
    echo "docker is not available; run this where it is, or record the number from"
    echo "the portal log line 'total setup time: <n>s' after a real provisioning."
    exit 2
}

echo "image: $IMAGE   target: <=${TARGET}s foreground   runs: $RUNS"
echo ""
echo "Two numbers per run, because the portal image is not a bare base image:"
echo "  BARE   - the base image with no python3 at all, so phase 1 pays an apt install."
echo "  TARGET - python3 already present, which is what the portal image ships (3.13.3),"
echo "           measured by running the same script a second time in the same container."
WORST=0
for run in $(seq 1 "$RUNS"); do
    out="$(docker run --rm -v "$DIR:/pack:ro" "$IMAGE" bash -c '
        export DEBIAN_FRONTEND=noninteractive
        t0=$(date +%s)
        bash /pack/setup/scripts/setup_script.sh >/tmp/setup1.log 2>&1
        t1=$(date +%s)
        echo "BARE=$((t1 - t0))"
        # Did the detached job survive the script exiting?
        pgrep -f install-deps.sh >/dev/null 2>&1 \
            && echo "DETACHED=alive" || echo "DETACHED=finished-or-gone"
        # Second pass: python3 is installed now, which is the portal image state.
        pkill -f foundryd.py >/dev/null 2>&1
        rm -rf /home/user/kilnbrook-foundry /var/log/kilnbrook-lab /opt/kilnbrook-svc
        t2=$(date +%s)
        bash /pack/setup/scripts/setup_script.sh >/tmp/setup2.log 2>&1
        t3=$(date +%s)
        echo "TARGET=$((t3 - t2))"
        grep -c "^WARN" /var/log/kilnbrook-lab/setup-status 2>/dev/null \
            | sed "s/^/WARNINGS=/"
        grep -E "^=== |t\+[0-9]+s|total setup time" /tmp/setup2.log | tail -14 \
            | sed "s/^/  | /"
    ' 2>&1)"
    bare="$(printf '%s' "$out" | sed -n 's/^BARE=\([0-9]*\)/\1/p' | head -1)"
    secs="$(printf '%s' "$out" | sed -n 's/^TARGET=\([0-9]*\)/\1/p' | head -1)"
    warns="$(printf '%s' "$out" | sed -n 's/^WARNINGS=\([0-9]*\)/\1/p' | head -1)"
    det="$(printf '%s' "$out" | sed -n 's/^DETACHED=\(.*\)/\1/p' | head -1)"
    echo ""
    echo "run ${run}: BARE ${bare:-?}s, TARGET ${secs:-?}s, ${warns:-?} warning(s), detached job ${det:-?}"
    printf '%s\n' "$out" | grep '^  | ' || true
    [ -n "${secs:-}" ] && [ "$secs" -gt "$WORST" ] && WORST="$secs"
done

echo ""
echo "worst TARGET foreground: ${WORST}s (target ${TARGET}s)"
if [ "$WORST" -le "$TARGET" ]; then
    echo "PASS"
    exit 0
fi
echo "FAIL - the foreground is too slow; look at which phase grew in the timings above."
exit 1
