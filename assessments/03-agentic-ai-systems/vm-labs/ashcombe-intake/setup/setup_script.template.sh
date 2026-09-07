#!/bin/bash
# Ashcombe intake lab - VM provisioning script.
# Runs once, as root, before the learner starts.
# TEMPLATE: build.sh replaces every FILE marker below with that file's contents.
# No `set -e`: a failing step must be recorded and provisioning must continue,
# so a single hiccup cannot leave the learner with a half-built project or
# root-owned files.
set -uo pipefail

LOG_DIR="/var/log/ashcombe-lab"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp/ashcombe-lab"
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
PROJ="${LAB_HOME}/ashcombe-intake"
KIT="${PROJ}/intake_kit"
PIPE="${PROJ}/intake"
SVC="/opt/ashcombe-svc"
PORT=8777

svc_healthy() {
    python3 - "$PORT" <<'PROBE' >/dev/null 2>&1
import sys, urllib.request
urllib.request.urlopen("http://127.0.0.1:%s/health" % sys.argv[1], timeout=2).read()
PROBE
}

note "Ashcombe intake setup starting; full log at ${LOG}"

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
# Only python3 is needed to hand over a usable lab: it runs the intake desk and
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

# pip for the one wheel below; curl and jq because the check scripts use them.
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
# Only the load-bearing package is pinned, so the rest tracks whatever CPython
# the image ships. --only-binary makes a wheel-less resolution fail in seconds
# with a readable error instead of starting a source build.
# shellcheck disable=SC2086
if python3 -m pip install $PIPFLAGS "pymupdf==1.24.14"; then
    echo pinned > "$DEPS_STATE"
# shellcheck disable=SC2086
elif python3 -m pip install $PIPFLAGS "pymupdf<2"; then
    echo series > "$DEPS_STATE"
else
    echo failed > "$DEPS_STATE"
fi

# Pay the import cost once, so the first graded run is not a cold start.
cd "$PROJ" 2>/dev/null && python3 - <<'WARM'
import sys

sys.path.insert(0, ".")
try:
    import glob

    import fitz

    import intake_kit  # noqa: F401

    for sample in sorted(glob.glob("inbox/*.pdf"))[:1]:
        document = fitz.open(sample)
        for page in document:
            page.get_text()
        document.close()
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
mkdir -p "$KIT" "$PIPE" "${PROJ}/inbox" "${PROJ}/out"

cat > "${KIT}/__init__.py" <<'___ACFILE___'
@@FILE:app/intake_kit/__init__.py@@
___ACFILE___

cat > "${KIT}/client.py" <<'___ACFILE___'
@@FILE:app/intake_kit/client.py@@
___ACFILE___

cat > "${PIPE}/__init__.py" <<'___ACFILE___'
@@FILE:app/intake/__init__.py@@
___ACFILE___

cat > "${PROJ}/check_local.py" <<'___ACFILE___'
@@FILE:app/check_local.py@@
___ACFILE___

cat > "/tmp/.ac_triage_stub.py" <<'___ACFILE___'
@@FILE:app/intake/triage_stub.py@@
___ACFILE___

cat > "/tmp/.ac_chunk_stub.py" <<'___ACFILE___'
@@FILE:app/intake/chunk_stub.py@@
___ACFILE___

cat > "/tmp/.ac_worker_stub.py" <<'___ACFILE___'
@@FILE:app/intake/worker_stub.py@@
___ACFILE___

# Never clobber work in progress: the starters are only installed on a fresh
# project.
for pair in "intake/triage.py:/tmp/.ac_triage_stub.py" \
            "intake/chunk.py:/tmp/.ac_chunk_stub.py" \
            "intake/worker.py:/tmp/.ac_worker_stub.py"; do
    name="${pair%%:*}"; from="${pair#*:}"
    if [ ! -f "${PROJ}/${name}" ]; then
        cp "$from" "${PROJ}/${name}"
        echo "installed ${name} starter"
    else
        echo "${name} already exists - left untouched"
    fi
