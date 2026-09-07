#!/bin/bash
# Ashford grid operations lab - VM provisioning script.
# Runs once, as root, before the learner starts.
# TEMPLATE: build.sh replaces every FILE marker below with that file's contents.
# No `set -e`: a failing step must be recorded and provisioning must continue, so a
# single hiccup cannot leave the learner with a half-built project or root-owned files.
set -uo pipefail

LOG_DIR="/var/log/ashford-lab"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp/ashford-lab"
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
    # deadline watchdog until the command returned - measured on a sibling lab: a 4s deadline
    # fired at t+40s against a 40s step. Stepping keeps the trap responsive.
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
# setsid is the right tool and is present on the target image, but a missing setsid
# would make this a silent no-op - and a background job that never starts costs the
# whole health-wait budget before anything notices. Fall back to plain nohup.
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
PROJ="${LAB_HOME}/ashford-grid"
DATA_DIR="${PROJ}/data"
DB_FILE="${DATA_DIR}/grid_ops.db"
SVC="/opt/ashford-svc"
PORT=8836

# A stdlib HTTP server binds in well under a second, so 10s is already generous. The probe
# is python3 rather than curl so that it still works on a VM where the curl install is the
# thing that went wrong: provisioning depends on python3 anyway.
svc_healthy() {
    python3 - "$PORT" <<'PROBE' >/dev/null 2>&1
import sys, urllib.request
urllib.request.urlopen("http://127.0.0.1:%s/health" % sys.argv[1], timeout=2).read()
PROBE
}

