#!/bin/bash
# Westmere claims desk lab - VM provisioning script.
# Runs once, as root, before the learner starts.
# TEMPLATE: build.sh replaces every FILE marker below with that file's contents.
# No `set -e`: a failing step must be recorded and provisioning must continue,
# so a single hiccup cannot leave the learner with a half-built project or
# root-owned files.
set -uo pipefail

LOG_DIR="/var/log/westmere-lab"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp/westmere-lab"
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
PROJ="${LAB_HOME}/westmere-claims"
KIT="${PROJ}/claim_kit"
DATA_DIR="${PROJ}/data"
STATE_DIR="${PROJ}/state"
STATE_DB="${STATE_DIR}/claims.db"
SVC="/opt/westmere-svc"
PORT=8571

svc_healthy() {
    python3 - "$PORT" <<'PROBE' >/dev/null 2>&1
import sys, urllib.request
urllib.request.urlopen("http://127.0.0.1:%s/health" % sys.argv[1], timeout=2).read()
PROBE
}

note "Westmere claims desk setup starting; full log at ${LOG}"

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
# Only python3 is needed to hand over a usable lab: it runs the claims desk and
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
                > "${SITEDIR}/westmere-user-site.pth" 2>/dev/null && break
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

PIPFLAGS="--quiet --disable-pip-version-check --only-binary=:all:"
if python3 -m pip install --help 2>/dev/null | grep -q break-system-packages; then
    PIPFLAGS="$PIPFLAGS --break-system-packages"
fi

# The pinned set. --only-binary makes a wheel-less resolution fail in seconds
# with a readable error instead of starting a source build on an image with no
# compiler. The fallback keeps the majors, which is where the API lives.
PINNED="langchain==1.2.15 langchain-core==1.3.0 langgraph==1.1.9 langgraph-checkpoint-sqlite==3.0.3 pydantic==2.13.3"
LOOSE="langchain<2 langchain-core<2 langgraph<2 langgraph-checkpoint-sqlite<4 pydantic<3"
# shellcheck disable=SC2086
if python3 -m pip install $PIPFLAGS $PINNED; then
    echo pinned > "$DEPS_STATE"
# shellcheck disable=SC2086
elif python3 -m pip install $PIPFLAGS $LOOSE; then
    echo series > "$DEPS_STATE"
else
    echo failed > "$DEPS_STATE"
fi

# Pay the import and first-request cost, so the first graded run is not a cold
# start. langgraph and langchain-core are slow to import the first time.
cd "$PROJ" 2>/dev/null && python3 - <<'WARM'
import sys

sys.path.insert(0, ".")
try:
    from langgraph.checkpoint.sqlite import SqliteSaver  # noqa: F401
    from langgraph.graph import StateGraph  # noqa: F401

    import claim_kit as kit

    model = kit.get_chat_model()
    first = kit.claim_ids()[0]
    claim = kit.load_claim(first)
    model.invoke([{"role": "system", "content": kit.CHAT_SYSTEM},
                  {"role": "user", "content": claim["narrative"][:80]}])
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
mkdir -p "$KIT" "$DATA_DIR" "$STATE_DIR"

cat > "${KIT}/__init__.py" <<'___WMFILE___'
@@FILE:app/claim_kit/__init__.py@@
___WMFILE___

cat > "${KIT}/client.py" <<'___WMFILE___'
@@FILE:app/claim_kit/client.py@@
___WMFILE___

cat > "${KIT}/model.py" <<'___WMFILE___'
@@FILE:app/claim_kit/model.py@@
___WMFILE___

cat > "${KIT}/claims.py" <<'___WMFILE___'
@@FILE:app/claim_kit/claims.py@@
___WMFILE___

cat > "${KIT}/prompts.py" <<'___WMFILE___'
@@FILE:app/claim_kit/prompts.py@@
___WMFILE___

cat > "${KIT}/tools.py" <<'___WMFILE___'
@@FILE:app/claim_kit/tools.py@@
___WMFILE___

