#!/bin/bash
# Measure the FOREGROUND wall clock of the generated setup script.
#
# The portal's front end gives up while polling for lab status if provisioning takes
# too long, and that window is much tighter than the setup time limit, so this number
# is the one that decides whether the lab loads on a first attempt. Two modes:
#
#   ./setup-timing.sh              sandboxed on this host - runs the real generated
#                                  script with its paths and port rewritten into a
#                                  temp directory, as the current user. Measures
#                                  everything except the apt block (which the target
#                                  image skips anyway, since it ships python3).
#
#   IMAGE=jrei/systemd-ubuntu ./setup-timing.sh --image
#                                  the honest measurement: the unmodified script on
#                                  the real base image, as root, under Docker.
#
# Fails if the foreground exceeds TARGET seconds (default 20).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET="${TARGET:-20}"
IMAGE="${IMAGE:-jrei/systemd-ubuntu}"
SCRIPT="$DIR/setup/scripts/setup_script.sh"

[ -f "$SCRIPT" ] || { echo "run ./build.sh first"; exit 1; }

if [ "${1:-}" = "--image" ]; then
    command -v docker >/dev/null 2>&1 || { echo "docker is not available"; exit 1; }
    echo "=== running the unmodified setup script on ${IMAGE} ==="
    docker run --rm -v "$DIR:/pack:ro" "$IMAGE" bash -c '
        t0=$SECONDS
        bash /pack/setup/scripts/setup_script.sh >/tmp/out.log 2>&1
        echo "FOREGROUND $((SECONDS - t0))s"
        grep -E "^\[.*(total setup time|LAB NOT READY)" /tmp/out.log | tail -3
        grep "^WARN" /var/log/ashford-lab/setup-status 2>/dev/null | sed "s/^/  /"
    '
    exit $?
fi

SANDBOX="$(mktemp -d)"
[ -n "${KEEP_SANDBOX:-}" ] || trap 'rm -rf "$SANDBOX"' EXIT
PORT="${PORT:-9800}"

echo "=== sandboxed timing run in ${SANDBOX} (port ${PORT}) ==="
sed -e "s|/var/log/ashford-lab|${SANDBOX}/log|g" \
    -e "s|^LAB_HOME=.*|LAB_HOME=\"${SANDBOX}/home\"|" \
    -e "s|/home/user|${SANDBOX}/home|g" \
    -e "s|/usr/bin/python3|$(command -v python3)|g" \
    -e "s|/opt/ashford-svc|${SANDBOX}/svc|g" \
    -e "s|^PORT=8836|PORT=${PORT}|" \
    -e "s|/etc/systemd/system/ashford-gridd.service|${SANDBOX}/unit|g" \
    -e "s|/etc/pip.conf|${SANDBOX}/pip.conf|g" \
    -e 's|^LAB_USER="user"|LAB_USER="'"$(id -un)"'"|' \
    -e "s|chown -R root:root|true chown|" \
    -e "s|/var/log/ashford-gridd.log|${SANDBOX}/gridd.log|g" \
    "$SCRIPT" > "$SANDBOX/setup.sh"
# The systemd path is unavailable in the sandbox, so the nohup fallback is what runs -
# which is also what happens on any image where `systemctl enable --now` fails.
bash -n "$SANDBOX/setup.sh" || { echo "the rewritten script does not parse"; exit 1; }

mkdir -p "$SANDBOX/home"
T0=$SECONDS
bash "$SANDBOX/setup.sh" >"$SANDBOX/run.log" 2>&1
ELAPSED=$((SECONDS - T0))

grep -E '^\[' "$SANDBOX/run.log" | tail -25
echo
echo "  phases:"
grep -E 'done \(t\+|ready \(t\+|up \(t\+|handed off \(t\+' "$SANDBOX/run.log" | sed 's/^/    /'
echo
echo "  FOREGROUND WALL CLOCK: ${ELAPSED}s   (target <= ${TARGET}s)"
echo "  note: the apt block is skipped here because this host already has python3 -"
echo "        which is also true of the target image, so this is representative."
pkill -f "$SANDBOX/svc/gridd.py" >/dev/null 2>&1 || true
[ "$ELAPSED" -le "$TARGET" ] || { echo "  OVER TARGET"; exit 1; }
echo "  within target"
