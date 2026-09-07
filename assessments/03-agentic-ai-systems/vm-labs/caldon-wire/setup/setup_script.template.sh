#!/bin/bash
# Caldon wire desk lab - VM provisioning script.
# Runs once, as root, before the learner starts.
# TEMPLATE: build.sh replaces every FILE marker below with that file's contents.
# No `set -e`: a failing step must be recorded and provisioning must continue,
# so a single hiccup cannot leave the learner with a half-built project or
# root-owned files.
set -uo pipefail

LOG_DIR="/var/log/caldon-lab"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp/caldon-lab"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp"
LOG="${LOG_DIR}/setup.log"
STATUS_FILE="${LOG_DIR}/setup-status"
: > "$STATUS_FILE" 2>/dev/null || true

# Everything from here on is captured in the log and still shown to the portal.
exec > >(tee -a "$LOG") 2>&1

WARNINGS=0
stamp() { date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "-"; }
note()  { echo "[$(stamp)] $*"; }
ok()    { echo "[$(stamp)] OK   $*"; printf 'OK   %s\n'   "$*" >>"$STATUS_FILE" 2>/dev/null || true; }
warn()  { WARNINGS=$((WARNINGS + 1)); echo "[$(stamp)] WARN $*"; printf 'WARN %s\n' "$*" >>"$STATUS_FILE" 2>/dev/null || true; }
run()   { local label="$1"; shift; if "$@"; then ok "$label"; else warn "$label (exit $?)"; fi; return 0; }

# cap <seconds> <cmd...> : never let one command block provisioning
# indefinitely. A freshly booted VM is the worst place to run an unbounded
# command. `apt-get` can sit on the dpkg lock while apt-daily or
# unattended-upgrades holds it, and `systemctl` can block while systemd is
# still initialising. Both fire at boot on a randomised delay, so the collision
# is intermittent - which is exactly what an attempt that fails once and then
# succeeds on a fresh VM looks like. Nothing below may call apt-get or
# systemctl unwrapped.
cap() {
    local secs="$1"; shift
    # Deliberately pure bash rather than coreutils timeout(1): this must behave
    # identically wherever it runs, and a silently absent timeout binary is how
    # a bound becomes a no-op.
    #
    # The command runs in the background and is waited for in one-second steps.
    # Bash dispatches a trap only between commands, so blocking in the
    # foreground would defer the deadline watchdog until the command returned.
    # Stepping keeps the trap responsive.
    "$@" &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -ge "$secs" ]; then
            kill -TERM "$pid" 2>/dev/null
            sleep 2
            kill -KILL "$pid" 2>/dev/null
            break
        fi
    done
    wait "$pid" 2>/dev/null
    return $?
}

# detach <logfile> <cmd...> : run something that must outlive this script.
# setsid is the right tool and is present on the target image, but a missing
# setsid would make this a silent no-op - and a background job that never
# starts costs the whole health-wait budget before anything notices. Fall back
# to plain nohup.
detach() {
    local logfile="$1"; shift
    if command -v setsid >/dev/null 2>&1; then
        setsid nohup "$@" >"$logfile" 2>&1 </dev/null &
    else
        nohup "$@" >"$logfile" 2>&1 </dev/null &
    fi
    disown 2>/dev/null || true
    return 0
}

LAB_USER="user"
LAB_HOME="/home/${LAB_USER}"
PROJ="${LAB_HOME}/caldon-wire"
DATA_DIR="${PROJ}/data"
FEED_FILE="${DATA_DIR}/wire_feed.json"
SVC="/opt/caldon-svc"
PORT=8794

# A stdlib HTTP server binds in well under a second, so 10s is already
# generous. curl is installed by the detached job rather than by the
# foreground, so the probe here is python3 - which provisioning already depends
# on anyway.
svc_healthy() {
    python3 - "$PORT" <<'PROBE' >/dev/null 2>&1
import sys, urllib.request
urllib.request.urlopen("http://127.0.0.1:%s/health" % sys.argv[1], timeout=2).read()
PROBE
}

