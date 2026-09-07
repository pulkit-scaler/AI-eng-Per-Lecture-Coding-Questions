#!/bin/bash
# Caverly Trust lab - VM provisioning script.
# Runs once, as root, before the learner starts.
# TEMPLATE: build.sh replaces every FILE marker below with that file's contents.
# No `set -e`: a failing step must be recorded and provisioning must continue,
# so a single hiccup cannot leave the learner with a half-built project or
# root-owned files.
set -uo pipefail

LOG_DIR="/var/log/caverly-lab"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp/caverly-lab"
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
PROJ="${LAB_HOME}/caverly-trust"
KIT="${PROJ}/trust_kit"
GUARDS="${PROJ}/guards"
SVC="/opt/caverly-svc"
PORT=8744

svc_healthy() {
    python3 - "$PORT" <<'PROBE' >/dev/null 2>&1
import sys, urllib.request
urllib.request.urlopen("http://127.0.0.1:%s/health" % sys.argv[1], timeout=2).read()
PROBE
}

note "Caverly Trust setup starting; full log at ${LOG}"

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
# Only python3 is needed to hand over a usable lab: it runs the support desk and
# the learner program. curl and jq are consumers the check scripts need, so they
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

# curl and jq are not a grader convenience: the platform helper builds its one
# line of output with `jq -n`, so a check that runs before jq exists cannot emit
# a verdict at all and the portal renders an empty panel. They are small, and
# every image seen so far already ships them, so this is normally a no-op - but
# it must not be left to the detached job, which finishes after the learner can
# already press Submit.
if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    ok "have curl and jq (the helper needs jq to print a verdict)"
else
    note "installing curl and jq in the foreground; a check cannot report without them"
    APT_OPTS="-o DPkg::Lock::Timeout=30"
    # shellcheck disable=SC2086
    cap 45 apt-get install -y -qq --no-install-recommends $APT_OPTS curl jq \
        || { cap 45 apt-get update -qq $APT_OPTS; \
             cap 45 apt-get install -y -qq --no-install-recommends $APT_OPTS curl jq; }
    if command -v jq >/dev/null 2>&1; then
        ok "curl and jq installed"
    else
        warn "jq is still missing - checks will not be able to print a verdict"
    fi
fi

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
note "base packages done (t+${SECONDS}s)"

echo "=== [2/8] Grader tooling (detached; the foreground never waits) ==="
DEPSLOG="${LOG_DIR}/deps.log"
DEPS_STATE="${LOG_DIR}/deps.state"
DEPS_READY="${LOG_DIR}/deps.ready"
DEPS_JOB="${LOG_DIR}/install-deps.sh"
rm -f "$DEPS_STATE" "$DEPS_READY"

{
    echo '#!/bin/bash'
    echo '# GENERATED by the setup script - installs what the checks need after'
    echo '# provisioning has already returned, then publishes a readiness file.'
    echo "DEPS_STATE=\"${DEPS_STATE}\""
    echo "DEPS_READY=\"${DEPS_READY}\""
    echo "PROJ=\"${PROJ}\""
    cat <<'DEPSJOB'
# Keeps this from dropping root-owned __pycache__ into the learner project
# after phase 8 has already handed it over.
export PYTHONDONTWRITEBYTECODE=1
export DEBIAN_FRONTEND=noninteractive
APT_OPTS="-o DPkg::Lock::Timeout=60"

# Nothing this lab needs is outside the standard library. curl and jq are here
# because the check scripts shell out to them.
for attempt in 1 2; do
    # shellcheck disable=SC2086
    apt-get install -y -qq --no-install-recommends $APT_OPTS curl jq && break
    # shellcheck disable=SC2086
    apt-get update -qq $APT_OPTS
    # shellcheck disable=SC2086
    apt-get install -y -qq --no-install-recommends $APT_OPTS curl jq && break
    sleep 5
done

if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    echo present > "$DEPS_STATE"
else
    echo missing > "$DEPS_STATE"
fi

# Pay the import cost once, so the first graded run is not a cold start.
cd "$PROJ" 2>/dev/null && python3 - <<'WARM'
import sys

sys.path.insert(0, ".")
try:
    import trust_kit

    trust_kit.run_agent("What is my balance right now?",
                        {"auth_user_id": "u_maren"})
    print("warm-up complete")
except Exception as exc:
    print("warm-up skipped: %s: %s" % (type(exc).__name__, exc))

WARM

# Written last, and only once the install has resolved, so its presence means
# the state file is final and curl and jq are both present.
touch "$DEPS_READY"
DEPSJOB
} > "$DEPS_JOB"
chmod 700 "$DEPS_JOB"
detach "$DEPSLOG" "$DEPS_JOB"
note "grader tooling install detached (job ${DEPS_JOB}, log ${DEPSLOG})"

