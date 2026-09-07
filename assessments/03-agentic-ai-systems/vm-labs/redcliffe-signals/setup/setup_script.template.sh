#!/bin/bash
# Redcliffe Signals lab - VM provisioning script.
# Runs once, as root, before the learner starts.
# TEMPLATE: build.sh replaces every FILE marker below with that file's contents.
# No `set -e`: a failing step must be recorded and provisioning must continue,
# so a single hiccup cannot leave the learner with a half-built project or
# root-owned files.
set -uo pipefail

LOG_DIR="/var/log/redcliffe-lab"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp/redcliffe-lab"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp"
LOG="${LOG_DIR}/setup.log"
STATUS_FILE="${LOG_DIR}/setup-status"
: > "$STATUS_FILE" 2>/dev/null || true

exec > >(tee -a "$LOG") 2>&1

WARNINGS=0
stamp() { date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "-"; }
note()  { echo "[$(stamp)] $*"; }
ok()    { echo "[$(stamp)] OK   $*"; printf 'OK   %s\n'   "$*" >>"$STATUS_FILE" 2>/dev/null || true; }
warn()  { WARNINGS=$((WARNINGS + 1)); echo "[$(stamp)] WARN $*"; printf 'WARN %s\n' "$*" >>"$STATUS_FILE" 2>/dev/null || true; }
run()   { local label="$1"; shift; if "$@"; then ok "$label"; else warn "$label (exit $?)"; fi; return 0; }

