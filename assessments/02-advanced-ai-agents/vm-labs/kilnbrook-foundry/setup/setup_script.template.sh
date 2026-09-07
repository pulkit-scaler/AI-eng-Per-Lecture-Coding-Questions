#!/bin/bash
# Kilnbrook Foundry lab - VM provisioning script.
# Runs once, as root, before the learner starts.
# TEMPLATE: build.sh replaces every FILE marker below with that file's contents.
# No `set -e`: a failing step must be recorded and provisioning must continue, so a
# single hiccup cannot leave the learner with a half-built project or root-owned files.
set -uo pipefail

LOG_DIR="/var/log/kilnbrook-lab"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp/kilnbrook-lab"
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
# run <label> <cmd...> : log it, never let a failure stop provisioning
run()   { local label="$1"; shift; if "$@"; then ok "$label"; else warn "$label (exit $?)"; fi; return 0; }

# cap <seconds> <cmd...> : never let one command block provisioning indefinitely.
# A freshly booted VM is the worst place to run an unbounded command. `apt-get` can sit on
# the dpkg lock while apt-daily/unattended-upgrades holds it, and `systemctl` can block
# while systemd is still initialising. Both fire at boot on a randomised delay, so the
# collision is intermittent - which is exactly what an attempt that fails once and then
# succeeds on a fresh VM looks like. Nothing below may call apt-get or systemctl unwrapped.
cap() {
    local secs="$1"; shift
    # Deliberately pure bash rather than coreutils timeout(1): this must behave identically
    # wherever it runs, and a silently absent timeout binary is how a bound becomes a no-op.
    #
    # The command runs in the background and is waited for in one-second steps. Bash
    # dispatches a trap only between commands, so blocking in the foreground would defer the
    # deadline watchdog until the command returned. Stepping keeps the trap responsive.
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

note "Kilnbrook Foundry setup starting; full log at ${LOG}"

# Hard internal deadline. Every individual step is capped above, so this is a backstop
# against them accumulating. On expiry the script prints its summary and exits 0 rather
# than being killed: the portal then shows a provisioned lab with a warning instead of a
# blocking-process error, and the learner gets a usable VM. This is the difference between
# degrading and disappearing - the project files, the database and the endpoint are all in
# place by then, and the dependency install finishes on its own afterwards.
SETUP_BUDGET="${SETUP_BUDGET:-95}"
DEADLINE_HIT=0
on_deadline() {
    DEADLINE_HIT=1
    warn "setup hit its internal ${SETUP_BUDGET}s deadline at t+${SECONDS}s and is finishing early so provisioning reports a result instead of being killed"
    finish_summary
    exit 0
}
trap on_deadline USR1
( sleep "$SETUP_BUDGET"; kill -USR1 $$ 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG_PID=$!

# The portal front end gives up if it cannot read the lab status within its polling
# window, so the foreground here is stripped to the shortest path that yields a usable
# lab. Three things keep provisioning from disappearing, in order of how much they matter:
#   1. every external command that can block is wrapped in `cap` (above);
#   2. pip, curl, jq and the openai wheel are all installed by a detached job, because
#      nothing at provisioning time needs them - foundryd.py and the database builder are
#      pure standard library, and the project is just files;
#   3. a hard internal deadline that finishes early with a summary rather than being killed.
# Every phase prints t+${SECONDS}s so a real VM run shows where the time went, and that
# output is what the portal captures - the only diagnosis that survives a wiped VM.

LAB_USER="user"
LAB_HOME="/home/${LAB_USER}"
PROJ="${LAB_HOME}/kilnbrook-foundry"
SVC="/opt/kilnbrook-svc"
PORT=8781
DB_FILE="${PROJ}/data/foundry.db"
PIN="openai==3.1.0"

echo "=== [1/7] Base packages ==="
export DEBIAN_FRONTEND=noninteractive
if ! id -u "$LAB_USER" >/dev/null 2>&1; then
    cap 20 useradd -m -s /bin/bash "$LAB_USER" || true
fi
# Only python3 is needed to hand over a usable lab: it runs the endpoint, builds the
# database and runs the learner code. pip, curl and jq are consumers that come later.
if ! command -v python3 >/dev/null 2>&1; then
    note "installing python3 (the only package provisioning itself needs)"
    # Take the lock contenders out of the way first. apt-daily and unattended-upgrades
    # start on a randomised delay after boot, so on some attempts they hold the dpkg lock
    # exactly when this runs and on others they do not - that intermittency is the whole
    # signature of a lab that fails once and then works.
    for u in apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service apt-daily.service; do
        cap 5 systemctl stop "$u" >/dev/null 2>&1 || true
        cap 5 systemctl disable "$u" >/dev/null 2>&1 || true
    done
    APT_OPTS="-o DPkg::Lock::Timeout=30"
    apt_ok=0
    for attempt in 1 2; do
        # Try the install before paying for an index refresh: when the image ships a usable
        # package index this skips apt-get update entirely, and when it does not the install
        # fails in about a second and the update below runs anyway.
        # shellcheck disable=SC2086
        if cap 60 apt-get install -y -qq $APT_OPTS python3; then apt_ok=1; break; fi
        # shellcheck disable=SC2086
        cap 45 apt-get update -qq $APT_OPTS || note "apt-get update attempt ${attempt} failed (t+${SECONDS}s)"
        # shellcheck disable=SC2086
        if cap 60 apt-get install -y -qq $APT_OPTS python3; then apt_ok=1; break; fi
        note "python3 install attempt ${attempt} failed (t+${SECONDS}s)"
        # A freshly created VM may not have its network up yet when provisioning starts, so
        # one retry covers a failure that is gone seconds later.
        [ "$attempt" -eq 1 ] && sleep 5
    done
    [ "$apt_ok" -eq 1 ] || warn "could not install python3 (t+${SECONDS}s) - the lab will not work"
fi
if command -v python3 >/dev/null 2>&1; then
    ok "have python3 ($(python3 -V 2>&1))"
    python3 -c 'import sqlite3' >/dev/null 2>&1 \
        && ok "python3 sqlite3 module present" \
        || warn "python3 has no sqlite3 module - the database tools cannot work"
else
    warn "missing python3"
fi
# Learners type `python`, and a symlink survives scripts and sudo where an alias does not.
if command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
    ln -sf "$(command -v python3)" /usr/local/bin/python 2>/dev/null || true
fi
# This image is externally managed (PEP 668), so a learner pip install refuses without it.
mkdir -p /etc 2>/dev/null || true
if [ ! -f /etc/pip.conf ]; then
    printf '[global]\nbreak-system-packages = true\ndisable-pip-version-check = true\n' \
        > /etc/pip.conf 2>/dev/null || warn "could not write /etc/pip.conf"
fi
note "base packages done (t+${SECONDS}s)"

echo "=== [2/7] Runtime dependencies (detached; the foreground never waits for them) ==="
PIPLOG="${LOG_DIR}/pip.log"
DEPS_STATE="${LOG_DIR}/deps.state"
DEPS_READY="${LOG_DIR}/deps.ready"
DEPS_JOB="${LOG_DIR}/install-deps.sh"
rm -f "$DEPS_STATE" "$DEPS_READY"

# Everything the lab needs but provisioning does not: pip, curl and jq for the check
# scripts, and the openai wheel for the learner code. None of it is required to hand over
# a working project, a built database and a running endpoint, and all of it is slow and
# network-bound. Keeping it here is what lets the foreground finish in seconds, which is
# what the portal is actually waiting on.
{
    echo '#!/bin/bash'
    echo '# GENERATED by the setup script - installs what the lab needs after provisioning'
    echo '# has already returned, then publishes a readiness marker.'
    echo "DEPS_STATE=\"${DEPS_STATE}\""
    echo "DEPS_READY=\"${DEPS_READY}\""
    echo "PROJ=\"${PROJ}\""
    echo "PORT=\"${PORT}\""
    echo "PIN=\"${PIN}\""
    cat <<'DEPSJOB'
# PYTHONDONTWRITEBYTECODE keeps this from dropping root-owned __pycache__ into the
# learner project after phase 7 has already handed it over.
export PYTHONDONTWRITEBYTECODE=1
export DEBIAN_FRONTEND=noninteractive
APT_OPTS="-o DPkg::Lock::Timeout=60"

# --no-install-recommends is load-bearing, not tidiness: python3-pip recommends
# build-essential and python3-dev, which is a large download this lab never needs.
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

# Pinned first, then unpinned. --only-binary means a wheel-less resolution fails in
# seconds with a readable error rather than starting a source build that would be killed
# for running out of memory mid-provision.
# shellcheck disable=SC2086
if python3 -m pip install $PIPFLAGS "$PIN"; then
    echo pinned > "$DEPS_STATE"
# shellcheck disable=SC2086
elif python3 -m pip install $PIPFLAGS openai; then
    echo latest > "$DEPS_STATE"
else
    echo failed > "$DEPS_STATE"
fi

# A learner install without sudo lands in ~/.local, which root cannot import from, so
# bridge it into the admin site directory. Without this a learner whose code works can
# still score zero.
PYVER="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)"
for site in "/usr/local/lib/python${PYVER}/dist-packages" \
            "/usr/lib/python3/dist-packages"; do
    if [ -d "$site" ]; then
        echo "/home/user/.local/lib/python${PYVER}/site-packages" \
            > "${site}/kilnbrook-user-site.pth" 2>/dev/null && break
    fi
done

# Pay the import and first-request cost so the first graded check is not a cold start.
cd "$PROJ" 2>/dev/null && KILN_SESSION=warm-up python3 - <<'WARM'
import os
import sys

sys.path.insert(0, ".")
try:
    from kiln_kit import MODEL_NAME, PERSONA, connect, make_client

    with connect() as conn:
        conn.execute("SELECT COUNT(*) FROM pours").fetchone()
    client = make_client()
    client.chat.completions.create(
        model=MODEL_NAME,
        messages=[{"role": "system", "content": PERSONA["role"]},
                  {"role": "user", "content": "warm up"}],
    )
    print("warm-up complete")
except Exception as exc:
    print("warm-up skipped: %s: %s" % (type(exc).__name__, exc))
WARM

# Written last, and only after the install has resolved, so its presence means the state
# file is final and curl, jq and pip are all present.
touch "$DEPS_READY"
DEPSJOB
} > "$DEPS_JOB"
chmod +x "$DEPS_JOB"
setsid nohup "$DEPS_JOB" >"$PIPLOG" 2>&1 </dev/null &
note "runtime dependency install detached (job ${DEPS_JOB}, log ${PIPLOG})"

echo "=== [3/7] Project skeleton and database ==="
mkdir -p "${PROJ}/kiln_kit" "${PROJ}/data"

cat > "${PROJ}/kiln_kit/__init__.py" <<'___KBFILE___'
@@FILE:app/kiln_kit/__init__.py@@
___KBFILE___

cat > "${PROJ}/kiln_kit/client.py" <<'___KBFILE___'
@@FILE:app/kiln_kit/client.py@@
___KBFILE___

cat > "${PROJ}/kiln_kit/db.py" <<'___KBFILE___'
@@FILE:app/kiln_kit/db.py@@
___KBFILE___

cat > "${PROJ}/kiln_kit/persona.py" <<'___KBFILE___'
@@FILE:app/kiln_kit/persona.py@@
___KBFILE___

cat > "${PROJ}/check_local.py" <<'___KBFILE___'
@@FILE:app/check_local.py@@
___KBFILE___

cat > "/tmp/.kilnbrook_stub.py" <<'___KBFILE___'
@@FILE:app/solution_stub.py@@
___KBFILE___

# The builder is an instructor file: it runs from /tmp and is removed straight after, so
# it never appears under the learner project.
cat > "/tmp/.kilnbrook_make_db.py" <<'___KBFILE___'
@@FILE:service/make_db.py@@
___KBFILE___

# Never clobber work in progress: the starter is only installed on a fresh project.
if [ ! -f "${PROJ}/solution.py" ]; then
    cp /tmp/.kilnbrook_stub.py "${PROJ}/solution.py"
    echo "installed solution.py starter"
else
    echo "solution.py already exists - left untouched"
fi
rm -f /tmp/.kilnbrook_stub.py

# Build the database only when it is absent, so re-running setup cannot discard a lab the
# learner is part-way through.
if [ ! -s "$DB_FILE" ]; then
    run "build foundry database" python3 /tmp/.kilnbrook_make_db.py "$DB_FILE"
else
    ok "foundry database already present"
fi
rm -f /tmp/.kilnbrook_make_db.py
[ -s "$DB_FILE" ] && ok "database at ${DB_FILE}" || warn "database missing at ${DB_FILE}"

# Hand the project to the learner immediately, before any step that could fail and leave
# these files root-owned - and therefore read-only for them. The data directory matters as
# much as the file inside it: owning the parent is what lets the learner replace the
# database if they damage it.
run "early chown of ${PROJ}" chown -R "${LAB_USER}:${LAB_USER}" "$PROJ"
chmod -R u+rw "$PROJ" 2>/dev/null || warn "early chmod failed"
find "$PROJ" -type d -exec chmod u+x {} + 2>/dev/null || true
[ -s "${PROJ}/solution.py" ] && ok "solution.py in place" || warn "solution.py missing or empty"

echo "=== [4/7] Model endpoint ==="
mkdir -p "$SVC"

cat > "${SVC}/foundryd.py" <<'___KBFILE___'
@@FILE:service/foundryd.py@@
___KBFILE___

chown -R root:root "$SVC"
chmod 700 "$SVC"
chmod 700 "${SVC}/foundryd.py"

echo "=== [5/7] Starting the endpoint ==="
start_with_systemd() {
    command -v systemctl >/dev/null 2>&1 || return 1
    cat > /etc/systemd/system/kilnbrook-foundryd.service <<UNIT
[Unit]
Description=Kilnbrook Foundry model endpoint
After=network.target

[Service]
Type=simple
Environment=KILN_DB=${DB_FILE}
Environment=KILN_PORT=${PORT}
ExecStart=/usr/bin/python3 ${SVC}/foundryd.py
Restart=always
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
UNIT
    cap 15 systemctl daemon-reload >/dev/null 2>&1 || return 1
    cap 25 systemctl enable --now kilnbrook-foundryd >/dev/null 2>&1 || return 1
    return 0
}

start_with_nohup() {
    # If a unit was created and is flapping, stop it first: Restart=always plus a second
    # copy of the server means two processes fighting for the same port.
    if command -v systemctl >/dev/null 2>&1; then
        cap 15 systemctl disable --now kilnbrook-foundryd >/dev/null 2>&1 || true
    fi
    KILN_DB="$DB_FILE" KILN_PORT="$PORT" setsid nohup /usr/bin/python3 "${SVC}/foundryd.py" \
        >/var/log/kilnbrook-foundryd.log 2>&1 < /dev/null &
    disown || true
}

# curl arrives with the detached job, not the foreground, so the health probe here is
# python3 - which provisioning already depends on anyway.
svc_healthy() {
    python3 - "$PORT" <<'PROBE' >/dev/null 2>&1
import sys, urllib.request
urllib.request.urlopen("http://127.0.0.1:%s/health" % sys.argv[1], timeout=2).read()
PROBE
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
    ok "endpoint already running on ${PORT}"
elif start_with_systemd && wait_health; then
    ok "endpoint started under systemd"
else
    # Only ever spend the health-wait budget on something that was actually started: the
    # obvious ordering burns the whole wait against a server that never launched.
    echo "systemd path unavailable, falling back to a background process"
    start_with_nohup
    wait_health || warn "the model endpoint did not come up during setup; the check scripts start it on demand, so grading still works (see ${LOG})"
fi
if svc_healthy; then
    ok "endpoint healthy on 127.0.0.1:${PORT}"
else
    warn "endpoint not answering on 127.0.0.1:${PORT} at end of setup"
fi
note "endpoint up (t+${SECONDS}s)"

echo "=== [6/7] Grading tools and dependency hand-off ==="
# curl and jq are not needed to hand over a working lab, but they ARE needed to grade
# one: every check shells out to both. Leaving them to the detached job alone means a
# submission made in the minute after provisioning has no way to tell a missing tool
# from a wrong answer, and the check would blame the learner code for it.
#
# So they are installed here, in the foreground, but only after phases 3 to 5 have put
# the project, the database and the endpoint in place. That ordering is the point: the
# essentials never queue behind an apt call, and on an image that already ships curl and
# jq (the portal image does) this costs nothing at all. The detached job installs them
# again as a fallback for the case where this attempt failed.
if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    note "installing curl and jq (every check shells out to both)"
    # shellcheck disable=SC2086
    cap 40 apt-get install -y -qq --no-install-recommends -o DPkg::Lock::Timeout=30 curl jq \
        || note "curl/jq foreground install failed (t+${SECONDS}s); the detached job retries them"
fi
for tool in curl jq; do
    if command -v "$tool" >/dev/null 2>&1; then
        ok "have $tool"
    else
        note "$tool not present yet; the detached dependency job installs it and the checks wait for its readiness marker"
    fi
done
note "grading tools checked (t+${SECONDS}s)"


# A very short, bounded grace period. Its only purpose is to let an already-finished
# install be reported accurately in the summary below. It must never wait for the slow
# case: a wheel fetch is tens of seconds and the portal window is what that would spend.
DEPS_GRACE="${DEPS_GRACE:-2}"
for _i in $(seq 1 "$DEPS_GRACE"); do
    [ -f "$DEPS_READY" ] && break
    sleep 1
done
case "$(cat "$DEPS_STATE" 2>/dev/null)" in
    pinned) ok "installed ${PIN}" ;;
    latest) warn "the pinned openai version was unavailable; installed the latest instead" ;;
    failed) warn "pip install of openai FAILED - the lab cannot run until this is fixed (see ${PIPLOG})" ;;
    *)      note "dependencies are still downloading in the background (log ${PIPLOG}); the project, the database and the endpoint are ready now. ${DEPS_READY} appears when the install finishes, and check_local.py waits for it." ;;