echo "=== [3/8] Project skeleton ==="
mkdir -p "$KIT" "$GUARDS" "${PROJ}/campaigns" "${PROJ}/reports"

cat > "${KIT}/__init__.py" <<'___CVFILE___'
@@FILE:app/trust_kit/__init__.py@@
___CVFILE___

cat > "${KIT}/client.py" <<'___CVFILE___'
@@FILE:app/trust_kit/client.py@@
___CVFILE___

cat > "${KIT}/bank.py" <<'___CVFILE___'
@@FILE:app/trust_kit/bank.py@@
___CVFILE___

cat > "${KIT}/agent.py" <<'___CVFILE___'
@@FILE:app/trust_kit/agent.py@@
___CVFILE___

cat > "${KIT}/redteam.py" <<'___CVFILE___'
@@FILE:app/trust_kit/redteam.py@@
___CVFILE___

cat > "${GUARDS}/__init__.py" <<'___CVFILE___'
@@FILE:app/guards/__init__.py@@
___CVFILE___

cat > "${PROJ}/check_local.py" <<'___CVFILE___'
@@FILE:app/check_local.py@@
___CVFILE___

cat > "${PROJ}/campaigns/sample.json" <<'___CVFILE___'
@@FILE:app/campaigns/sample.json@@
___CVFILE___

cat > "/tmp/.cv_input_stub.py" <<'___CVFILE___'
@@FILE:app/guards/input_rail_stub.py@@
___CVFILE___

cat > "/tmp/.cv_retrieval_stub.py" <<'___CVFILE___'
@@FILE:app/guards/retrieval_rail_stub.py@@
___CVFILE___

cat > "/tmp/.cv_tool_stub.py" <<'___CVFILE___'
@@FILE:app/guards/tool_rail_stub.py@@
___CVFILE___

cat > "/tmp/.cv_output_stub.py" <<'___CVFILE___'
@@FILE:app/guards/output_rail_stub.py@@
___CVFILE___

cat > "/tmp/.cv_harden_stub.py" <<'___CVFILE___'
@@FILE:app/harden_stub.py@@
___CVFILE___

# Never clobber work in progress: the starters are only installed on a fresh
# project.
for pair in "guards/input_rail.py:/tmp/.cv_input_stub.py" \
            "guards/retrieval_rail.py:/tmp/.cv_retrieval_stub.py" \
            "guards/tool_rail.py:/tmp/.cv_tool_stub.py" \
            "guards/output_rail.py:/tmp/.cv_output_stub.py" \
            "harden.py:/tmp/.cv_harden_stub.py"; do
    name="${pair%%:*}"; from="${pair#*:}"
    if [ ! -f "${PROJ}/${name}" ]; then
        cp "$from" "${PROJ}/${name}"
        echo "installed ${name} starter"
    else
        echo "${name} already exists - left untouched"
    fi
done
rm -f /tmp/.cv_input_stub.py /tmp/.cv_retrieval_stub.py /tmp/.cv_tool_stub.py \
      /tmp/.cv_output_stub.py /tmp/.cv_harden_stub.py

# Hand the project over immediately, before any step that could fail and leave
# these files root-owned - and therefore read-only for the learner.
run "early chown of ${PROJ}" chown -R "${LAB_USER}:${LAB_USER}" "$PROJ"
chmod -R u+rw "$PROJ" 2>/dev/null || warn "early chmod failed"
find "$PROJ" -type d -exec chmod u+x {} + 2>/dev/null || true
[ -s "${GUARDS}/tool_rail.py" ] && ok "guards/ starters in place" || warn "guards/ starters missing"
[ -s "${PROJ}/harden.py" ] && ok "harden.py in place" || warn "harden.py missing"
note "project skeleton done (t+${SECONDS}s)"

echo "=== [4/8] Support desk files ==="
mkdir -p "$SVC"

cat > "${SVC}/trustsvc.py" <<'___CVFILE___'
@@FILE:service/trustsvc.py@@
___CVFILE___

chown -R root:root "$SVC"
chmod 700 "$SVC"
chmod 700 "${SVC}/trustsvc.py"
note "support desk files written (t+${SECONDS}s)"