# cap <seconds> <cmd...> : never let one command block provisioning
# indefinitely. Pure bash rather than coreutils timeout(1), because a silently
# absent timeout binary turns a bound into a no-op. The command is waited for in
# one-second steps: bash dispatches a trap only between commands, so blocking in
# the foreground would defer the deadline watchdog below.
cap() {
    local secs="$1"; shift
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
PROJ="${LAB_HOME}/redcliffe-signals"
KIT="${PROJ}/signal_kit"
PKG="${PROJ}/signals"
SVC="/opt/redcliffe-svc"
PORT=8622

svc_healthy() {
    python3 - "$PORT" <<'PROBE' >/dev/null 2>&1
import sys, urllib.request
urllib.request.urlopen("http://127.0.0.1:%s/health" % sys.argv[1], timeout=2).read()
PROBE
}

note "Redcliffe Signals setup starting; full log at ${LOG}"

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

echo "=== [1/8] Base packages ==="
export DEBIAN_FRONTEND=noninteractive
if ! id -u "$LAB_USER" >/dev/null 2>&1; then
    cap 20 useradd -m -s /bin/bash "$LAB_USER" || true
fi
# Only python3 is needed to hand over a usable lab: it runs the control desk and
# the learner program. pip, curl and jq are consumers that come later, so they
# are installed by the detached job rather than on the path the portal is
# waiting on. The health probe below is python3 for the same reason.
if ! command -v python3 >/dev/null 2>&1; then
    note "installing python3 (the only package provisioning itself needs)"
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
        [ "$attempt" -eq 1 ] && sleep 5
    done
    [ "$apt_ok" -eq 1 ] || warn "could not install python3 (t+${SECONDS}s) - the lab will not work"
fi
command -v python3 >/dev/null 2>&1 && ok "have python3 ($(python3 -V 2>&1))" || warn "missing python3"
PYBIN="$(command -v python3 || echo /usr/bin/python3)"

if command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
    ln -sf "$(command -v python3)" /usr/local/bin/python 2>/dev/null \
        && ok "python -> python3" || warn "could not link python"
fi

# The image marks its interpreter externally managed, so a plain pip install
# refuses under PEP 668. Written before anything runs pip, the learner included.
if [ ! -f /etc/pip.conf ]; then
    printf '[global]\nbreak-system-packages = true\ndisable-pip-version-check = true\n' \
        > /etc/pip.conf 2>/dev/null && ok "wrote /etc/pip.conf" || warn "could not write /etc/pip.conf"
fi

# sudo needs a password on this image, so anything the learner installs
# themselves lands in ~/.local, which root cannot import from. Bridge it, or
# their code runs while every check reports a missing module.
PYVER="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo "")"
if [ -n "$PYVER" ]; then
    for SITEDIR in "/usr/local/lib/python${PYVER}/dist-packages" "/usr/lib/python3/dist-packages"; do
        if [ -d "$SITEDIR" ]; then
            echo "${LAB_HOME}/.local/lib/python${PYVER}/site-packages" \
                > "${SITEDIR}/redcliffe-user-site.pth" 2>/dev/null && break
        fi
    done
fi
note "base packages done (t+${SECONDS}s)"

echo "=== [2/8] Runtime dependencies (detached; the foreground never waits) ==="
PIPLOG="${LOG_DIR}/pip.log"
DEPS_STATE="${LOG_DIR}/deps.state"
DEPS_READY="${LOG_DIR}/deps.ready"
DEPS_JOB="${LOG_DIR}/install-deps.sh"
rm -f "$DEPS_STATE" "$DEPS_READY"

{
    echo '#!/bin/bash'
    echo '# GENERATED by the setup script - installs what the lab needs after'
    echo '# provisioning has already returned, then publishes a readiness file.'
    echo "DEPS_STATE=\"${DEPS_STATE}\""
    echo "DEPS_READY=\"${DEPS_READY}\""
    echo "PROJ=\"${PROJ}\""
    echo "PORT=\"${PORT}\""
    cat <<'DEPSJOB'
# Keeps this from dropping root-owned __pycache__ into the learner project
# after phase 8 has already handed it over.
export PYTHONDONTWRITEBYTECODE=1
export DEBIAN_FRONTEND=noninteractive
APT_OPTS="-o DPkg::Lock::Timeout=60"

# pip for the wheels below; curl and jq because the check scripts use them.
for attempt in 1 2; do
    # shellcheck disable=SC2086
    apt-get install -y -qq --no-install-recommends $APT_OPTS python3-pip curl jq && break
    # shellcheck disable=SC2086
    apt-get update -qq $APT_OPTS
    # shellcheck disable=SC2086
    apt-get install -y -qq --no-install-recommends $APT_OPTS python3-pip curl jq && break
    sleep 5
done

# Nothing this lab needs is outside the standard library: the control desk, the
# vectoriser and the learner modules are all stdlib. What the detached job is
# for is curl and jq, which the check scripts shell out to.
if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    echo present > "$DEPS_STATE"
else
    echo missing > "$DEPS_STATE"
fi

# Pay the import and first-request cost, so the first graded run is not a cold
# start. langgraph and langchain-core are slow to import the first time.
cd "$PROJ" 2>/dev/null && python3 - <<'WARM'
import sys

sys.path.insert(0, ".")
try:
    import signal_kit as kit

    kit.embed("warming the vectoriser")
    kit.think("what aspect is RC-BOX-14 showing", 1)
    print("warm-up complete")
except Exception as exc:
    print("warm-up skipped: %s: %s" % (type(exc).__name__, exc))

WARM

# Written last, and only once the install has resolved, so its presence means
# the state file is final and pip, curl and jq are all present.
touch "$DEPS_READY"
DEPSJOB
} > "$DEPS_JOB"
chmod 700 "$DEPS_JOB"
detach "$PIPLOG" "$DEPS_JOB"
note "runtime dependency install detached (job ${DEPS_JOB}, log ${PIPLOG})"

echo "=== [3/8] Project skeleton ==="
mkdir -p "$KIT" "$PKG" "${PROJ}/store"

cat > "${KIT}/__init__.py" <<'___RCFILE___'
@@FILE:app/signal_kit/__init__.py@@
___RCFILE___

cat > "${KIT}/client.py" <<'___RCFILE___'
@@FILE:app/signal_kit/client.py@@
___RCFILE___

cat > "${KIT}/desk.py" <<'___RCFILE___'
@@FILE:app/signal_kit/desk.py@@
___RCFILE___

cat > "${KIT}/embed.py" <<'___RCFILE___'
@@FILE:app/signal_kit/embed.py@@
___RCFILE___

cat > "${KIT}/prompts.py" <<'___RCFILE___'
@@FILE:app/signal_kit/prompts.py@@
___RCFILE___

cat > "${PKG}/__init__.py" <<'___RCFILE___'
@@FILE:app/signals/__init__.py@@
___RCFILE___

cat > "${PROJ}/signalctl.py" <<'___RCFILE___'
@@FILE:app/signalctl.py@@
___RCFILE___

cat > "${PROJ}/check_local.py" <<'___RCFILE___'
@@FILE:app/check_local.py@@
___RCFILE___

cat > "/tmp/.rc_react_stub.py" <<'___RCFILE___'
@@FILE:app/signals/react_loop_stub.py@@
___RCFILE___

cat > "/tmp/.rc_reflect_stub.py" <<'___RCFILE___'
@@FILE:app/signals/reflect_stub.py@@
___RCFILE___

cat > "/tmp/.rc_memory_stub.py" <<'___RCFILE___'
@@FILE:app/signals/memory_stub.py@@
___RCFILE___

# Never clobber work in progress: the starters are only installed on a fresh
# project.
for pair in "react_loop.py:/tmp/.rc_react_stub.py" \
            "reflect.py:/tmp/.rc_reflect_stub.py" \
            "memory.py:/tmp/.rc_memory_stub.py"; do
    name="${pair%%:*}"; from="${pair#*:}"
    if [ ! -f "${PKG}/${name}" ]; then
        cp "$from" "${PKG}/${name}"
        echo "installed signals/${name} starter"
    else
        echo "signals/${name} already exists - left untouched"
    fi
done
rm -f /tmp/.rc_react_stub.py /tmp/.rc_reflect_stub.py /tmp/.rc_memory_stub.py

# Hand the project over immediately, before any step that could fail and leave
# these files root-owned - and therefore read-only for the learner.
run "early chown of ${PROJ}" chown -R "${LAB_USER}:${LAB_USER}" "$PROJ"
chmod -R u+rw "$PROJ" 2>/dev/null || warn "early chmod failed"
find "$PROJ" -type d -exec chmod u+x {} + 2>/dev/null || true
[ -s "${PKG}/memory.py" ] && ok "signals/ starters in place" || warn "signals/ starters missing"
[ -s "${PROJ}/signalctl.py" ] && ok "signalctl.py in place" || warn "signalctl.py missing"
note "project skeleton done (t+${SECONDS}s)"

echo "=== [4/8] Control desk files ==="
mkdir -p "$SVC"

cat > "${SVC}/signalsvc.py" <<'___RCFILE___'
@@FILE:service/signalsvc.py@@
___RCFILE___

chown -R root:root "$SVC"
chmod 700 "$SVC"
chmod 700 "${SVC}/signalsvc.py"
note "control desk files written (t+${SECONDS}s)"

echo "=== [5/8] Learner state the checks touch ==="
# The checks run the learner program, and writing a note CREATES the store. If a
# check gets there first the file is root-owned and every later run of their own
# program fails to append to it. Both the directory and the file are created
# here as the learner; the checks additionally chown the project back from an
# EXIT trap.
STORE_DIR="${PROJ}/store"
STORE_FILE="${STORE_DIR}/signals.jsonl"
mkdir -p "$STORE_DIR" 2>/dev/null || true
[ -e "$STORE_FILE" ] || : > "$STORE_FILE" 2>/dev/null || true
run "chown store directory to ${LAB_USER}" chown -R "${LAB_USER}:${LAB_USER}" "$STORE_DIR"
chmod 755 "$STORE_DIR" 2>/dev/null || true
chmod 664 "$STORE_FILE" 2>/dev/null || true
[ -e "$STORE_FILE" ] && ok "note store pre-created and owned by ${LAB_USER}" \
    || warn "could not pre-create ${STORE_FILE}"
note "learner state done (t+${SECONDS}s)"

echo "=== [6/8] Starting the control desk ==="
start_with_systemd() {
    command -v systemctl >/dev/null 2>&1 || return 1
    cat > /etc/systemd/system/redcliffe-desk.service <<UNIT
[Unit]
Description=Redcliffe control desk
After=network.target

[Service]
Type=simple
Environment=REDCLIFFE_PORT=${PORT}
ExecStart=${PYBIN} ${SVC}/signalsvc.py
Restart=always
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
UNIT
    cap 15 systemctl daemon-reload >/dev/null 2>&1 || return 1
    cap 25 systemctl enable --now redcliffe-desk >/dev/null 2>&1 || return 1
    return 0
}

start_with_nohup() {
    if command -v systemctl >/dev/null 2>&1; then
        cap 15 systemctl disable --now redcliffe-desk >/dev/null 2>&1 || true
    fi
    export REDCLIFFE_PORT="$PORT"
    detach /var/log/redcliffe-desk.log "$PYBIN" "${SVC}/signalsvc.py"
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
    ok "control desk already running on ${PORT}"
elif start_with_systemd && wait_health; then
    ok "control desk started under systemd"
else
    echo "systemd path unavailable, falling back to a background process"
    start_with_nohup
    wait_health || warn "the control desk did not come up during setup; the check scripts start it on demand, so grading still works (see ${LOG})"
fi
if svc_healthy; then
    ok "control desk healthy on 127.0.0.1:${PORT}"
else
    warn "control desk not answering on 127.0.0.1:${PORT} at end of setup"
fi
note "control desk up (t+${SECONDS}s)"

echo "=== [7/8] Dependency hand-off ==="
DEPS_GRACE="${DEPS_GRACE:-5}"
for _i in $(seq 1 "$DEPS_GRACE"); do
    [ -f "$DEPS_READY" ] && break
    sleep 1
done
case "$(cat "$DEPS_STATE" 2>/dev/null)" in
    present) ok "curl and jq are installed" ;;
    missing) warn "curl or jq is missing - the check scripts need both (see ${PIPLOG})" ;;
    *)       note "the graders tools are still installing in the background (log ${PIPLOG}); the project and the control desk are ready now" ;;
