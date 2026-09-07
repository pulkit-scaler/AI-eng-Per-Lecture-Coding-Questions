#!/bin/bash
# Thistledown Mill lab - VM provisioning script.
# Runs once, as root, before the learner starts.
# TEMPLATE: build.sh replaces every FILE marker below with that file's contents.
# No `set -e`: a failing step must be recorded and provisioning must continue,
# so a single hiccup cannot leave the learner with a half-built project or
# root-owned files.
set -uo pipefail

LOG_DIR="/var/log/thistledown-lab"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp/thistledown-lab"
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
PROJ="${LAB_HOME}/thistledown-mill"
PKG="${PROJ}/mill"
DATA_DIR="${PROJ}/data"
SVC="/opt/thistledown-svc"
PORT=8433

svc_healthy() {
    python3 - "$PORT" <<'PROBE' >/dev/null 2>&1
import sys, urllib.request
urllib.request.urlopen("http://127.0.0.1:%s/health" % sys.argv[1], timeout=2).read()
PROBE
}

note "Thistledown Mill setup starting; full log at ${LOG}"

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
# Only python3 is needed to hand over a usable lab: it runs the planning model and
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
                > "${SITEDIR}/thistledown-user-site.pth" 2>/dev/null && break
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
# crewai is a large install - several hundred megabytes of wheels - which is
# exactly why it is here and not in the foreground. --only-binary makes a
# wheel-less resolution fail in seconds with a readable error rather than
# starting a source build on an image with no compiler.
PINNED="crewai>=0.130,<1.0 python-dotenv"
LOOSE="crewai python-dotenv"
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
# start - crewai is slow to import the first time.
#
# This also settles whether the API the lab needs is actually there, because
# pip succeeding is not the same thing. Every crewai release the lab can use
# caps out at python <3.14, so on an image whose python is newer the pinned
# rung finds nothing and the unpinned rung resolves to a 0.11-series release
# with no crewai.tools in it. pip reports success, the readiness file appears,
# and every correct solution then fails at import for a score of zero. Exit 3
# on that so the state below says so instead of reporting a good install.
cd "$PROJ" 2>/dev/null && python3 - <<'WARM'
import sys

sys.path.insert(0, ".")
try:
    import crewai
    from crewai.tools import BaseTool  # noqa: F401
except Exception as exc:
    print("crewai is installed but unusable: %s: %s" % (type(exc).__name__, exc))
    print("crewai %s on python %s"
          % (getattr(sys.modules.get("crewai"), "__version__", "?"),
             sys.version.split()[0]))
    sys.exit(3)
try:
    from mill import millkit

    millkit.read_only().close()
    print("warm-up complete: crewai %s, %d orders"
          % (getattr(crewai, "__version__", "?"), len(millkit.order_ids())))
except Exception as exc:
    print("warm-up skipped: %s: %s" % (type(exc).__name__, exc))

WARM
[ "$?" -eq 3 ] && echo unusable > "$DEPS_STATE"

# Written last, and only once the install has resolved, so its presence means
# the state file is final and pip, curl and jq are all present.
touch "$DEPS_READY"
DEPSJOB
} > "$DEPS_JOB"
chmod 700 "$DEPS_JOB"
detach "$PIPLOG" "$DEPS_JOB"
note "runtime dependency install detached (job ${DEPS_JOB}, log ${PIPLOG})"

echo "=== [3/8] Project skeleton ==="
mkdir -p "$PKG" "$DATA_DIR" "${PROJ}/config" "${PROJ}/out"

cat > "${PKG}/__init__.py" <<'___TMFILE___'
@@FILE:app/mill/__init__.py@@
___TMFILE___

cat > "${PKG}/millkit.py" <<'___TMFILE___'
@@FILE:app/mill/millkit.py@@
___TMFILE___

cat > "${PKG}/main.py" <<'___TMFILE___'
@@FILE:app/mill/main.py@@
___TMFILE___

cat > "${DATA_DIR}/orders.json" <<'___TMFILE___'
@@FILE:app/data/orders.json@@
___TMFILE___

cat > "${PROJ}/check_local.py" <<'___TMFILE___'
@@FILE:app/check_local.py@@
___TMFILE___

cat > "/tmp/.mill_build_db.py" <<'___TMFILE___'
@@FILE:app/build_db.py@@
___TMFILE___

cat > "/tmp/.mill_tools_stub.py" <<'___TMFILE___'
@@FILE:app/mill/tools_stub.py@@
___TMFILE___

cat > "/tmp/.mill_crew_stub.py" <<'___TMFILE___'
@@FILE:app/mill/crew_stub.py@@
___TMFILE___

cat > "/tmp/.mill_agents_stub.yaml" <<'___TMFILE___'
@@FILE:app/config/agents.yaml@@
___TMFILE___

cat > "/tmp/.mill_tasks_stub.yaml" <<'___TMFILE___'
@@FILE:app/config/tasks.yaml@@
___TMFILE___