cat > "${DATA_DIR}/claims.json" <<'___WMFILE___'
@@FILE:app/data/claims.json@@
___WMFILE___

cat > "${PROJ}/check_local.py" <<'___WMFILE___'
@@FILE:app/check_local.py@@
___WMFILE___

cat > "/tmp/.westmere_stub.py" <<'___WMFILE___'
@@FILE:app/claimctl_stub.py@@
___WMFILE___

# Never clobber work in progress: the starter is only installed on a fresh
# project.
if [ ! -f "${PROJ}/claimctl.py" ]; then
    cp /tmp/.westmere_stub.py "${PROJ}/claimctl.py"
    echo "installed claimctl.py starter"
else
    echo "claimctl.py already exists - left untouched"
fi
rm -f /tmp/.westmere_stub.py

# Hand the project over immediately, before any step that could fail and leave
# these files root-owned - and therefore read-only for the learner.
run "early chown of ${PROJ}" chown -R "${LAB_USER}:${LAB_USER}" "$PROJ"
chmod -R u+rw "$PROJ" 2>/dev/null || warn "early chmod failed"
find "$PROJ" -type d -exec chmod u+x {} + 2>/dev/null || true
[ -s "${PROJ}/claimctl.py" ] && ok "claimctl.py in place" || warn "claimctl.py missing or empty"
[ -s "${DATA_DIR}/claims.json" ] && ok "claims file in place" || warn "claims file missing or empty"
note "project skeleton done (t+${SECONDS}s)"

echo "=== [4/8] Claims desk files ==="
mkdir -p "$SVC"

cat > "${SVC}/claimsvc.py" <<'___WMFILE___'
@@FILE:service/claimsvc.py@@
___WMFILE___

# The desk reads its own copy rather than the one in the project, so nothing the
# learner does to their files can change what the desk answers.
cat > "${SVC}/claims.json" <<'___WMFILE___'
@@FILE:app/data/claims.json@@
___WMFILE___

chown -R root:root "$SVC"
chmod 700 "$SVC"
chmod 600 "${SVC}/claims.json"
chmod 700 "${SVC}/claimsvc.py"
note "claims desk files written (t+${SECONDS}s)"

echo "=== [5/8] Learner state the checks touch ==="
# The checks run the learner program, and the learner program opens a SQLite
# checkpoint store. Opening a database CREATES it, so if a check gets there
# first the file is root-owned and every later run of their own program fails
# with a readonly database. Both the directory and the file are created here as
# the learner; the checks additionally chown the project back from an EXIT trap.
mkdir -p "$STATE_DIR" 2>/dev/null || true
[ -e "$STATE_DB" ] || : > "$STATE_DB" 2>/dev/null || true
run "chown state directory to ${LAB_USER}" chown -R "${LAB_USER}:${LAB_USER}" "$STATE_DIR"
chmod 755 "$STATE_DIR" 2>/dev/null || true
chmod 664 "$STATE_DB" 2>/dev/null || true
[ -e "$STATE_DB" ] && ok "checkpoint store pre-created and owned by ${LAB_USER}" \
    || warn "could not pre-create ${STATE_DB}"
note "learner state done (t+${SECONDS}s)"

echo "=== [6/8] Starting the claims desk ==="
start_with_systemd() {
    command -v systemctl >/dev/null 2>&1 || return 1
    cat > /etc/systemd/system/westmere-desk.service <<UNIT
[Unit]
Description=Westmere claims desk
After=network.target

[Service]
Type=simple
Environment=WESTMERE_PORT=${PORT}
Environment=WESTMERE_CLAIMS=${SVC}/claims.json
ExecStart=${PYBIN} ${SVC}/claimsvc.py
Restart=always
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
UNIT
    cap 15 systemctl daemon-reload >/dev/null 2>&1 || return 1
    cap 25 systemctl enable --now westmere-desk >/dev/null 2>&1 || return 1
    return 0
}