note "Ashford grid operations setup starting; full log at ${LOG}"

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
    # Defined in phase 7, which the deadline may pre-empt. Every value it reads is set
    # above, so the only thing that can be missing is the function itself.
    if type finish_summary >/dev/null 2>&1; then finish_summary; fi
    exit 0
}
trap on_deadline USR1
( sleep "$SETUP_BUDGET"; kill -USR1 $$ 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG_PID=$!

# The portal's own front end gives up if it cannot read the lab status within its polling
# window, and that window is much tighter than the setup time limit. Three things keep
# provisioning inside it, in order of how much they matter:
#   1. every external command that can block is wrapped in `cap` (above);
#   2. the `openai` install is detached entirely in phase 2, because nothing at
#      provisioning time needs it - gridd.py and seed_db.py are pure standard library and
#      the project is just files, so the learner gets a working lab while the wheel lands
#      behind them;
#   3. a hard internal deadline that finishes early with a summary rather than being killed.
# Every phase prints t+${SECONDS}s so a real VM run shows where the time went, and that
# output is what the portal captures - the only diagnosis that survives a wiped VM.

echo "=== [1/8] Base packages ==="
export DEBIAN_FRONTEND=noninteractive
if ! id -u "$LAB_USER" >/dev/null 2>&1; then
    cap 20 useradd -m -s /bin/bash "$LAB_USER" || true
fi
# python3, curl and jq are the three the foreground must guarantee. python3 runs the
# endpoint, seeds the database and runs the learner code. curl and jq are what the grading
# checks are built out of: the platform helper composes its verdict line with jq -n, and
# every expected value a check compares against is read out of JSON with jq -r, so a VM
# without jq cannot produce a verdict at all. Leaving them to the detached job meant a
# check that started before the job finished had no way to say so, and reported the
# endpoint as unreachable instead. pip stays detached because nothing at provisioning time
# needs it. The health check below still uses python3 rather than curl, so it works even
# if the curl install is the thing that failed.
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
command -v python3 >/dev/null 2>&1 && ok "have python3" || warn "missing python3"

# curl and jq, in the foreground, bounded. Both are small and usually already on the
# image, so the common case costs one `command -v` and nothing else. When they are
# missing, one capped install attempt is worth the seconds: a check that cannot run jq
# cannot report a score, and the learner sees an empty panel rather than a diagnosis.
# The detached job installs them again, which is idempotent and covers the case where
# this attempt failed on a dpkg lock that has since cleared.
MISSING_TOOLS=""
command -v curl >/dev/null 2>&1 || MISSING_TOOLS="${MISSING_TOOLS} curl"
command -v jq   >/dev/null 2>&1 || MISSING_TOOLS="${MISSING_TOOLS} jq"
if [ -n "$MISSING_TOOLS" ]; then
    note "installing the grading tools the checks need:${MISSING_TOOLS}"
    # shellcheck disable=SC2086
    cap 45 apt-get install -y -qq --no-install-recommends ${APT_OPTS:--o DPkg::Lock::Timeout=30} $MISSING_TOOLS \
        || note "foreground install of${MISSING_TOOLS} did not finish; the detached job retries it"
fi
for tool in curl jq; do
    command -v "$tool" >/dev/null 2>&1 && ok "have $tool" \
        || warn "missing $tool - the grading checks need it to reach the endpoint and read its JSON; the detached job retries the install (see ${LOG_DIR}/pip.log)"
done
# Resolved once and used everywhere below, including in the unit file. A hardcoded
# /usr/bin/python3 is right on this image and wrong on the next one, and the failure
# it produces is a service that never starts rather than an error anybody reads.
PYBIN="$(command -v python3 || echo /usr/bin/python3)"

# Learners type `python`, not only `python3`. A symlink rather than a shell alias: an alias
# dies inside scripts and under sudo.
if command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
    ln -sf "$(command -v python3)" /usr/local/bin/python 2>/dev/null \
        && ok "python -> python3" || warn "could not link python"
fi

# The image marks its interpreter externally managed, so a plain `pip install` refuses
# under PEP 668. Written before anything runs pip, including the learner.
if [ ! -f /etc/pip.conf ]; then
    printf '[global]\nbreak-system-packages = true\ndisable-pip-version-check = true\n' \
        > /etc/pip.conf 2>/dev/null && ok "wrote /etc/pip.conf" || warn "could not write /etc/pip.conf"
fi

# `sudo` needs a password on this image, so a learner installing anything themselves lands
# in ~/.local, which root cannot import from. Bridge it with a .pth in the admin site
# directory, or their code runs while every check reports a missing module.
PYVER="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo "")"
if [ -n "$PYVER" ]; then
    for SITEDIR in "/usr/local/lib/python${PYVER}/dist-packages" "/usr/lib/python3/dist-packages"; do
        if [ -d "$SITEDIR" ]; then
            echo "${LAB_HOME}/.local/lib/python${PYVER}/site-packages" \
                > "${SITEDIR}/ashford-user-site.pth" 2>/dev/null && break
        fi
    done
fi
note "base packages done (t+${SECONDS}s)"

echo "=== [2/8] Runtime dependency (detached; the foreground never waits for it) ==="
PIPLOG="${LOG_DIR}/pip.log"
DEPS_STATE="${LOG_DIR}/deps.state"
DEPS_READY="${LOG_DIR}/deps.ready"
DEPS_JOB="${LOG_DIR}/install-deps.sh"
rm -f "$DEPS_STATE" "$DEPS_READY"

# Everything the lab needs but provisioning does not: pip and the openai wheel. Neither is
# required to hand the learner a working project, a seeded database and a running endpoint,
# and both are slow and network-bound. Keeping them here is what lets the foreground finish
# in seconds, which is what the portal is waiting on. curl and jq are retried here too,
# but the foreground has already guaranteed them: this is only the second attempt for a VM
# where the first one lost a dpkg lock.
#
# Written to disk with a generated header, then a quoted body: the header carries the few
# values that must be expanded now, and nothing in the body needs escaping.
{
    echo '#!/bin/bash'
    echo '# GENERATED by the setup script - installs what the lab needs after provisioning'
    echo '# has already returned, then publishes a readiness sentinel.'
    echo "DEPS_STATE=\"${DEPS_STATE}\""
    echo "DEPS_READY=\"${DEPS_READY}\""
    echo "PROJ=\"${PROJ}\""
    echo "PORT=\"${PORT}\""
    echo "DB_FILE=\"${DB_FILE}\""
    cat <<'DEPSJOB'
# PYTHONDONTWRITEBYTECODE keeps this from dropping root-owned __pycache__ into the
# learner's project after phase 8 has already handed it over.
export PYTHONDONTWRITEBYTECODE=1
export DEBIAN_FRONTEND=noninteractive
APT_OPTS="-o DPkg::Lock::Timeout=60"

# pip for the wheel below. curl and jq are already installed by the foreground; this is
# the idempotent retry for the case where that attempt lost a dpkg lock.
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

# Only the load-bearing library is pinned, and --only-binary makes a wheel-less
# resolution fail in seconds with a readable error rather than starting a source build on
# an image with no compiler. The ladder records which rung fired, so a version drift shows
# up in the setup status instead of as a mystery failure weeks later.
# shellcheck disable=SC2086
if python3 -m pip install $PIPFLAGS "openai==3.1.0"; then
    echo pinned > "$DEPS_STATE"
# shellcheck disable=SC2086
elif python3 -m pip install $PIPFLAGS openai; then
    echo latest > "$DEPS_STATE"
else
    echo failed > "$DEPS_STATE"
fi

# Pay the import and first-request cost so the first graded run is not a cold start.
cd "$PROJ" 2>/dev/null && ASHFORD_DB="$DB_FILE" python3 - <<'WARM'
import os
import sys

sys.path.insert(0, ".")
try:
    from openai import OpenAI  # noqa: F401

    from grid_kit import (CRITIQUE_SYSTEM_PROMPT, MODEL, execute_sql,
                          make_client, schema_summary)

    schema_summary()
    execute_sql("SELECT COUNT(*) AS feeders FROM feeders")
    client = make_client()
    client.chat.completions.create(
        model=MODEL, temperature=0.0,
        messages=[{"role": "system", "content": CRITIQUE_SYSTEM_PROMPT},
                  {"role": "user",
                   "content": "Candidate SQL: SELECT COUNT(*) FROM feeders"}])
    print("warm-up complete")
except Exception as exc:
    print("warm-up skipped: %s: %s" % (type(exc).__name__, exc))

WARM

# Written last, and only after the install has resolved, so its presence means the state
# file is final and openai is importable. The checks gate on THIS file, never on whether
# curl and jq exist: those are guaranteed by the foreground, so using them as a proxy for
# "the wheel has landed" would be true from the first second and would make a check blame
# the learner for a library that is not there yet.
touch "$DEPS_READY"
DEPSJOB
} > "$DEPS_JOB"
chmod +x "$DEPS_JOB"
detach "$PIPLOG" "$DEPS_JOB"
note "runtime dependency install detached (job ${DEPS_JOB}, log ${PIPLOG})"

echo "=== [3/8] Project skeleton ==="
mkdir -p "${PROJ}/grid_kit" "$DATA_DIR"

cat > "${PROJ}/grid_kit/__init__.py" <<'___AGFILE___'
@@FILE:app/grid_kit/__init__.py@@
___AGFILE___

cat > "${PROJ}/grid_kit/client.py" <<'___AGFILE___'
@@FILE:app/grid_kit/client.py@@
___AGFILE___

cat > "${PROJ}/grid_kit/db.py" <<'___AGFILE___'
@@FILE:app/grid_kit/db.py@@
___AGFILE___

cat > "${PROJ}/grid_kit/handlers.py" <<'___AGFILE___'
@@FILE:app/grid_kit/handlers.py@@
___AGFILE___

cat > "${PROJ}/grid_kit/persona.py" <<'___AGFILE___'
@@FILE:app/grid_kit/persona.py@@
___AGFILE___

cat > "${PROJ}/grid_kit/prompts.py" <<'___AGFILE___'
@@FILE:app/grid_kit/prompts.py@@
___AGFILE___

cat > "${PROJ}/grid_kit/tools.py" <<'___AGFILE___'
@@FILE:app/grid_kit/tools.py@@
___AGFILE___

cat > "${PROJ}/check_local.py" <<'___AGFILE___'
@@FILE:app/check_local.py@@
___AGFILE___

cat > "/tmp/.ashford_stub.py" <<'___AGFILE___'
@@FILE:app/solution_stub.py@@
___AGFILE___

# Never clobber work in progress: the stub is only installed on a fresh project.
if [ ! -f "${PROJ}/solution.py" ]; then
    cp /tmp/.ashford_stub.py "${PROJ}/solution.py"
    echo "installed solution.py stub"
else
    echo "solution.py already exists - left untouched"
fi
rm -f /tmp/.ashford_stub.py

# Hand the project to the learner immediately, before any step that could fail
# and leave these files root-owned (and therefore read-only for them).
run "early chown of ${PROJ}" chown -R "${LAB_USER}:${LAB_USER}" "$PROJ"
chmod -R u+rw "$PROJ" 2>/dev/null || warn "early chmod failed"
find "$PROJ" -type d -exec chmod u+x {} + 2>/dev/null || true
[ -s "${PROJ}/solution.py" ] && ok "solution.py in place" || warn "solution.py missing or empty"
note "project skeleton done (t+${SECONDS}s)"

echo "=== [4/8] Model endpoint files ==="
mkdir -p "$SVC"

cat > "${SVC}/gridd.py" <<'___AGFILE___'
@@FILE:service/gridd.py@@
___AGFILE___

cat > "${SVC}/seed_db.py" <<'___AGFILE___'
@@FILE:service/seed_db.py@@
___AGFILE___

chown -R root:root "$SVC"
chmod 700 "$SVC"
chmod 700 "${SVC}/gridd.py" "${SVC}/seed_db.py"

echo "=== [5/8] Grid operations database ==="
# Grading runs as root, and opening a SQLite file creates it. Seeding it here as part of
# provisioning, then chowning the file AND its parent directory to the learner, means the
# first toucher afterwards writes into something the learner already owns. Owning the
# parent is the half that is easy to forget and the half that decides whether the learner
# can add anything beside it.
if [ ! -f "$DB_FILE" ]; then
    if cap 30 python3 "${SVC}/seed_db.py" "$DB_FILE"; then
        ok "seeded ${DB_FILE}"
    else
        warn "could not seed ${DB_FILE} - the lab cannot answer any question until this is fixed"
    fi
else
    ok "database already present - left untouched"
fi
run "chown database to ${LAB_USER}" chown -R "${LAB_USER}:${LAB_USER}" "$DATA_DIR"
chmod 755 "$DATA_DIR" 2>/dev/null || true
chmod 644 "$DB_FILE" 2>/dev/null || true
note "database ready (t+${SECONDS}s)"

echo "=== [6/8] Starting the model endpoint ==="
start_with_systemd() {
    command -v systemctl >/dev/null 2>&1 || return 1
    cat > /etc/systemd/system/ashford-gridd.service <<UNIT
[Unit]
Description=Ashford grid operations model endpoint
After=network.target

[Service]
Type=simple
Environment=ASHFORD_DB=${DB_FILE}
Environment=ASHFORD_PORT=${PORT}
ExecStart=${PYBIN} ${SVC}/gridd.py
Restart=always
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
UNIT
    cap 15 systemctl daemon-reload >/dev/null 2>&1 || return 1
    cap 25 systemctl enable --now ashford-gridd >/dev/null 2>&1 || return 1
    return 0
}

start_with_nohup() {
    # If a unit was created and is flapping, stop it first: Restart=always plus a second
    # copy of the endpoint means two processes fighting for the same port.
    if command -v systemctl >/dev/null 2>&1; then
        cap 15 systemctl disable --now ashford-gridd >/dev/null 2>&1 || true
    fi
    export ASHFORD_DB="$DB_FILE" ASHFORD_PORT="$PORT"
    detach /var/log/ashford-gridd.log "$PYBIN" "${SVC}/gridd.py"
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
    # Only ever spend the health-wait budget on something that was actually started. The
    # obvious ordering - start, ignore the result, then wait - burns the whole wait against
    # a server that never launched on any image where systemctl is missing, and only then
    # tries the fallback that does launch it.
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

echo "=== [7/8] Dependency hand-off ==="
# A short, bounded grace period. On a warm or fast machine the detached job has already
# finished by now, so setup still exits with everything in place. What this must never do
# is wait for the slow case: that is what puts the total over the limit.
DEPS_GRACE="${DEPS_GRACE:-5}"
for _i in $(seq 1 "$DEPS_GRACE"); do
    [ -f "$DEPS_READY" ] && break
    sleep 1
done
case "$(cat "$DEPS_STATE" 2>/dev/null)" in
    pinned) ok "installed pinned openai" ;;
    latest) warn "the pinned openai version was unavailable; installed the latest instead" ;;
    failed) warn "pip install of openai FAILED - the lab cannot run until this is fixed (see ${PIPLOG})" ;;
    *)      note "the dependency is still downloading in the background (log ${PIPLOG}); the project, the database and the endpoint are ready now. ${DEPS_READY} appears when the install finishes, and check_local.py and the checks both wait for it." ;;