note "Caldon wire desk setup starting; full log at ${LOG}"

# Hard internal deadline. Every individual step is capped above, so this is a
# backstop against them accumulating. On expiry the script prints its summary
# and exits 0 rather than being killed: the portal then shows a provisioned lab
# with a warning instead of a blocking-process error, and the learner gets a
# usable VM. This is the difference between degrading and disappearing - the
# project files, the feed and the wire desk are all in place by then, and the
# dependency install finishes on its own afterwards.
SETUP_BUDGET="${SETUP_BUDGET:-95}"
DEADLINE_HIT=0
on_deadline() {
    DEADLINE_HIT=1
    warn "setup hit its internal ${SETUP_BUDGET}s deadline at t+${SECONDS}s and is finishing early so provisioning reports a result instead of being killed"
    if type finish_summary >/dev/null 2>&1; then finish_summary; fi
    exit 0
}
trap on_deadline USR1
( sleep "$SETUP_BUDGET"; kill -USR1 $$ 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG_PID=$!

# The portal's own front end gives up if it cannot read the lab status within
# its polling window, and that window is much tighter than the setup time
# limit. Three things keep provisioning inside it, in order of how much they
# matter:
#   1. every external command that can block is wrapped in `cap` (above);
#   2. the `openai` install is detached entirely in phase 2, because nothing at
#      provisioning time needs it - wired.py is pure standard library and the
#      project is just files, so the learner gets a working lab while the wheel
#      lands behind them;
#   3. a hard internal deadline that finishes early with a summary rather than
#      being killed.
# Every phase prints t+${SECONDS}s so a real VM run shows where the time went,
# and that output is what the portal captures - the only diagnosis that
# survives a wiped VM.

echo "=== [1/8] Base packages ==="
export DEBIAN_FRONTEND=noninteractive
if ! id -u "$LAB_USER" >/dev/null 2>&1; then
    cap 20 useradd -m -s /bin/bash "$LAB_USER" || true
fi
# Only python3 is needed to hand over a usable lab: it runs the wire desk and
# the learner code. pip, curl and jq are all consumers that come later - the
# checks use curl and jq, and the dependency install needs pip - so they are
# installed by the detached job instead of on the path the portal is waiting
# on. The health check below uses python3 rather than curl for the same reason.
if ! command -v python3 >/dev/null 2>&1; then
    note "installing python3 (the only package provisioning itself needs)"
    # Take the lock contenders out of the way first. apt-daily and
    # unattended-upgrades start on a randomised delay after boot, so on some
    # attempts they hold the dpkg lock exactly when this runs and on others
    # they do not - that intermittency is the whole signature of a lab that
    # fails once and then works.
    for u in apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service apt-daily.service; do
        cap 5 systemctl stop "$u" >/dev/null 2>&1 || true
        cap 5 systemctl disable "$u" >/dev/null 2>&1 || true
    done
    APT_OPTS="-o DPkg::Lock::Timeout=30"
    apt_ok=0
    for attempt in 1 2; do
        # shellcheck disable=SC2086
        if cap 60 apt-get install -y -qq $APT_OPTS python3; then apt_ok=1; break; fi
        # shellcheck disable=SC2086
        cap 45 apt-get update -qq $APT_OPTS || note "apt-get update attempt ${attempt} failed (t+${SECONDS}s)"
        # shellcheck disable=SC2086
        if cap 60 apt-get install -y -qq $APT_OPTS python3; then apt_ok=1; break; fi
        note "python3 install attempt ${attempt} failed (t+${SECONDS}s)"
        [ "$attempt" -eq 1 ] && sleep 5
    done
    [ "$apt_ok" -eq 1 ] || warn "could not install python3 (t+${SECONDS}s) - the lab will not work"
fi
command -v python3 >/dev/null 2>&1 && ok "have python3" || warn "missing python3"
# Resolved once and used everywhere below, including in the unit file. A
# hardcoded /usr/bin/python3 is right on this image and wrong on the next one,
# and the failure it produces is a service that never starts rather than an
# error anybody reads.
PYBIN="$(command -v python3 || echo /usr/bin/python3)"

# Learners type `python`, not only `python3`. A symlink rather than a shell
# alias: an alias dies inside scripts and under sudo.
if command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
    ln -sf "$(command -v python3)" /usr/local/bin/python 2>/dev/null \
        && ok "python -> python3" || warn "could not link python"
fi

# The image marks its interpreter externally managed, so a plain `pip install`
# refuses under PEP 668. Written before anything runs pip, including the
# learner.
if [ ! -f /etc/pip.conf ]; then
    printf '[global]\nbreak-system-packages = true\ndisable-pip-version-check = true\n' \
        > /etc/pip.conf 2>/dev/null && ok "wrote /etc/pip.conf" || warn "could not write /etc/pip.conf"
fi

# `sudo` needs a password on this image, so a learner installing anything
# themselves lands in ~/.local, which root cannot import from. Bridge it with a
# .pth in the admin site directory, or their code runs while every check
# reports a missing module.
PYVER="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo "")"
if [ -n "$PYVER" ]; then
    for SITEDIR in "/usr/local/lib/python${PYVER}/dist-packages" "/usr/lib/python3/dist-packages"; do
        if [ -d "$SITEDIR" ]; then
            echo "${LAB_HOME}/.local/lib/python${PYVER}/site-packages" \
                > "${SITEDIR}/caldon-user-site.pth" 2>/dev/null && break
        fi
    done
fi
note "base packages done (t+${SECONDS}s)"

echo "=== [2/8] Runtime dependency (detached; the foreground never waits) ==="
PIPLOG="${LOG_DIR}/pip.log"
DEPS_STATE="${LOG_DIR}/deps.state"
DEPS_READY="${LOG_DIR}/deps.ready"
DEPS_JOB="${LOG_DIR}/install-deps.sh"
rm -f "$DEPS_STATE" "$DEPS_READY"

# Everything the lab needs but provisioning does not: pip, the checks' curl and
# jq, and the openai wheel. None of it is required to hand the learner a
# working project, a feed and a running wire desk, and all of it is slow and
# network-bound. Keeping it here is what lets the foreground finish in seconds,
# which is what the portal is waiting on.
{
    echo '#!/bin/bash'
    echo '# GENERATED by the setup script - installs what the lab needs after'
    echo '# provisioning has already returned, then publishes a readiness file.'
    echo "DEPS_STATE=\"${DEPS_STATE}\""
    echo "DEPS_READY=\"${DEPS_READY}\""
    echo "PROJ=\"${PROJ}\""
    echo "PORT=\"${PORT}\""
    cat <<'DEPSJOB'
# PYTHONDONTWRITEBYTECODE keeps this from dropping root-owned __pycache__ into
# the learner's project after phase 8 has already handed it over.
export PYTHONDONTWRITEBYTECODE=1
export DEBIAN_FRONTEND=noninteractive
APT_OPTS="-o DPkg::Lock::Timeout=60"

# pip for the wheel below; curl and jq because the check scripts use them.
for attempt in 1 2; do
    # shellcheck disable=SC2086
    apt-get install -y -qq --no-install-recommends $APT_OPTS python3-pip curl jq && break
    # shellcheck disable=SC2086
    apt-get update -qq $APT_OPTS
    # shellcheck disable=SC2086
    apt-get install -y -qq --no-install-recommends $APT_OPTS python3-pip curl jq && break
    sleep 5
done

PIPFLAGS="--quiet --disable-pip-version-check --only-binary=:all:"
if python3 -m pip install --help 2>/dev/null | grep -q break-system-packages; then
    PIPFLAGS="$PIPFLAGS --break-system-packages"
fi

# The major version is load-bearing and the ladder never falls past it.
# openai 3.x moved onto a transport whose response stream is still suspended
# when the event loop shuts down, so every streamed reply is followed by a
# multi-line asyncgen traceback on stderr. Nothing fails, but a learner reading
# that output cannot tell it from a real error in their own code. 2.x streams
# clean. --only-binary makes a wheel-less resolution fail in seconds with a
# readable error rather than starting a source build on an image with no
# compiler.
# shellcheck disable=SC2086
if python3 -m pip install $PIPFLAGS "openai==2.54.0"; then
    echo pinned > "$DEPS_STATE"
# shellcheck disable=SC2086
elif python3 -m pip install $PIPFLAGS "openai<3"; then
    echo series > "$DEPS_STATE"
else
    echo failed > "$DEPS_STATE"
fi

# Pay the import and first-request cost so the first graded run is not a cold
# start.
cd "$PROJ" 2>/dev/null && python3 - <<'WARM'
import asyncio
import sys

sys.path.insert(0, ".")
try:
    from wire_kit import (MODEL, SUMMARY_SYSTEM, make_async_client,
                          story_ids, story_prompt)

    async def warm():
        async with make_async_client() as client:
            await client.chat.completions.create(
                model=MODEL,
                messages=[{"role": "system", "content": SUMMARY_SYSTEM},
                          {"role": "user",
                           "content": story_prompt(story_ids()[0])}])

    asyncio.run(warm())
    print("warm-up complete")
except Exception as exc:
    print("warm-up skipped: %s: %s" % (type(exc).__name__, exc))

WARM

# Written last, and only after the install has resolved, so its presence means
# the state file is final and curl, jq and pip are all present.
touch "$DEPS_READY"
DEPSJOB
} > "$DEPS_JOB"
chmod +x "$DEPS_JOB"
detach "$PIPLOG" "$DEPS_JOB"
note "runtime dependency install detached (job ${DEPS_JOB}, log ${PIPLOG})"

echo "=== [3/8] Project skeleton ==="
mkdir -p "${PROJ}/wire_kit" "$DATA_DIR"

cat > "${PROJ}/wire_kit/__init__.py" <<'___CWFILE___'
@@FILE:app/wire_kit/__init__.py@@
___CWFILE___

cat > "${PROJ}/wire_kit/client.py" <<'___CWFILE___'
@@FILE:app/wire_kit/client.py@@
___CWFILE___

cat > "${PROJ}/wire_kit/feed.py" <<'___CWFILE___'
@@FILE:app/wire_kit/feed.py@@
___CWFILE___

cat > "${PROJ}/wire_kit/prompts.py" <<'___CWFILE___'
@@FILE:app/wire_kit/prompts.py@@
___CWFILE___

cat > "${PROJ}/check_local.py" <<'___CWFILE___'
@@FILE:app/check_local.py@@
___CWFILE___

cat > "${FEED_FILE}" <<'___CWFILE___'
@@FILE:app/data/wire_feed.json@@
___CWFILE___

cat > "/tmp/.caldon_stub.py" <<'___CWFILE___'
@@FILE:app/solution_stub.py@@
___CWFILE___

# Never clobber work in progress: the stub is only installed on a fresh
# project.
if [ ! -f "${PROJ}/solution.py" ]; then
    cp /tmp/.caldon_stub.py "${PROJ}/solution.py"
    echo "installed solution.py stub"
else
    echo "solution.py already exists - left untouched"
fi
rm -f /tmp/.caldon_stub.py

# Hand the project to the learner immediately, before any step that could fail
# and leave these files root-owned (and therefore read-only for them).
run "early chown of ${PROJ}" chown -R "${LAB_USER}:${LAB_USER}" "$PROJ"
chmod -R u+rw "$PROJ" 2>/dev/null || warn "early chmod failed"
find "$PROJ" -type d -exec chmod u+x {} + 2>/dev/null || true
[ -s "${PROJ}/solution.py" ] && ok "solution.py in place" || warn "solution.py missing or empty"
[ -s "${FEED_FILE}" ] && ok "wire feed in place" || warn "wire feed missing or empty"
note "project skeleton done (t+${SECONDS}s)"

echo "=== [4/8] Wire desk files ==="
mkdir -p "$SVC"

cat > "${SVC}/wired.py" <<'___CWFILE___'
@@FILE:service/wired.py@@
___CWFILE___

# The desk reads its own copy rather than the one in the project, so nothing
# the learner does to their files can change what the desk returns.
cat > "${SVC}/wire_feed.json" <<'___CWFILE___'
@@FILE:app/data/wire_feed.json@@
___CWFILE___

chown -R root:root "$SVC"
chmod 700 "$SVC"
chmod 600 "${SVC}/wire_feed.json"
chmod 700 "${SVC}/wired.py"
note "wire desk files written (t+${SECONDS}s)"

echo "=== [5/8] Learner state ==="
# Grading runs as root, and a check that writes anywhere under the project
# would leave a root-owned file the learner cannot replace. Nothing under the
# project is created by a check, but the directory and its contents are chowned
# here anyway so the first toucher afterwards writes into something the learner
# already owns.
run "chown data directory to ${LAB_USER}" chown -R "${LAB_USER}:${LAB_USER}" "$DATA_DIR"
chmod 755 "$DATA_DIR" 2>/dev/null || true
chmod 644 "$FEED_FILE" 2>/dev/null || true

echo "=== [6/8] Starting the wire desk ==="
start_with_systemd() {
    command -v systemctl >/dev/null 2>&1 || return 1
    cat > /etc/systemd/system/caldon-wired.service <<UNIT
[Unit]
Description=Caldon wire desk model endpoint
After=network.target

[Service]
Type=simple
Environment=CALDON_PORT=${PORT}
Environment=CALDON_FEED=${SVC}/wire_feed.json
ExecStart=${PYBIN} ${SVC}/wired.py
Restart=always
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
UNIT
    cap 15 systemctl daemon-reload >/dev/null 2>&1 || return 1
    cap 25 systemctl enable --now caldon-wired >/dev/null 2>&1 || return 1
    return 0
}

start_with_nohup() {
    # If a unit was created and is flapping, stop it first: Restart=always plus
    # a second copy of the desk means two processes fighting for the same port.
    if command -v systemctl >/dev/null 2>&1; then
        cap 15 systemctl disable --now caldon-wired >/dev/null 2>&1 || true
    fi
    export CALDON_PORT="$PORT" CALDON_FEED="${SVC}/wire_feed.json"
    detach /var/log/caldon-wired.log "$PYBIN" "${SVC}/wired.py"
}

wait_health() {
    local i
    for i in $(seq 1 20); do
        svc_healthy && return 0
        sleep 0.5
    done
    return 1
}

if svc_healthy; then
    ok "wire desk already running on ${PORT}"
elif start_with_systemd && wait_health; then
    ok "wire desk started under systemd"
else
    # Only ever spend the health-wait budget on something that was actually
    # started. The obvious ordering - start, ignore the result, then wait -
    # burns the whole wait against a server that never launched on any image
    # where systemctl is missing, and only then tries the fallback that does
    # launch it.
    echo "systemd path unavailable, falling back to a background process"
    start_with_nohup
    wait_health || warn "the wire desk did not come up during setup; the check scripts start it on demand, so grading still works (see ${LOG})"
fi
if svc_healthy; then
    ok "wire desk healthy on 127.0.0.1:${PORT}"
else
    warn "wire desk not answering on 127.0.0.1:${PORT} at end of setup"
fi
note "wire desk up (t+${SECONDS}s)"

echo "=== [7/8] Dependency hand-off ==="
# A short, bounded grace period. On a warm or fast machine the detached job has
# already finished by now, so setup still exits with everything in place. What
# this must never do is wait for the slow case: that is what puts the total
# over the limit.
DEPS_GRACE="${DEPS_GRACE:-5}"
for _i in $(seq 1 "$DEPS_GRACE"); do
    [ -f "$DEPS_READY" ] && break
    sleep 1
done
case "$(cat "$DEPS_STATE" 2>/dev/null)" in
    pinned) ok "installed pinned openai" ;;
    series) warn "the pinned openai version was unavailable; installed the newest 2.x instead" ;;
    failed) warn "pip install of openai FAILED - the lab cannot run until this is fixed (see ${PIPLOG})" ;;
    *)      note "the dependency is still downloading in the background (log ${PIPLOG}); the project, the feed and the wire desk are ready now. ${DEPS_READY} appears when the install finishes, and check_local.py and the checks both wait for it." ;;
