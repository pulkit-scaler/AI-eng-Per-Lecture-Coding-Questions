#!/bin/bash
# Larkspur Transit MCP lab - VM provisioning script.
# Runs once, as root, before the learner starts.
# TEMPLATE: build.sh replaces every FILE marker below with that file's contents.
# No `set -e`: a failing step must be recorded and provisioning must continue, so a
# single hiccup cannot leave the learner with a half-built project or root-owned files.
set -uo pipefail

LOG_DIR="/var/log/larkspur-lab"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp/larkspur-lab"
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

note "Larkspur Transit setup starting; full log at ${LOG}"

# Hard internal deadline. Every individual step is capped above, so this is a backstop
# against them accumulating. On expiry the script prints its summary and exits 0 rather
# than being killed: the portal then shows a provisioned lab with a warning instead of a
# blocking-process error, and the learner gets a usable VM. This is the difference between
# degrading and disappearing - the project files, the database and the service are already
# in place by then, and the dependency install finishes on its own afterwards.
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

# The portal kills a setup script that runs too long, and reports a blocking process
# instead of a result - which the learner sees as a lab that would not start. Three things
# keep that from happening, in order of how much they matter:
#   1. every external command that can block is wrapped in `cap` (above);
#   2. the mcp/openai install is detached entirely in phase 2, because nothing at
#      provisioning time needs it - opsd.py is pure standard library, the database is built
#      with sqlite3 from the standard library, and the project is just files;
#   3. a hard internal deadline that finishes early with a summary rather than being killed.
# Every phase prints t+${SECONDS}s so a real VM run shows where the time went, and that
# output is what the portal captures - the only diagnosis that survives a wiped VM.

LAB_USER="user"
LAB_HOME="/home/${LAB_USER}"
PROJ="${LAB_HOME}/larkspur-transit"
SVC="/opt/larkspur-svc"
PORT=8757
SERVICE_URL="http://127.0.0.1:${PORT}"

echo "=== [1/7] Base packages ==="
export DEBIAN_FRONTEND=noninteractive
if ! id -u "$LAB_USER" >/dev/null 2>&1; then
    cap 20 useradd -m -s /bin/bash "$LAB_USER" || true
fi
# The portal's own front end gives up if it cannot read the lab status "within the expected
# time", so the foreground is stripped to the shortest path that yields a usable lab. Only
# python3 is needed to build the database, run the service and run the learner code, and pip
# is only needed by the detached dependency job, so pip stays there.
#
# curl and jq do NOT stay there. Every check shells out to both: the platform's own
# print_status builds its JSON line with `jq -n`, and every verdict message this lab emits
# interpolates `jq -r` output. If they arrive late, a check that runs early reads an empty
# string for every value it looked up and reports a failure against the learner's code for
# something that is really a half-provisioned VM. They are two small packages, so they are
# installed here, in the foreground, capped and non-fatal. The detached job installs them
# again as a retry, which is harmless because apt-get is idempotent.
# The service health check below still uses python3 rather than curl, so provisioning does
# not depend on this step having succeeded.
if ! command -v python3 >/dev/null 2>&1; then
    note "installing python3 (the only package provisioning itself needs)"
    # Take the lock contenders out of the way first. apt-daily and unattended-upgrades start
    # on a randomised delay after boot, so on some attempts they hold the dpkg lock exactly
    # when this runs and on others they do not - that intermittency is the whole signature of
    # a lab that fails once and then works.
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
# Learners type `python`, not `python3`. A symlink survives scripts and sudo; a shell alias
# would not.
if command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
    ln -sf "$(command -v python3)" /usr/local/bin/python 2>/dev/null || true
fi
# sqlite3 is in the python3 standard library on this image, but say so out loud if it is not:
# the operations database cannot be built without it.
python3 -c 'import sqlite3' >/dev/null 2>&1 && ok "sqlite3 module present" \
    || warn "python3 has no sqlite3 module - the operations database cannot be built"

# curl and jq: the two tools every check shells out to. Foreground, capped, non-fatal.
if command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1; then
    ok "have curl and jq"