done
rm -f /tmp/.ac_triage_stub.py /tmp/.ac_chunk_stub.py /tmp/.ac_worker_stub.py

# Hand the project over immediately, before any step that could fail and leave
# these files root-owned - and therefore read-only for the learner.
run "early chown of ${PROJ}" chown -R "${LAB_USER}:${LAB_USER}" "$PROJ"
chmod -R u+rw "$PROJ" 2>/dev/null || warn "early chmod failed"
find "$PROJ" -type d -exec chmod u+x {} + 2>/dev/null || true
[ -s "${PIPE}/triage.py" ] && ok "intake/ starters in place" || warn "intake/ starters missing"
note "project skeleton done (t+${SECONDS}s)"

echo "=== [4/8] Support desk files ==="
mkdir -p "$SVC"

# The desk imports its document plans from the module beside it, so both files
# have to land here. Without corpus.py the desk dies on its first import and
# every check reports an unreachable desk.
cat > "${SVC}/corpus.py" <<'___ACFILE___'
@@FILE:service/corpus.py@@
___ACFILE___

cat > "${SVC}/intakesvc.py" <<'___ACFILE___'
@@FILE:service/intakesvc.py@@
___ACFILE___

chown -R root:root "$SVC"
chmod 700 "$SVC"
chmod 700 "${SVC}/intakesvc.py" "${SVC}/corpus.py"
if python3 -c "import sys; sys.path.insert(0, sys.argv[1]); import corpus; raise SystemExit(0 if corpus.CORPUS else 1)" "$SVC" 2>/dev/null; then
    ok "desk files written, and the document plans import"
else
    warn "the document plans at ${SVC}/corpus.py do not import - the desk cannot start"
fi
note "intake desk files written (t+${SECONDS}s)"

echo "=== [5/8] Learner state the checks touch ==="
# The check scripts drain a spool of their own under a root-only directory, so
# nothing they do writes into the project. What is pre-created here is the
# learner spool: their own runs write a ledger and artefacts, and those files
# must belong to them from the start.
SPOOL="${PROJ}/inbox"
ARTEFACTS="${PROJ}/out"
LEDGER_FILE="${PROJ}/ledger.jsonl"
mkdir -p "$SPOOL" "$ARTEFACTS" 2>/dev/null || true
[ -e "$LEDGER_FILE" ] || : > "$LEDGER_FILE" 2>/dev/null || true
run "chown spool to ${LAB_USER}" chown -R "${LAB_USER}:${LAB_USER}" \
    "$SPOOL" "$ARTEFACTS" "$LEDGER_FILE"
chmod 664 "$LEDGER_FILE" 2>/dev/null || true
note "learner state done (t+${SECONDS}s)"

echo "=== [6/8] Starting the intake desk ==="
start_with_systemd() {
    command -v systemctl >/dev/null 2>&1 || return 1
    cat > /etc/systemd/system/ashcombe-desk.service <<UNIT
[Unit]
Description=Ashcombe intake intake desk
After=network.target

[Service]
Type=simple
Environment=ASHCOMBE_PORT=${PORT}
Environment=PYTHONPATH=${SVC}
ExecStart=${PYBIN} ${SVC}/intakesvc.py
Restart=always
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
UNIT
    cap 15 systemctl daemon-reload >/dev/null 2>&1 || return 1
    cap 25 systemctl enable --now ashcombe-desk >/dev/null 2>&1 || return 1
    return 0
}