esac
tail -n 5 "$PIPLOG" 2>/dev/null | sed 's/^/    pip| /'
if [ -f "$DEPS_READY" ]; then
    grep -q 'warm-up complete' "$PIPLOG" 2>/dev/null && ok "warm-up complete" || true
fi
note "dependency handed off (t+${SECONDS}s)"

finish_summary() {
    # Emitted on the normal path and on the deadline path alike, so the
    # portal's own captured output always ends with a verdict. That output is
    # the only diagnosis that survives a VM the portal wipes after a failed
    # attempt.
    [ "${SUMMARY_DONE:-0}" -eq 1 ] && return 0
    SUMMARY_DONE=1
    # Lead with an honest verdict. The block below is fixed text that says the
    # lab is ready, and on the deadline path it can be reached with apt having
    # failed and python3 missing - in which case nothing works and saying
    # "ready" would be actively misleading.
    local blockers=""
    command -v python3 >/dev/null 2>&1 || blockers="${blockers} python3-missing"
    [ -s "${PROJ}/solution.py" ] || blockers="${blockers} project-missing"
    [ -s "$FEED_FILE" ] || blockers="${blockers} feed-missing"
    svc_healthy || blockers="${blockers} wire-desk-down"
    if [ -n "$blockers" ]; then
        warn "LAB NOT READY -${blockers}"
        note "provisioning could not finish the essentials. Re-running setup on a fresh VM is"
        note "the fastest remedy; the phase timings above show which step ran out of time."
        note "total setup time: ${SECONDS}s"
        return 0
    fi
cat <<SUMMARY

--------------------------------------------------------------------
Caldon wire desk lab is ready.

Project:   ${PROJ}
Provided:  wire_kit/        (the configured async client, the feed reader and
                             the system prompts each desk expects
                             - do not modify)
           data/wire_feed.json  (the stories on the wire)
           check_local.py   (runs your five functions and prints what they
                             return)
You write: solution.py

The wire desk is answering on http://127.0.0.1:${PORT} and is what the provided
client talks to. Leave it running.

Verify your work with:
    cd ${PROJ} && python3 check_local.py

Setup log:    ${LOG}
Setup status: ${STATUS_FILE}
--------------------------------------------------------------------
SUMMARY

if [ "$WARNINGS" -gt 0 ]; then
    note "setup finished with ${WARNINGS} warning(s):"
    grep '^WARN' "$STATUS_FILE" 2>/dev/null | sed 's/^/    /'
else
    note "setup finished with no warnings"
fi
# The portal kills provisioning that runs much beyond two minutes, and its
# status poll gives up sooner than that, so the total is recorded on every run:
# if this creeps up, the apt install is the thing to look at.
note "total setup time: ${SECONDS}s"
    if [ "$DEADLINE_HIT" -eq 1 ]; then
        note "finished early on the internal deadline; the project, the feed and the wire desk are in place and the dependency install continues in the background"
    fi
}

echo "=== [8/8] Permissions & summary ==="
run "chown project to ${LAB_USER}" chown -R "${LAB_USER}:${LAB_USER}" "$PROJ"
run "make project writable" chmod -R u+rw "$PROJ"
find "$PROJ" -type d -exec chmod u+x {} + 2>/dev/null || warn "could not set directory execute bits"
rm -rf "${PROJ}/__pycache__" "${PROJ}/wire_kit/__pycache__" 2>/dev/null || true
[ -w "${PROJ}/solution.py" ] || warn "solution.py is not writable - the learner will hit a read-only file"

finish_summary

# Give the tee subshell a moment to flush, then always report success: a
# warning must not fail provisioning, and the log holds everything needed to
# diagnose it.
kill "$WATCHDOG_PID" >/dev/null 2>&1 || true
sync 2>/dev/null || true
exit 0