else
    note "installing curl and jq (the test scripts shell out to both)"
    # shellcheck disable=SC2086
    cap 45 apt-get install -y -qq ${APT_OPTS:--o DPkg::Lock::Timeout=30} \
        --no-install-recommends curl jq >/dev/null 2>&1 || true
    if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        # shellcheck disable=SC2086
        cap 45 apt-get update -qq ${APT_OPTS:--o DPkg::Lock::Timeout=30} >/dev/null 2>&1 || true
        # shellcheck disable=SC2086
        cap 45 apt-get install -y -qq ${APT_OPTS:--o DPkg::Lock::Timeout=30} \
            --no-install-recommends curl jq >/dev/null 2>&1 || true
    fi
    command -v curl >/dev/null 2>&1 || warn "curl is missing - the test scripts cannot reach the operations endpoint"
    command -v jq   >/dev/null 2>&1 || warn "jq is missing - the test scripts cannot build a verdict line"
    command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && ok "installed curl and jq"
fi
note "base packages done (t+${SECONDS}s)"

echo "=== [2/7] Runtime dependencies (detached; the foreground never waits for them) ==="
PIPLOG="${LOG_DIR}/pip.log"
DEPS_STATE="${LOG_DIR}/deps.state"
DEPS_READY="${LOG_DIR}/deps.ready"
DEPS_JOB="${LOG_DIR}/install-deps.sh"
rm -f "$DEPS_STATE" "$DEPS_READY"

# Everything the lab needs but provisioning does not: pip, the graders curl and jq, and the
# mcp/openai wheels. None of it is required to hand the learner a working project, a seeded
# database and a running service, and all of it is network-bound. Keeping it here is what
# lets the foreground finish in seconds, which is what the portal is actually waiting on.
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
    cat <<'DEPSJOB'
# PYTHONDONTWRITEBYTECODE keeps this from dropping root-owned __pycache__ into the learner
# project after phase 7 has already handed it over.
export PYTHONDONTWRITEBYTECODE=1
export DEBIAN_FRONTEND=noninteractive
APT_OPTS="-o DPkg::Lock::Timeout=60"

pip_ready() { python3 -m pip --version >/dev/null 2>&1; }

# Fastest rung first. get-pip.py is a couple of seconds; apt python3-pip is 7s with
# --no-install-recommends and about 28s without, because the recommends drag in a whole
# compiler toolchain that nothing in a wheels-only lab needs.
if ! pip_ready; then
    python3 - <<'GETPIP' >/dev/null 2>&1 || true
import urllib.request
urllib.request.urlretrieve("https://bootstrap.pypa.io/get-pip.py", "/tmp/get-pip.py")
GETPIP
    [ -s /tmp/get-pip.py ] && python3 /tmp/get-pip.py -q >/dev/null 2>&1 || true
fi
# curl and jq are what the grader scripts shell out to; python3-pip is the fallback rung.
for attempt in 1 2; do
    if pip_ready; then
        apt-get install -y -qq $APT_OPTS --no-install-recommends curl jq && break
    else
        apt-get install -y -qq $APT_OPTS --no-install-recommends python3-pip curl jq && break
    fi
    apt-get update -qq $APT_OPTS
    sleep 3
done
pip_ready || apt-get install -y -qq $APT_OPTS --no-install-recommends python3-pip

# PEP 668 marks this image externally managed, so a plain `pip install` refuses. Write the
# flag into /etc/pip.conf as well, or the learner first pip command fails for them too.
PIPFLAGS="--quiet --disable-pip-version-check"
# Captured first rather than piped into `grep -q`: with `pipefail` set, grep exiting
# on its first match makes pip take SIGPIPE and the pipeline reports failure even
# though the flag was found.
pip_help="$(python3 -m pip install --help 2>/dev/null || true)"
if grep -q break-system-packages <<<"$pip_help"; then
    PIPFLAGS="$PIPFLAGS --break-system-packages"
    mkdir -p /etc 2>/dev/null
    if ! grep -q 'break-system-packages' /etc/pip.conf 2>/dev/null; then
        printf '[global]\nbreak-system-packages = true\n' >>/etc/pip.conf
    fi
fi