# Never clobber work in progress: the starters are only installed on a fresh
# project.
for pair in "tools.py:/tmp/.mill_tools_stub.py" "crew.py:/tmp/.mill_crew_stub.py"; do
    name="${pair%%:*}"; from="${pair#*:}"
    if [ ! -f "${PKG}/${name}" ]; then
        cp "$from" "${PKG}/${name}"
        echo "installed mill/${name} starter"
    else
        echo "mill/${name} already exists - left untouched"
    fi
done
for pair in "agents.yaml:/tmp/.mill_agents_stub.yaml" "tasks.yaml:/tmp/.mill_tasks_stub.yaml"; do
    name="${pair%%:*}"; from="${pair#*:}"
    if [ ! -f "${PROJ}/config/${name}" ]; then
        cp "$from" "${PROJ}/config/${name}"
        echo "installed config/${name} starter"
    else
        echo "config/${name} already exists - left untouched"
    fi
done
rm -f /tmp/.mill_tools_stub.py /tmp/.mill_crew_stub.py \
      /tmp/.mill_agents_stub.yaml /tmp/.mill_tasks_stub.yaml

# The mill database. Built here rather than shipped as a binary, so the pack
# carries readable source for it and the learner can rebuild it if they break
# something.
if [ ! -f "${DATA_DIR}/mill.db" ]; then
    if cap 25 python3 /tmp/.mill_build_db.py "${DATA_DIR}/mill.db"; then
        ok "built the mill database"
    else
        warn "could not build the mill database"
    fi
else
    echo "mill.db already exists - left untouched"
fi
rm -f /tmp/.mill_build_db.py

# Hand the project over immediately, before any step that could fail and leave
# these files root-owned - and therefore read-only for the learner.
run "early chown of ${PROJ}" chown -R "${LAB_USER}:${LAB_USER}" "$PROJ"
chmod -R u+rw "$PROJ" 2>/dev/null || warn "early chmod failed"
find "$PROJ" -type d -exec chmod u+x {} + 2>/dev/null || true
[ -s "${PKG}/crew.py" ] && ok "mill/crew.py in place" || warn "mill/crew.py missing"
[ -s "${DATA_DIR}/orders.json" ] && ok "order book in place" || warn "order book missing"
[ -s "${DATA_DIR}/mill.db" ] && ok "mill database in place" || warn "mill database missing"
note "project skeleton done (t+${SECONDS}s)"

echo "=== [4/8] Planning model files ==="
mkdir -p "$SVC"

cat > "${SVC}/millsvc.py" <<'___TMFILE___'
@@FILE:service/millsvc.py@@
___TMFILE___

chown -R root:root "$SVC"
chmod 700 "$SVC"
chmod 700 "${SVC}/millsvc.py"
note "planning model files written (t+${SECONDS}s)"

echo "=== [5/8] Learner state and environment ==="
# A planning run writes its note into out/, and grading runs as root, so the
# directory is created here as the learner. Every check also chowns the project
# back from an EXIT trap.
mkdir -p "${PROJ}/out" 2>/dev/null || true
run "chown out directory to ${LAB_USER}" chown -R "${LAB_USER}:${LAB_USER}" "${PROJ}/out"

# crewai asks once, per project directory, whether the user would like to see
# execution traces, and waits twenty seconds for an answer. On a graded run that
# is twenty seconds of nothing. The question is marked answered here, as the
# learner, for the one directory this lab runs in.
CREW_STATE="${LAB_HOME}/.local/share/thistledown-mill"
mkdir -p "$CREW_STATE" 2>/dev/null || true
printf '{"first_execution_done": true}' > "${CREW_STATE}/.crewai_user.json" 2>/dev/null || true
run "chown crewai state to ${LAB_USER}" chown -R "${LAB_USER}:${LAB_USER}" \
    "${LAB_HOME}/.local" 2>/dev/null

# The mill runs its planning model on this machine. These are exported for the
# learner shell; the check scripts export the same values themselves, because
# the judge is a non-login root shell and never reads a profile script.
cat > /etc/profile.d/thistledown.sh <<PROFILE
export OPENAI_API_KEY=thistledown-local
export OPENAI_API_BASE=http://127.0.0.1:${PORT}/v1
export OPENAI_BASE_URL=http://127.0.0.1:${PORT}/v1
export THISTLEDOWN_MODEL_URL=http://127.0.0.1:${PORT}/v1
export CREWAI_TRACING_ENABLED=false
export CREWAI_DISABLE_TELEMETRY=true
export OTEL_SDK_DISABLED=true
PROFILE
chmod 644 /etc/profile.d/thistledown.sh 2>/dev/null || true
ok "planning model environment written to /etc/profile.d/thistledown.sh"
note "learner state done (t+${SECONDS}s)"