start_with_nohup() {
    if command -v systemctl >/dev/null 2>&1; then
        cap 15 systemctl disable --now ashcombe-desk >/dev/null 2>&1 || true
    fi
    export ASHCOMBE_PORT="$PORT" PYTHONPATH="$SVC"
    detach /var/log/ashcombe-desk.log "$PYBIN" "${SVC}/intakesvc.py"
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
    ok "intake desk already running on ${PORT}"
elif start_with_systemd && wait_health; then
    ok "intake desk started under systemd"
else
    echo "systemd path unavailable, falling back to a background process"
    start_with_nohup
    wait_health || warn "the intake desk did not come up during setup; the check scripts start it on demand, so grading still works (see ${LOG})"
fi
if svc_healthy; then
    ok "intake desk healthy on 127.0.0.1:${PORT}"
else
    warn "intake desk not answering on 127.0.0.1:${PORT} at end of setup"
fi
note "intake desk up (t+${SECONDS}s)"

echo "=== [7/8] Sample documents and tooling hand-off ==="
if svc_healthy; then
    SPOOL="$SPOOL" python3 - "$PORT" <<'SAMPLES' && ok "sample documents written to the spool" || warn "could not write the sample documents into the spool"
import base64, json, os, sys, urllib.request

spool = os.environ["SPOOL"]
url = "http://127.0.0.1:%s/v1/samples" % sys.argv[1]
payload = json.loads(urllib.request.urlopen(url, timeout=10).read())
written = 0
for document in payload["documents"]:
    target = os.path.join(spool, document["name"])
    if os.path.exists(target):
        continue
    with open(target, "wb") as handle:
        handle.write(base64.b64decode(document["b64"]))
    written += 1
print("wrote %d sample document(s)" % written)
SAMPLES
    chown -R "${LAB_USER}:${LAB_USER}" "$SPOOL" 2>/dev/null || true
else
    warn "the intake desk is not up, so the sample documents could not be written into the spool"
fi

DEPS_GRACE="${DEPS_GRACE:-5}"
for _i in $(seq 1 "$DEPS_GRACE"); do
    [ -f "$DEPS_READY" ] && break
    sleep 1
done
case "$(cat "$DEPS_STATE" 2>/dev/null)" in
    pinned)  ok "pymupdf installed at the pinned version, with curl and jq" ;;
    series)  ok "pymupdf installed from its current series, with curl and jq" ;;
    failed)  warn "pymupdf did not install - the lab cannot run until this is fixed (see ${DEPSLOG})" ;;
    *)       note "the grader tools are still installing in the background (log ${DEPSLOG}); the project and the intake desk are ready now" ;;
esac
tail -n 5 "$DEPSLOG" 2>/dev/null | sed 's/^/    deps| /'
note "tooling handed off (t+${SECONDS}s)"

finish_summary() {
    [ "${SUMMARY_DONE:-0}" -eq 1 ] && return 0
    SUMMARY_DONE=1
    local blockers=""
    command -v python3 >/dev/null 2>&1 || blockers="${blockers} python3-missing"
    [ -s "${PIPE}/worker.py" ] || blockers="${blockers} project-missing"
    [ -s "${KIT}/__init__.py" ] || blockers="${blockers} kit-missing"
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
Ashcombe intake lab is ready.

Project:   ${PROJ}
Provided:  intake_kit/       the document parsing API client - do not modify
           inbox/           three documents to develop against
           out/             where your artefacts go
           check_local.py   drains a scratch copy of the spool and shows the
                            ledger and the chunks it produced
You write: intake/triage.py
           intake/chunk.py
           intake/worker.py

The intake desk is answering on http://127.0.0.1:${PORT}. Leave it running.
PyMuPDF is installed for you. There is no key to set.

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
        note "finished early on the internal deadline; the project and the intake desk are in place"
    fi
}

echo "=== [8/8] Permissions and summary ==="
run "chown project to ${LAB_USER}" chown -R "${LAB_USER}:${LAB_USER}" "$PROJ"
run "make project writable" chmod -R u+rw "$PROJ"
find "$PROJ" -type d -exec chmod u+x {} + 2>/dev/null || warn "could not set directory execute bits"
rm -rf "${PROJ}/__pycache__" "${KIT}/__pycache__" "${PIPE}/__pycache__" 2>/dev/null || true
[ -w "${PIPE}/triage.py" ] || warn "intake/triage.py is not writable - the learner will hit a read-only file"

finish_summary

kill "$WATCHDOG_PID" >/dev/null 2>&1 || true
sync 2>/dev/null || true
exit 0