esac
tail -n 5 "$PIPLOG" 2>/dev/null | sed 's/^/    pip| /'
if [ -f "$DEPS_READY" ]; then
    grep -q 'warm-up complete' "$PIPLOG" 2>/dev/null && ok "warm-up complete" || true
fi
note "dependencies handed off (t+${SECONDS}s)"

finish_summary() {
    # Emitted on the normal path and on the deadline path alike, so the portal output
    # always ends with a verdict. That output is the only diagnosis that survives a VM
    # the portal wipes after a failed attempt.
    [ "${SUMMARY_DONE:-0}" -eq 1 ] && return 0
    SUMMARY_DONE=1
    local blockers=""
    command -v python3 >/dev/null 2>&1 || blockers="${blockers} python3-missing"
    [ -s "${PROJ}/solution.py" ] || blockers="${blockers} project-missing"
    [ -s "$DB_FILE" ] || blockers="${blockers} database-missing"
    svc_healthy || blockers="${blockers} endpoint-down"
    if [ -n "$blockers" ]; then
        warn "LAB NOT READY -${blockers}"
        note "provisioning could not finish the essentials. Re-running setup on a fresh VM is"
        note "the fastest remedy; the phase timings above show which step ran out of time."
        note "total setup time: ${SECONDS}s"
        return 0
    fi
cat <<SUMMARY

--------------------------------------------------------------------
Kilnbrook Foundry lab is ready.

Project:   ${PROJ}
Provided:  kiln_kit/       (model client, database helper, persona
                            - do not modify)
           data/foundry.db (the foundry operations database)
           check_local.py  (prints what your functions return)
You write: solution.py

The model endpoint is answering on http://127.0.0.1:${PORT}/v1 and is what
kiln_kit.make_client() is configured for. Leave it running.

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
note "total setup time: ${SECONDS}s"
    if [ "$DEADLINE_HIT" -eq 1 ]; then
        note "finished early on the internal deadline; the project, the database and the endpoint are in place and the dependency install continues in the background"
    fi
}

echo "=== [7/7] Permissions & summary ==="
run "chown project to ${LAB_USER}" chown -R "${LAB_USER}:${LAB_USER}" "$PROJ"
run "make project writable" chmod -R u+rw "$PROJ"
find "$PROJ" -type d -exec chmod u+x {} + 2>/dev/null || warn "could not set directory execute bits"
rm -rf "${PROJ}/__pycache__" "${PROJ}/kiln_kit/__pycache__" 2>/dev/null || true
[ -w "${PROJ}/solution.py" ] || warn "solution.py is not writable - the learner will hit a read-only file"
[ -w "${PROJ}/data" ] || warn "the data directory is not writable by the learner"

finish_summary

# Give the tee subshell a moment to flush, then always report success: a warning must not
# fail provisioning, and the log holds everything needed to diagnose it.
kill "$WATCHDOG_PID" >/dev/null 2>&1 || true
sync 2>/dev/null || true
exit 0