esac
tail -n 5 "$PIPLOG" 2>/dev/null | sed 's/^/    pip| /'
note "dependencies handed off (t+${SECONDS}s)"

finish_summary() {
    [ "${SUMMARY_DONE:-0}" -eq 1 ] && return 0
    SUMMARY_DONE=1
    local blockers=""
    command -v python3 >/dev/null 2>&1 || blockers="${blockers} python3-missing"
    [ -s "${PROJ}/signalctl.py" ] || blockers="${blockers} project-missing"
    [ -s "${KIT}/desk.py" ] || blockers="${blockers} kit-missing"
    svc_healthy || blockers="${blockers} desk-down"
    if [ -n "$blockers" ]; then
        warn "LAB NOT READY -${blockers}"
        note "provisioning could not finish the essentials. Re-running setup on a fresh VM is"
        note "the fastest remedy; the phase timings above show which step ran out of time."
        note "total setup time: ${SECONDS}s"
        return 0
    fi
cat <<SUMMARY

--------------------------------------------------------------------
Redcliffe Signals lab is ready.

Project:   ${PROJ}
Provided:  signal_kit/       the control desk, the three tools and the
                             vectoriser - do not modify
           signalctl.py      the command line that calls your modules
           store/            where your note store goes
           check_local.py    runs every subcommand and shows what it printed
You write: signals/react_loop.py
           signals/reflect.py
           signals/memory.py

The control desk is answering on http://127.0.0.1:${PORT}. Leave it running.
Everything else here is the standard library - there is nothing to install and
no key to set.

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
        note "finished early on the internal deadline; the project and the control desk are in place"
    fi
}

echo "=== [8/8] Permissions and summary ==="
run "chown project to ${LAB_USER}" chown -R "${LAB_USER}:${LAB_USER}" "$PROJ"
run "make project writable" chmod -R u+rw "$PROJ"
find "$PROJ" -type d -exec chmod u+x {} + 2>/dev/null || warn "could not set directory execute bits"
rm -rf "${PROJ}/__pycache__" "${KIT}/__pycache__" "${PKG}/__pycache__" 2>/dev/null || true
[ -w "${PKG}/memory.py" ] || warn "signals/memory.py is not writable - the learner will hit a read-only file"

finish_summary

kill "$WATCHDOG_PID" >/dev/null 2>&1 || true
sync 2>/dev/null || true
exit 0