echo "=== [6/8] Starting the planning model ==="
start_with_systemd() {
    command -v systemctl >/dev/null 2>&1 || return 1
    cat > /etc/systemd/system/thistledown-model.service <<UNIT
[Unit]
Description=Thistledown planning model
After=network.target

[Service]
Type=simple
Environment=THISTLEDOWN_PORT=${PORT}
ExecStart=${PYBIN} ${SVC}/millsvc.py
Restart=always
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
UNIT
    cap 15 systemctl daemon-reload >/dev/null 2>&1 || return 1
    cap 25 systemctl enable --now thistledown-model >/dev/null 2>&1 || return 1
    return 0
}

start_with_nohup() {
    if command -v systemctl >/dev/null 2>&1; then
        cap 15 systemctl disable --now thistledown-model >/dev/null 2>&1 || true
    fi
    export THISTLEDOWN_PORT="$PORT"
    detach /var/log/thistledown-model.log "$PYBIN" "${SVC}/millsvc.py"
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
    ok "planning model already running on ${PORT}"
elif start_with_systemd && wait_health; then
    ok "planning model started under systemd"
else
    echo "systemd path unavailable, falling back to a background process"
    start_with_nohup
    wait_health || warn "the planning model did not come up during setup; the check scripts start it on demand, so grading still works (see ${LOG})"
fi
if svc_healthy; then
    ok "planning model healthy on 127.0.0.1:${PORT}"
else
    warn "planning model not answering on 127.0.0.1:${PORT} at end of setup"
fi
note "planning model up (t+${SECONDS}s)"

echo "=== [7/8] Dependency hand-off ==="
DEPS_GRACE="${DEPS_GRACE:-5}"
for _i in $(seq 1 "$DEPS_GRACE"); do
    [ -f "$DEPS_READY" ] && break
    sleep 1
done
case "$(cat "$DEPS_STATE" 2>/dev/null)" in
    pinned) ok "installed the pinned crewai (>=0.130,<1.0) and python-dotenv" ;;
    series) warn "the pinned crewai range was unavailable; installed the newest crewai instead" ;;
    unusable) warn "crewai installed but crewai.tools is missing - the resolved version is too old for this lab and every check will fail; the image python is probably newer than crewai supports (see ${PIPLOG})" ;;
    failed) warn "pip install FAILED - the lab cannot run until this is fixed (see ${PIPLOG})" ;;
    *)      note "the packages are still downloading in the background (log ${PIPLOG}); the project, the order book and the model are ready now. ${DEPS_READY} appears when the install finishes, and check_local.py and the checks both wait for it." ;;
esac
tail -n 5 "$PIPLOG" 2>/dev/null | sed 's/^/    pip| /'
note "dependencies handed off (t+${SECONDS}s)"

finish_summary() {
    [ "${SUMMARY_DONE:-0}" -eq 1 ] && return 0
    SUMMARY_DONE=1
    local blockers=""
    command -v python3 >/dev/null 2>&1 || blockers="${blockers} python3-missing"
    [ -s "${PKG}/millkit.py" ] || blockers="${blockers} project-missing"
    [ -s "${DATA_DIR}/orders.json" ] || blockers="${blockers} orders-missing"
    [ -s "${DATA_DIR}/mill.db" ] || blockers="${blockers} database-missing"
    svc_healthy || blockers="${blockers} model-down"
    if [ -n "$blockers" ]; then
        warn "LAB NOT READY -${blockers}"
        note "provisioning could not finish the essentials. Re-running setup on a fresh VM is"
        note "the fastest remedy; the phase timings above show which step ran out of time."
        note "total setup time: ${SECONDS}s"
        return 0
    fi
cat <<SUMMARY

--------------------------------------------------------------------
Thistledown Mill lab is ready.

Project:   ${PROJ}
Provided:  mill/millkit.py    the database, the order book and the planning
                              model, already configured - do not modify
           mill/main.py       the entry point that runs one order
           data/mill.db       the mill database
           data/orders.json   the order book
           check_local.py     exercises your tools and runs one order
You write: config/agents.yaml
           config/tasks.yaml
           mill/tools.py
           mill/crew.py

The planning model is answering on http://127.0.0.1:${PORT} and is what the
crew talks to. Leave it running. Nothing here needs an account anywhere.

Run one order with:
    cd ${PROJ}
    python3 -m mill.main --order TM-4301
    cat out/TM-4301.md

Check your work with:
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
        note "finished early on the internal deadline; the project, the order book and the model are in place and the dependency install continues in the background"
    fi
}

echo "=== [8/8] Permissions and summary ==="
run "chown project to ${LAB_USER}" chown -R "${LAB_USER}:${LAB_USER}" "$PROJ"
run "make project writable" chmod -R u+rw "$PROJ"
find "$PROJ" -type d -exec chmod u+x {} + 2>/dev/null || warn "could not set directory execute bits"
rm -rf "${PROJ}/__pycache__" "${PKG}/__pycache__" 2>/dev/null || true
[ -w "${PKG}/crew.py" ] || warn "mill/crew.py is not writable - the learner will hit a read-only file"

finish_summary

kill "$WATCHDOG_PID" >/dev/null 2>&1 || true
sync 2>/dev/null || true
exit 0