# --only-binary=:all: is load-bearing. On this image only pydantic-core and jiter are
# compiled, and both publish cp313 manylinux wheels; if a resolution ever picks something
# without one, this fails in seconds with a readable error instead of OOM-killing a source
# build on two cores.
#
# The three pins are not cosmetic, and the fallback rung has to constrain all three or it
# can land a pair that cannot work together:
#   mcp               2.x removed the mcp.server.fastmcp module this whole lab is built on,
#                     so every correct solution would fail at import.
#   pydantic-settings 2.15 warns on every FastMCP construction. On a stdio server that
#                     warning goes to the server stderr, which the client is reading, and
#                     it corrupts the stream.
#   openai            the lab calls chat.completions.create and reads
#                     response.choices[0].message.tool_calls. Leaving it unbounded let a
#                     future major release change that surface under the learner.
# shellcheck disable=SC2086
if python3 -m pip install $PIPFLAGS --only-binary=:all: \
        "mcp==1.9.4" "pydantic-settings==2.14.0" "openai==3.1.0"; then
    echo pinned > "$DEPS_STATE"
# shellcheck disable=SC2086
elif python3 -m pip install $PIPFLAGS --only-binary=:all: \
        "mcp>=1.9,<2" "pydantic-settings<2.15" "openai>=3,<4"; then
    echo latest > "$DEPS_STATE"
else
    echo failed > "$DEPS_STATE"
fi

# A no-sudo `pip install --user` lands in ~/.local, which root cannot import from - so the
# learner code would work while every check scored zero. Bridge it with a .pth in the admin
# site directory.
PYVER="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)"
if [ -n "$PYVER" ]; then
    for site in "/usr/local/lib/python${PYVER}/dist-packages" \
                "/usr/local/lib/python${PYVER}/site-packages"; do
        [ -d "$site" ] || continue
        echo "/home/user/.local/lib/python${PYVER}/site-packages" \
            >"${site}/larkspur-user-site.pth" 2>/dev/null || true
    done
fi

# Pay the import cost once, here, so the first graded check does not pay it inside the
# per-test cap. mcp is the heaviest import in this lab: measured cold it is the difference
# between a check that finishes in one second and one that finishes in three.
python3 - <<'WARM'
try:
    import openai  # noqa: F401
    from mcp import ClientSession, StdioServerParameters  # noqa: F401
    from mcp.client.stdio import stdio_client  # noqa: F401
    from mcp.server.fastmcp import FastMCP
    from mcp.server.fastmcp.prompts import base  # noqa: F401

    FastMCP("warm-up", log_level="ERROR")
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

echo "=== [3/7] Project skeleton ==="
mkdir -p "${PROJ}/transit_kit" "${PROJ}/data"

cat > "${PROJ}/transit_kit/__init__.py" <<'___LKFILE___'
@@FILE:app/transit_kit/__init__.py@@
___LKFILE___

cat > "${PROJ}/transit_kit/endpoint.py" <<'___LKFILE___'
@@FILE:app/transit_kit/endpoint.py@@
___LKFILE___

cat > "${PROJ}/transit_kit/audit.py" <<'___LKFILE___'
@@FILE:app/transit_kit/audit.py@@
___LKFILE___

cat > "${PROJ}/transit_kit/db.py" <<'___LKFILE___'
@@FILE:app/transit_kit/db.py@@
___LKFILE___

cat > "${PROJ}/transit_kit/sql_tools.py" <<'___LKFILE___'
@@FILE:app/transit_kit/sql_tools.py@@
___LKFILE___

cat > "${PROJ}/transit_kit/client_factory.py" <<'___LKFILE___'
@@FILE:app/transit_kit/client_factory.py@@
___LKFILE___

printf '%s' "$SERVICE_URL" > "${PROJ}/transit_kit/service.url"

cat > "${PROJ}/check_local.py" <<'___LKFILE___'
@@FILE:app/check_local.py@@
___LKFILE___

cat > "/tmp/.larkspur_server_stub.py" <<'___LKFILE___'
@@FILE:app/server_stub.py@@
___LKFILE___

cat > "/tmp/.larkspur_solution_stub.py" <<'___LKFILE___'
@@FILE:app/solution_stub.py@@
___LKFILE___

cat > "/tmp/.larkspur_seed_db.py" <<'___LKFILE___'
@@FILE:app/seed_db.py@@
___LKFILE___

# Never clobber work in progress: the stubs are only installed on a fresh project.
if [ ! -f "${PROJ}/server.py" ]; then
    cp /tmp/.larkspur_server_stub.py "${PROJ}/server.py"
    echo "installed server.py stub"
else
    echo "server.py already exists - left untouched"
fi
if [ ! -f "${PROJ}/solution.py" ]; then
    cp /tmp/.larkspur_solution_stub.py "${PROJ}/solution.py"
    echo "installed solution.py stub"