start_with_nohup() {
    if command -v systemctl >/dev/null 2>&1; then
        cap 15 systemctl disable --now westmere-desk >/dev/null 2>&1 || true
    fi
    export WESTMERE_PORT="$PORT" WESTMERE_CLAIMS="${SVC}/claims.json"
    detach /var/log/westmere-desk.log "$PYBIN" "${SVC}/claimsvc.py"
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
    ok "claims desk already running on ${PORT}"
elif start_with_systemd && wait_health; then
    ok "claims desk started under systemd"
else
    echo "systemd path unavailable, falling back to a background process"
    start_with_nohup
    wait_health || warn "the claims desk did not come up during setup; the check scripts start it on demand, so grading still works (see ${LOG})"
fi
if svc_healthy; then
    ok "claims desk healthy on 127.0.0.1:${PORT}"
else
    warn "claims desk not answering on 127.0.0.1:${PORT} at end of setup"
fi
note "claims desk up (t+${SECONDS}s)"

echo "=== [7/8] Dependency hand-off ==="
DEPS_GRACE="${DEPS_GRACE:-5}"
for _i in $(seq 1 "$DEPS_GRACE"); do
    [ -f "$DEPS_READY" ] && break
    sleep 1
done
case "$(cat "$DEPS_STATE" 2>/dev/null)" in
    pinned) ok "installed the pinned langchain and langgraph versions" ;;
    series) warn "a pinned version was unavailable; installed the newest of each major instead" ;;
    failed) warn "pip install FAILED - the lab cannot run until this is fixed (see ${PIPLOG})" ;;
    *)      note "the packages are still downloading in the background (log ${PIPLOG}); the project, the claims file and the desk are ready now. ${DEPS_READY} appears when the install finishes, and check_local.py and the checks both wait for it." ;;
esac
tail -n 5 "$PIPLOG" 2>/dev/null | sed 's/^/    pip| /'
note "dependencies handed off (t+${SECONDS}s)"

finish_summary() {
    [ "${SUMMARY_DONE:-0}" -eq 1 ] && return 0
    SUMMARY_DONE=1
    local blockers=""
    command -v python3 >/dev/null 2>&1 || blockers="${blockers} python3-missing"
    [ -s "${PROJ}/claimctl.py" ] || blockers="${blockers} project-missing"
    [ -s "${DATA_DIR}/claims.json" ] || blockers="${blockers} claims-missing"
    svc_healthy || blockers="${blockers} claims-desk-down"
    if [ -n "$blockers" ]; then
        warn "LAB NOT READY -${blockers}"
        note "provisioning could not finish the essentials. Re-running setup on a fresh VM is"
        note "the fastest remedy; the phase timings above show which step ran out of time."
        note "total setup time: ${SECONDS}s"
        return 0
    fi
cat <<SUMMARY

--------------------------------------------------------------------
Westmere claims desk lab is ready.

Project:   ${PROJ}
Provided:  claim_kit/         the chat model, the claims file, the prompts and
                              the three desk tools - do not modify
           data/claims.json   the claims on file
           state/             where your checkpoint store goes
           check_local.py     runs every subcommand and shows what it printed
You write: claimctl.py         the command line itself

The claims desk is answering on http://127.0.0.1:${PORT} and is what the
provided model and tools talk to. Leave it running.

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
        note "finished early on the internal deadline; the project, the claims file and the desk are in place and the dependency install continues in the background"
    fi
}

echo "=== [8/8] Permissions and summary ==="
run "chown project to ${LAB_USER}" chown -R "${LAB_USER}:${LAB_USER}" "$PROJ"
run "make project writable" chmod -R u+rw "$PROJ"
find "$PROJ" -type d -exec chmod u+x {} + 2>/dev/null || warn "could not set directory execute bits"
rm -rf "${PROJ}/__pycache__" "${KIT}/__pycache__" 2>/dev/null || true
[ -w "${PROJ}/claimctl.py" ] || warn "claimctl.py is not writable - the learner will hit a read-only file"

finish_summary

kill "$WATCHDOG_PID" >/dev/null 2>&1 || true
sync 2>/dev/null || true
exit 0