esac
tail -n 5 "$PIPLOG" 2>/dev/null | sed 's/^/    pip| /'
if [ -f "$DEPS_READY" ]; then
    grep -q 'warm-up complete' "$PIPLOG" 2>/dev/null && ok "warm-up complete" || true
fi
note "dependency handed off (t+${SECONDS}s)"

finish_summary() {
    # Emitted on the normal path and on the deadline path alike, so the portal's own
    # captured output always ends with a verdict. That output is the only diagnosis
    # that survives a VM the portal wipes after a failed attempt.
    [ "${SUMMARY_DONE:-0}" -eq 1 ] && return 0
    SUMMARY_DONE=1
    # Lead with an honest verdict. The block below is fixed text that says the lab is
    # ready, and on the deadline path it can be reached with apt having failed and python3
    # missing - in which case nothing works and saying "ready" would be actively
    # misleading.
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
Ashford grid operations lab is ready.

Project:   ${PROJ}
Provided:  grid_kit/       (configured client, database connection, persona,
                            system prompts, the three SQL tools, the four desks
                            - do not modify)
           data/grid_ops.db (the grid operations database)
           check_local.py  (prints what your functions return)
You write: solution.py

The model endpoint is running on http://127.0.0.1:${PORT} and is what the provided
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
# The portal kills provisioning that runs much beyond two minutes, and its status poll
# gives up sooner than that, so the total is recorded on every run: if this creeps up, the
# apt install is the thing to look at.
note "total setup time: ${SECONDS}s"
    if [ "$DEADLINE_HIT" -eq 1 ]; then
        note "finished early on the internal deadline; the project, the database and the endpoint are in place and the dependency install continues in the background"
    fi
}

echo "=== [8/8] Permissions & summary ==="
run "chown project to ${LAB_USER}" chown -R "${LAB_USER}:${LAB_USER}" "$PROJ"
run "make project writable" chmod -R u+rw "$PROJ"
find "$PROJ" -type d -exec chmod u+x {} + 2>/dev/null || warn "could not set directory execute bits"
rm -rf "${PROJ}/__pycache__" "${PROJ}/grid_kit/__pycache__" 2>/dev/null || true
[ -w "${PROJ}/solution.py" ] || warn "solution.py is not writable - the learner will hit a read-only file"

finish_summary

# Give the tee subshell a moment to flush, then always report success: a warning
# must not fail provisioning, and the log holds everything needed to diagnose it.
kill "$WATCHDOG_PID" >/dev/null 2>&1 || true
sync 2>/dev/null || true
exit 0