echo "=== [5/8] Learner state the checks touch ==="
# A check runs the learner gate, and the gate WRITES reports/scorecard.json. If
# a check gets there first the file is root-owned and every later run of their
# own program fails to replace it. Both the directory and the file are created
# here as the learner; the checks additionally chown the project back from an
# EXIT trap.
REPORT_DIR="${PROJ}/reports"
REPORT_FILE="${REPORT_DIR}/scorecard.json"
mkdir -p "$REPORT_DIR" 2>/dev/null || true
[ -e "$REPORT_FILE" ] || printf '{}\n' > "$REPORT_FILE" 2>/dev/null || true
run "chown report directory to ${LAB_USER}" chown -R "${LAB_USER}:${LAB_USER}" "$REPORT_DIR"
chmod 755 "$REPORT_DIR" 2>/dev/null || true
chmod 664 "$REPORT_FILE" 2>/dev/null || true
[ -e "$REPORT_FILE" ] && ok "scorecard path pre-created and owned by ${LAB_USER}" \
    || warn "could not pre-create ${REPORT_FILE}"
note "learner state done (t+${SECONDS}s)"

echo "=== [6/8] Starting the support desk ==="
start_with_systemd() {
    command -v systemctl >/dev/null 2>&1 || return 1
    cat > /etc/systemd/system/caverly-desk.service <<UNIT
[Unit]
Description=Caverly Trust support desk
After=network.target

[Service]
Type=simple
Environment=CAVERLY_PORT=${PORT}
ExecStart=${PYBIN} ${SVC}/trustsvc.py
Restart=always
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
UNIT
    cap 15 systemctl daemon-reload >/dev/null 2>&1 || return 1
    cap 25 systemctl enable --now caverly-desk >/dev/null 2>&1 || return 1
    return 0
}

start_with_nohup() {
    if command -v systemctl >/dev/null 2>&1; then
        cap 15 systemctl disable --now caverly-desk >/dev/null 2>&1 || true
    fi
    export CAVERLY_PORT="$PORT"
    detach /var/log/caverly-desk.log "$PYBIN" "${SVC}/trustsvc.py"
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
    ok "support desk already running on ${PORT}"
elif start_with_systemd && wait_health; then
    ok "support desk started under systemd"
else
    echo "systemd path unavailable, falling back to a background process"
    start_with_nohup
    wait_health || warn "the support desk did not come up during setup; the check scripts start it on demand, so grading still works (see ${LOG})"
fi
if svc_healthy; then
    ok "support desk healthy on 127.0.0.1:${PORT}"
else
    warn "support desk not answering on 127.0.0.1:${PORT} at end of setup"
fi
note "support desk up (t+${SECONDS}s)"

echo "=== [7/8] Tooling hand-off ==="
DEPS_GRACE="${DEPS_GRACE:-5}"
for _i in $(seq 1 "$DEPS_GRACE"); do
    [ -f "$DEPS_READY" ] && break
    sleep 1
done
case "$(cat "$DEPS_STATE" 2>/dev/null)" in
    present) ok "curl and jq are installed" ;;
    missing) warn "curl or jq is missing - the check scripts need both (see ${DEPSLOG})" ;;
    *)       note "the grader tools are still installing in the background (log ${DEPSLOG}); the project and the support desk are ready now" ;;
esac
tail -n 5 "$DEPSLOG" 2>/dev/null | sed 's/^/    deps| /'
note "tooling handed off (t+${SECONDS}s)"

finish_summary() {
    [ "${SUMMARY_DONE:-0}" -eq 1 ] && return 0
    SUMMARY_DONE=1
    local blockers=""
    command -v python3 >/dev/null 2>&1 || blockers="${blockers} python3-missing"
    [ -s "${PROJ}/harden.py" ] || blockers="${blockers} project-missing"
    [ -s "${KIT}/agent.py" ] || blockers="${blockers} kit-missing"
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
Caverly Trust lab is ready.

Project:   ${PROJ}
Provided:  trust_kit/        the support agent, the account records, the
                             tools and the campaign runner - do not modify
           campaigns/        a small sample campaign
           check_local.py    runs your defence layer against that campaign
           reports/          where your scorecard goes
You write: guards/input_rail.py
           guards/retrieval_rail.py
           guards/tool_rail.py
           guards/output_rail.py
           harden.py

The support desk is answering on http://127.0.0.1:${PORT}. Leave it running.
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
        note "finished early on the internal deadline; the project and the support desk are in place"
    fi
}

echo "=== [8/8] Permissions and summary ==="
run "chown project to ${LAB_USER}" chown -R "${LAB_USER}:${LAB_USER}" "$PROJ"
run "make project writable" chmod -R u+rw "$PROJ"
find "$PROJ" -type d -exec chmod u+x {} + 2>/dev/null || warn "could not set directory execute bits"
rm -rf "${PROJ}/__pycache__" "${KIT}/__pycache__" "${GUARDS}/__pycache__" 2>/dev/null || true
[ -w "${GUARDS}/tool_rail.py" ] || warn "guards/tool_rail.py is not writable - the learner will hit a read-only file"

finish_summary

kill "$WATCHDOG_PID" >/dev/null 2>&1 || true
sync 2>/dev/null || true
exit 0