else
    echo "solution.py already exists - left untouched"
fi
rm -f /tmp/.larkspur_server_stub.py /tmp/.larkspur_solution_stub.py

# The operations database. Rebuilt only when it is missing or does not answer, so a
# re-run of setup heals a broken file without discarding a healthy one.
DB="${PROJ}/data/transit.db"
db_healthy() {
    python3 - "$DB" <<'DBPROBE' >/dev/null 2>&1
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
names = {r[0] for r in conn.execute(
    "SELECT name FROM sqlite_master WHERE type = ?", ("table",))}
conn.close()
assert {"routes", "vehicles", "trips"} <= names, names
DBPROBE
}
if db_healthy; then
    ok "operations database already in place"
else
    if cap 30 python3 /tmp/.larkspur_seed_db.py "$DB"; then
        ok "built the operations database"
    else
        warn "could not build the operations database at ${DB}"
    fi
fi
rm -f /tmp/.larkspur_seed_db.py

# Pre-create the bytecode cache directories, owned by the learner, so the first thing the
# learner runs is writing into a directory that is already theirs.
#
# This used to be the defence against a root-owned cache: the checks start the learner MCP
# server as root, and mcp rebuilds a stdio child environment from a fixed whitelist that
# PYTHONDONTWRITEBYTECODE is not on, so that child wrote .pyc files under the project. The
# checks no longer run anything in the project - they copy it into their own work directory
# first - and each one also chowns the project back from its EXIT trap if a learner account
# exists. These directories are now belt and braces rather than the fix.
mkdir -p "${PROJ}/__pycache__" "${PROJ}/transit_kit/__pycache__"

# Hand the project to the learner immediately, before any step that could fail
# and leave these files root-owned (and therefore read-only for them).
run "early chown of ${PROJ}" chown -R "${LAB_USER}:${LAB_USER}" "$PROJ"
chmod -R u+rw "$PROJ" 2>/dev/null || warn "early chmod failed"
find "$PROJ" -type d -exec chmod u+rwx {} + 2>/dev/null || true
[ -s "${PROJ}/solution.py" ] && ok "solution.py in place" || warn "solution.py missing or empty"
[ -s "${PROJ}/server.py" ] && ok "server.py in place" || warn "server.py missing or empty"
note "project ready (t+${SECONDS}s)"

echo "=== [4/7] Operations service ==="
mkdir -p "$SVC"

cat > "${SVC}/opsd.py" <<'___LKFILE___'
@@FILE:service/opsd.py@@
___LKFILE___

chown -R root:root "$SVC"
chmod 700 "$SVC"
chmod 700 "${SVC}/opsd.py"

echo "=== [5/7] Starting the service ==="
start_with_systemd() {
    command -v systemctl >/dev/null 2>&1 || return 1
    cat > /etc/systemd/system/larkspur-opsd.service <<'UNIT'
[Unit]
Description=Larkspur Transit operations service
After=network.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /opt/larkspur-svc/opsd.py
Restart=always
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
UNIT
    cap 15 systemctl daemon-reload >/dev/null 2>&1 || return 1
    cap 25 systemctl enable --now larkspur-opsd >/dev/null 2>&1 || return 1
    return 0
}

start_with_nohup() {
    # If a unit was created and is flapping, stop it first: Restart=always plus a second
    # copy of the server means two processes fighting for the same port.
    if command -v systemctl >/dev/null 2>&1; then
        cap 15 systemctl disable --now larkspur-opsd >/dev/null 2>&1 || true
    fi
    setsid nohup /usr/bin/python3 "${SVC}/opsd.py" \
        >/var/log/larkspur-opsd.log 2>&1 < /dev/null &
    disown || true
}

# A stdlib HTTP server binds in well under a second, so 10s is already generous.
# curl is installed by the detached job, not the foreground, so the health probe here is
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
    ok "service already running on ${PORT}"
elif start_with_systemd && wait_health; then
    ok "service started under systemd"
else
    # Only ever spend the health-wait budget on a service something actually started.
    echo "systemd path unavailable, falling back to a background process"
    start_with_nohup
    wait_health || warn "operations service did not come up during setup; the test scripts start it on demand, so grading still works (see ${LOG})"
fi
if svc_healthy; then
    ok "service healthy on 127.0.0.1:${PORT}"
else
    warn "service not answering on 127.0.0.1:${PORT} at end of setup"
fi
note "service up (t+${SECONDS}s)"

echo "=== [6/7] Dependency hand-off ==="
# A short, bounded grace period. On a warm or fast machine the detached job has already
# finished by now, so setup still exits with everything in place. What this must never do is
# wait for the slow case: that is what puts the total over the limit.
DEPS_GRACE="${DEPS_GRACE:-10}"
for _i in $(seq 1 "$DEPS_GRACE"); do
    [ -f "$DEPS_READY" ] && break
    sleep 1
done
case "$(cat "$DEPS_STATE" 2>/dev/null)" in
    pinned) ok "installed pinned mcp/pydantic-settings/openai" ;;
    latest) warn "pinned versions unavailable; installed the newest mcp below 2.0 instead" ;;
    failed) warn "pip install of mcp/openai FAILED - the lab cannot run until this is fixed (see ${PIPLOG})" ;;
    *)      note "dependencies are still downloading in the background (log ${PIPLOG}); the project, the database and the service are ready now. ${DEPS_READY} appears when the install finishes, and check_local.py and the graders both wait for it." ;;
esac
tail -n 5 "$PIPLOG" 2>/dev/null | sed 's/^/    pip| /'
if [ -f "$DEPS_READY" ]; then
    grep -q 'warm-up complete' "$PIPLOG" 2>/dev/null && ok "warm-up complete" || true
fi
note "dependencies handed off (t+${SECONDS}s)"

finish_summary() {
    # Emitted on the normal path and on the deadline path alike, so the portal own
    # captured output always ends with a verdict. That output is the only diagnosis
    # that survives a VM the portal wipes after a failed attempt.
    [ "${SUMMARY_DONE:-0}" -eq 1 ] && return 0
    SUMMARY_DONE=1
    # Lead with an honest verdict: on the deadline path this can be reached with apt having
    # failed and python3 missing, in which case saying "ready" would be actively misleading.
    local blockers=""
    command -v python3 >/dev/null 2>&1 || blockers="${blockers} python3-missing"
    [ -s "${PROJ}/solution.py" ] || blockers="${blockers} project-missing"
    [ -s "${PROJ}/data/transit.db" ] || blockers="${blockers} database-missing"
    svc_healthy || blockers="${blockers} service-down"
    if [ -n "$blockers" ]; then
        warn "LAB NOT READY -${blockers}"
        note "provisioning could not finish the essentials. Re-running setup on a fresh VM is"
        note "the fastest remedy; the phase timings above show which step ran out of time."
        note "total setup time: ${SECONDS}s"
        return 0
    fi
cat <<SUMMARY

--------------------------------------------------------------------
Larkspur Transit MCP lab is ready.

Project:   ${PROJ}
Provided:  transit_kit/       (database access, the three SQL functions,
                               a configured client for the local model
                               endpoint - do not modify)
           data/transit.db    (the operations database)
           check_local.py     (prints what your server and client produce)
You write: server.py   - the MCP server
           solution.py - the MCP client and the agent loop

The operations service is running on ${SERVICE_URL} and backs the provided
model client. Leave it running.

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
# The portal kills provisioning that runs much beyond two minutes, so the total is
# recorded on every run: if this creeps up, the pip install is the thing to look at.
note "total setup time: ${SECONDS}s (portal limit is ~120s)"
    if [ "$DEADLINE_HIT" -eq 1 ]; then
        note "finished early on the internal deadline; the project, the database and the service are in place and the dependency install continues in the background"
    fi
}

echo "=== [7/7] Permissions & summary ==="
run "chown project to ${LAB_USER}" chown -R "${LAB_USER}:${LAB_USER}" "$PROJ"
run "make project writable" chmod -R u+rw "$PROJ"
find "$PROJ" -type d -exec chmod u+rwx {} + 2>/dev/null || warn "could not set directory execute bits"
[ -w "${PROJ}/solution.py" ] || warn "solution.py is not writable - the learner will hit a read-only file"
[ -w "${PROJ}/server.py" ] || warn "server.py is not writable - the learner will hit a read-only file"

finish_summary

# Give the tee subshell a moment to flush, then always report success: a warning
# must not fail provisioning, and the log holds everything needed to diagnose it.
kill "$WATCHDOG_PID" >/dev/null 2>&1 || true
sync 2>/dev/null || true
exit 0
