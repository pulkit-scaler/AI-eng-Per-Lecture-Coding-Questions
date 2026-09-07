#!/bin/bash
# TC02 (10 pts): tools/call does real database work and the guards hold
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "/usr/local/bin/judge/test/common.sh" 2>/dev/null || source "$DIR/common.sh" 2>/dev/null || true
type print_status >/dev/null 2>&1 || print_status() { echo "RESULT:$1 | $2"; }

# The platform helper ends by installing an ERR trap in the shell that sources it:
#     trap 'handle_script_error $LINENO $? "$BASH_COMMAND"' ERR
# An ERR trap fires on any non-zero simple command whether or not set -e is in
# effect, and that includes a deliberate "return 1" from one of the guards below.
# Its handler prints a line beginning INTERNAL_ERROR and then exits, so a second
# line lands after our verdict. The platform grades the LAST line of stdout and
# stderr combined, so the verdict is thrown away, the run is recorded as
# evaluated:false, and the learner is shown an empty "Test Case Results:" panel
# with no rows in it at all - which reads as a broken lab, not as a low score.
#
# Two lines, because they cover different halves of the same hole. Dropping the
# trap stops the handler running at all. Turning off errtrace stops the trap being
# inherited into a shell function, which is where every check below does its work:
# without that, whether the bug bites depends on the accident of which commands
# happen to sit outside a function.
trap - ERR
set +eE

# --- logging & result reporting -----------------------------------------
# Nothing below can abort the script: a check must always end in one verdict.
TC="$(basename "${BASH_SOURCE[0]}" .sh | sed 's/[^0-9]//g')"
ERRLOG="/tmp/larkspur_tc${TC}.err"
: > "$ERRLOG" 2>/dev/null || ERRLOG="/dev/null"
log() { :; }
log_verdict() { :; }
log_file() { :; }
trace_hint() { :; }
probe_log() { printf '/tmp/larkspur_probe_%s' "$1"; }

# The judge captures stdout and stderr together and grades the last line, so one
# stray notice on stderr - a job-control message, a Python warning, a killed
# background job - voids the verdict exactly the way the ERR trap did. Send this
# script stderr to a per-check file and keep stdout for the single verdict line.
# TC and ERRLOG are both set in the logging block above, so this comes after it.
exec 2>>"$ERRLOG"

LAB_DIR="${LAB_DIR:-/home/user/larkspur-transit}"
LAB_REAL="$(cd "$LAB_DIR" 2>/dev/null && pwd -P || printf '%s' "$LAB_DIR")"
SVC_URL="${SVC_URL:-http://127.0.0.1:8757}"
SVC_BIN="${SVC_BIN:-/opt/larkspur-svc/opsd.py}"
GKEY="X-Larkspur-Grader: larkspur-grader-k7q2"
PY="${PY:-python3}"
TO="$(command -v timeout || command -v gtimeout || true)"
export PYTHONDONTWRITEBYTECODE=1
# WORK is this check own scratch directory. Everything the check creates goes
# here, never into the learner project: the probe source, the probe JSON, the
# seeded probe databases, and the copy of the project that TC05 runs the learner
# code from. It is removed on the way out, so a grading run leaves the project
# byte-for-byte as the learner left it.
WORK="$(mktemp -d "/tmp/larkspur_work_${TC}_XXXXXX" 2>/dev/null || printf '/tmp/larkspur_work_%s_%s' "$TC" "$$")"
mkdir -p "$WORK" 2>/dev/null || WORK="/tmp"
PROBE_SRC="${WORK}/probe.py"
PROBE_OUT="${WORK}/probe_out.json"

# --- time budget --------------------------------------------------------
# The portal kills a test case that runs much beyond two minutes and reports a
# blocking process instead of a score, so every wait in this script is bounded:
# at most DEPS_WAIT for the dependency sentinel, SVC_WAIT for the service, one
# RUN_BUDGET-bounded probe whose own MCP reads give up after MCP_WAIT, and at most
# six CURL_MAX grader calls. The paths are mutually exclusive: a check that gives
# up waiting for the dependencies or the service reports at once and never reaches
# the probe, so the real worst case is about 1 + 45 + 20 = 66s. A healthy VM finishes in a couple of seconds, because setup has
# already installed the wheels, warmed the import and started the service; these
# numbers only cap the pathological run. Nothing below may loop without one of
# these four constants.
SVC_WAIT=${SVC_WAIT:-12}
RUN_BUDGET=${RUN_BUDGET:-45}
CURL_MAX=${CURL_MAX:-5}
DEPS_WAIT=${DEPS_WAIT:-20}
# A server that starts but never answers would otherwise burn the whole RUN_BUDGET.
# Bounding the protocol reads turns it into an eight-second diagnosable failure and
# lets the client shut the child process down cleanly on the way out.
MCP_WAIT=${MCP_WAIT:-10}
DEPS_READY_FILE="${DEPS_READY_FILE:-/var/log/larkspur-lab/deps.ready}"

# One verdict per script, whatever happens. report() is idempotent, so the EXIT
# trap can safely supply a diagnostic failure if the body never reached one.
STATUS_SENT=0
report() {
    if [ "$STATUS_SENT" -eq 1 ]; then log "suppressed extra verdict: $1 | $2"; return 0; fi
    STATUS_SENT=1
    log "VERDICT $1 | $2"
    log_verdict "$1" "$2"
    print_status "$1" "$2"
}

# An MCP server is a child process the grader started. If the probe was killed at
# its time bound, that child can outlive it, so every check sweeps up the ones it
# is responsible for: a root-owned process whose working directory is either this
# lab or this check own work directory. Nothing the learner started can match both
# conditions. The work directory has to be in the set as well as the lab, because a
# probe that runs against the staged copy leaves its child sitting there.
kill_stray_servers() {
    command -v pgrep >/dev/null 2>&1 || return 0
    local p owner cwd work_real
    work_real="$(cd "$WORK" 2>/dev/null && pwd -P || printf '%s' "$WORK")"
    for p in $(pgrep -f 'server\.py' 2>/dev/null); do
        [ -d "/proc/$p" ] || continue
        owner="$(stat -c %U "/proc/$p" 2>/dev/null)" || continue
        [ "$owner" = "root" ] || continue
        cwd="$(readlink -f "/proc/$p/cwd" 2>/dev/null)" || continue
        case "$cwd" in
            "$LAB_REAL"|"$work_real"|"$work_real"/*) ;;
            *) continue ;;
        esac
        kill -9 "$p" >/dev/null 2>&1 || true
    done
}

on_exit() {
    local rc=$?
    log "script exiting rc=$rc"
    report "failed" "TC${TC} ended without reaching a verdict (rc=$rc)"
    kill_stray_servers
    hand_project_back
    rm -rf "$WORK" >/dev/null 2>&1 || true
    printf 'script_%s %ss\n' "$TC" "$SECONDS" >>/tmp/larkspur_timing.log 2>/dev/null || true
}

# Hand the project back to the learner whatever happened. A grading run that is
# killed at the cap, or one that returns early from a guard, still has to leave a
# VM its owner can work in.
#
# The condition is whether a learner account named "user" exists on this machine,
# NOT where LAB_DIR happens to point. Gating on the path meant the repair was dead
# code everywhere it was ever exercised: every authoring harness runs with LAB_DIR
# under /tmp, so the one line written to stop a learner being locked out of their
# own project was never once executed by a test.
#
# The prevention is WORK above: the checks write nothing into the project. This is
# the backstop for the writes the checks cannot prevent, because the learner own
# client is what spawns the MCP server and the stdio transport rebuilds the child
# environment from a fixed whitelist that PYTHONDONTWRITEBYTECODE is not on - so
# that child drops bytecode caches into the project as root.
hand_project_back() {
    id -u user >/dev/null 2>&1 || return 0
    # The case guard is still needed: an unset or empty LAB_DIR must never let
    # this chown reach /.
    case "$LAB_DIR" in
        /*/*) chown -R user:user "$LAB_DIR" >/dev/null 2>&1 || true ;;
    esac
}
trap on_exit EXIT
log "TC${TC} starting"

# The dependency install is deliberately detached from provisioning, so setup cannot be
# killed by the portal for running long. That means a check starting seconds after the VM
# came up could race the install. Wait a bounded moment for the sentinel the install job
# writes; if this VM was provisioned by an older setup script that has no sentinel, fall
# back to an import probe so a missing file can never by itself fail a check. The
# sentinel also gates curl and jq, which the detached job installs and which the
# helpers below need - so this has to run before anything that shells out to them.
#
# The order matters. The sentinel is the only thing that means "the install
# finished"; the import probe is a fallback for a VM provisioned by an older setup
# script that never writes one, and it is only consulted after the wait. "curl and
# jq are present" is never used as a proxy for the install having finished, because
# both are installed in the setup foreground and so are true from the first second
# of the VM life - a check that read them as readiness would go on to blame the
# learner code for a library that is still downloading.
#
# MISSING_DEP carries what is actually absent, so the verdict can name it.
MISSING_DEP=""
ensure_deps() {
    MISSING_DEP=""
    if [ ! -f "$DEPS_READY_FILE" ] && ! "$PY" -c 'import mcp, openai' >/dev/null 2>&1; then
        local i
        for i in $(seq 1 "$DEPS_WAIT"); do
            sleep 1
            [ -f "$DEPS_READY_FILE" ] && break
        done
    fi
    if ! "$PY" -c 'import mcp' >/dev/null 2>&1; then MISSING_DEP="mcp"; return 1; fi
    if ! "$PY" -c 'import openai' >/dev/null 2>&1; then MISSING_DEP="openai"; return 1; fi
    # Both of these are what this script itself shells out to. Absent, every value
    # it interpolates would come back empty and the verdict would read as though
    # the learner code were at fault.
    command -v curl >/dev/null 2>&1 || { MISSING_DEP="curl"; return 1; }
    command -v jq   >/dev/null 2>&1 || { MISSING_DEP="jq"; return 1; }
    return 0
}

# Bound the probe even where coreutils timeout(1) is absent (macOS has none, and a
# silently missing bound reports a stalled run as a very slow test case instead of
# killing it, which is how an unbounded run passes for a fast one during
# authoring). The fallback watchdog needs nothing but the shell.
run_bounded() {
    if [ -n "$TO" ]; then
        "$TO" -k 5 "$RUN_BUDGET" "$@"
        return $?
    fi
    "$@" &
    local pid=$! rc=0 wd
    ( sleep "$RUN_BUDGET"; kill -9 "$pid" ) >/dev/null 2>&1 &
    wd=$!
    wait "$pid"; rc=$?
    kill "$wd" >/dev/null 2>&1
    return $rc
}

ensure_service() {
    curl -sf -m "$CURL_MAX" "${SVC_URL}/health" >/dev/null 2>&1 && return 0
    [ -f "$SVC_BIN" ] || return 1
    local setsid_bin; setsid_bin="$(command -v setsid || true)"
    ${setsid_bin:+"$setsid_bin"} nohup "$PY" "$SVC_BIN" >/tmp/larkspur_svc.log 2>&1 </dev/null &
    local i
    for i in $(seq 1 "$SVC_WAIT"); do
        curl -sf -m 2 "${SVC_URL}/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

# jq on absent or malformed JSON yields an empty string or the word null, and a
# verdict built by interpolating that reads as a broken lab rather than a failed
# check. Every reader below returns a readable word instead.
oracle_json() {
    local value
    value="$(curl -sf -m "$CURL_MAX" -H "$GKEY" --get --data-urlencode "q=$1" \
        "${SVC_URL}/__grk7q2/oracle" 2>/dev/null | jq -r "$2" 2>/dev/null)"
    printf '%s' "$value"
}

trace_json() {
    local value
    value="$(curl -sf -m "$CURL_MAX" -H "$GKEY" "${SVC_URL}/__grk7q2/trace?session=$1" \
        2>/dev/null | jq -r "$2" 2>/dev/null)"
    case "$value" in
        ""|null) printf 'unknown' ;;
        *) printf '%s' "$value" ;;
    esac
}

# trace_num <session> <filter> <fallback> : the same, for a field a numeric
# comparison is about to be applied to. A word where a number belongs makes bash
# report an integer error instead of scoring the check.
trace_num() {
    local value
    value="$(curl -sf -m "$CURL_MAX" -H "$GKEY" "${SVC_URL}/__grk7q2/trace?session=$1" \
        2>/dev/null | jq -r "$2" 2>/dev/null)"
    case "$value" in
        *[!0-9]*|"") printf '%s' "$3" ;;
        *) printf '%s' "$value" ;;
    esac
}

# probe_json <json> <filter> <fallback> : read one field out of the probe output.
probe_json() {
    local value
    value="$(printf '%s' "$1" | jq -r "$2" 2>/dev/null)"
    case "$value" in
        ""|null) printf '%s' "$3" ;;
        *) printf '%s' "$value" ;;
    esac
}

trace_reset() {
    curl -sf -m "$CURL_MAX" -X POST -H "$GKEY" \
        "${SVC_URL}/__grk7q2/trace/reset?session=$1" >/dev/null 2>&1
}

# stage_project : a copy of the learner project inside WORK, and the directory the
# probe should run from.
#
# This is the prevention half of the ownership problem. Whichever directory the
# probe runs in is where Python drops bytecode caches, and the checks run as root
# while the project belongs to the learner. Worse, the write the checks most want
# to avoid is not one they can suppress: the learner OWN client is what spawns the
# MCP server, and mcp rebuilds a stdio child environment from a fixed whitelist
# that PYTHONDONTWRITEBYTECODE is not on, so that child writes .pyc files whatever
# this script exports. Running against a copy takes the project out of the blast
# radius entirely. Nothing is graded differently: the copy holds the learner own
# two files and the provided kit, and the database is named by LARKSPUR_DB.
#
# Echoes the directory to run in, falling back to the project itself if the copy
# could not be made, so a copy failure degrades to the old behaviour rather than
# failing a correct solution.
stage_project() {
    local dest="${WORK}/project"
    rm -rf "$dest" 2>/dev/null
    mkdir -p "$dest" 2>/dev/null || { printf '%s' "$LAB_DIR"; return 0; }
    if cp -R "$LAB_DIR/." "$dest/" 2>/dev/null; then
        find "$dest" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null
        printf '%s' "$dest"
    else
        printf '%s' "$LAB_DIR"
    fi
}

# run_probe : python source on stdin, runs in PROBE_CWD (the project by default),
# echoes the JSON the probe wrote to LARKSPUR_OUT. ONE interpreter start per check.
run_probe() {
    local rc log_out cwd
    log_out="$(probe_log "$TC")"
    cwd="${PROBE_CWD:-$LAB_DIR}"
    cat > "$PROBE_SRC" || return 1
    : > "$PROBE_OUT"
    # These two carry the learner-visible evidence and are read back by
    # run_evidence, so they live at a stable path that outlives WORK. They are in
    # the check own /tmp space, never under the learner project.
    : > "${log_out}.out"; : > "${log_out}.err"
    ( cd "$cwd" 2>/dev/null || exit 90
      export LARKSPUR_LAB="$cwd" LARKSPUR_OUT="$PROBE_OUT" \
             LARKSPUR_MCP_WAIT="$MCP_WAIT" PYTHONDONTWRITEBYTECODE=1
      run_bounded "$PY" "$PROBE_SRC" ) >"${log_out}.out" 2>"${log_out}.err"
    rc=$?
    log "probe exited rc=$rc (cwd=$cwd)"
    log_file "${log_out}.err"
    cat "$PROBE_OUT" 2>/dev/null
    return $rc
}

# --- evidence helpers ---------------------------------------------------
# The portal shows the learner the verdict message and nothing else, so a message
# that names a log file has handed them a dead end unless the file has something
# in it. Fold the evidence into the sentence and keep the path as a pointer after
# it, never instead of it.

# log_tail <file> : the last few lines, flattened onto one line and capped.
log_tail() {
    [ -s "$1" ] || return 0
    tail -n 3 "$1" 2>/dev/null | tr '\n' '\r' | sed 's/\r/ | /g; s/ | $//' | cut -c1-280
}

# run_evidence : what the last probe actually printed, in a sentence.
#
# Two files matter here and they are not interchangeable. A traceback from the
# learner client lands on the probe own stderr; so does a traceback from their MCP
# SERVER, because the stdio transport forwards the child stderr to the parent. So a
# server that dies on import is diagnosable - but only if the message carries it.
# When both files are empty the process really did print nothing, and saying so is
# the only honest thing to report.
run_evidence() {
    local err out tail_err tail_out
    err="$(probe_log "$TC").err"
    out="$(probe_log "$TC").out"
    tail_err="$(log_tail "$err")"
    tail_out="$(log_tail "$out")"
    if [ -n "$tail_err" ]; then
        printf 'it printed this: %s [full output in %s]' "$tail_err" "$err"
    elif [ -n "$tail_out" ]; then
        printf 'it printed this on stdout: %s [full output in %s]' "$tail_out" "$out"
    else
        printf 'it printed nothing at all, so %s is empty. A module that only defines functions and never runs exits quietly like this: check that server.py really ends in a stdio entry point under an if __name__ == "__main__" guard, and that importing solution.py raises nothing' "$err"
    fi
}

no_probe_output() {
    report "failed" "$1. The check ran your code and got no result back, and $(run_evidence)"
}

# server_said : the tail of the MCP server own stderr.
#
# This is the piece that is easy to lose. When a learner server dies on import, the
# client sees only an anyio ExceptionGroup; the actual traceback went to the SERVER
# stderr, which the stdio transport forwards to the probe stderr and run_probe
# captures. Splice this into a verdict whenever the probe reported an error, so the
# real cause travels with the failure instead of sitting in a file.
server_said() {
    local tail_err
    tail_err="$(log_tail "$(probe_log "$TC").err")"
    if [ -n "$tail_err" ]; then
        printf ' What your server printed on its stderr: %s' "$tail_err"
    else
        printf ' Your server printed nothing on its stderr, so there is no traceback to show: either it never started, or it started and never answered. Check that server.py ends in mcp.run(transport=stdio) under an if __name__ guard, and that nothing in the file blocks or writes to stdout before that - stdout is the protocol channel, so a stray print corrupts it.'
    fi
}

# Only when something actually went wrong on the wire.
maybe_server_said() {
    case "$1" in
        ""|none) return 0 ;;
        *) server_said ;;
    esac
}

# Guard: an unreadable expected value must never silently match an empty result.
# This is an environment fault too - the check could not work out what the right
# answer was, so it has not looked at the learner code yet.
require_expected() {
    case "$1" in
        ""|null|unknown)
            report "failed" "This VM is not ready to be graded: the check could not read the expected result from the operations endpoint on ${SVC_URL}, so it never got as far as running your code. Nothing is wrong with server.py or solution.py. Confirm the endpoint answers with: curl -s ${SVC_URL}/health"
            return 1 ;;
    esac
    return 0
}


# An environment fault, not a fault in the learner code. Name the thing that is
# missing and the log that records why it is missing, so nobody spends an hour
# reading their own server.
deps_missing() {
    report "failed" "This VM is not ready to be graded: ${MISSING_DEP:-a lab dependency} is not installed, so the check could not run your code at all. Nothing is wrong with server.py or solution.py. The install log is /var/log/larkspur-lab/pip.log and /var/log/larkspur-lab/deps.ready appears when the install finishes; wait for that file and submit again."
}

svc_unreachable() {
    report "failed" "This VM is not ready to be graded: the operations endpoint on ${SVC_URL} did not answer within ${SVC_WAIT}s, so the check could not run your code. Nothing is wrong with server.py or solution.py. Check it with: curl -s ${SVC_URL}/health"
}

Test02() {
    ensure_deps || { deps_missing; return; }
    ensure_service || { svc_unreachable; return; }
    local out problems err seed
    seed="$$"
    # Run the learner server from a copy of the project, not the project itself:
    # a python process writes bytecode caches into the directory it starts in,
    # and this check runs as root while the project belongs to the learner.
    PROBE_CWD="$(stage_project)"
    out="$(SEED="$seed" BLOCKED="stops" PROBE_TABLE="vehicles" run_probe <<'PY'
import asyncio, json, os, sqlite3, sys, tempfile
from contextlib import AsyncExitStack
from datetime import timedelta

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

LAB = os.environ["LARKSPUR_LAB"]
BLOCKED = os.environ["BLOCKED"]
TABLE = os.environ["PROBE_TABLE"]
SEED = int(os.environ.get("SEED") or "1") % 23
READ_TIMEOUT = timedelta(seconds=int(os.environ.get("LARKSPUR_MCP_WAIT") or "10"))
PAYLOAD = {"problems": ["the server did not complete an MCP handshake"], "error": "",
           "seen": {}}
def describe(exc):
    # anyio raises an ExceptionGroup when a task group fails, and its str() is only
    # "unhandled errors in a TaskGroup (1 sub-exception)". The cause a learner needs,
    # a ModuleNotFoundError from their own import for instance, is in the
    # sub-exceptions, so walk into them and report the chain.
    parts = []
    pending = [exc]
    while pending and len(parts) < 6:
        item = pending.pop(0)
        parts.append("%s: %s" % (type(item).__name__, item))
        subs = getattr(item, "exceptions", None) or []
        pending.extend(list(subs)[:3])
    return (" <- ".join(parts))[:400]

SCHEMA = [
    "CREATE TABLE routes (route_id INTEGER PRIMARY KEY, code TEXT, name TEXT,"
    " mode TEXT, zone TEXT, length_km REAL)",
    "CREATE TABLE vehicles (vehicle_id INTEGER PRIMARY KEY, fleet_no TEXT,"
    " depot TEXT, model TEXT, capacity INTEGER, in_service INTEGER, livery TEXT)",
    "CREATE TABLE trips (trip_id INTEGER PRIMARY KEY, route_code TEXT,"
    " fleet_no TEXT, service_day TEXT, boardings INTEGER, delay_min REAL)",
    "CREATE TABLE %s (stop_id INTEGER PRIMARY KEY, name TEXT, zone TEXT)" % BLOCKED,
]


def build(path):
    # A database the learner has never seen: extra column, seeded numbers, and one
    # table that exists in the file but is not on the published allowlist. Nothing
    # here can be answered from memory of the bundled copy.
    conn = sqlite3.connect(path)
    try:
        for statement in SCHEMA:
            conn.execute(statement)
        conn.executemany(
            "INSERT INTO routes VALUES (?,?,?,?,?,?)",
            [(i, "R%d" % i, "Route %d" % i, "bus" if i % 2 else "tram",
              "zone-%d" % (i % 3), 3.0 + i) for i in range(1, 6 + SEED % 3)])
        conn.executemany(
            "INSERT INTO vehicles VALUES (?,?,?,?,?,?,?)",
            [(i, "W-%d" % (300 + i), "Northfield", "Corvid-40",
              31 + SEED + i * 7, 1 if i % 3 else 0,
              "heritage" if i % 4 == 0 else "standard")
             for i in range(1, 10 + SEED % 4)])
        conn.executemany(
            "INSERT INTO trips VALUES (?,?,?,?,?,?)",
            [(i, "R%d" % (1 + i % 4), "W-%d" % (300 + 1 + i % 5),
              "2026-04-%02d" % (1 + i % 9), 90 + SEED * 3 + i * 11, i % 5)
             for i in range(1, 12 + SEED % 5)])
        conn.commit()
    finally:
        conn.close()


def facts(path):
    conn = sqlite3.connect(path)
    try:
        tables = [r[0] for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type = ? AND name NOT LIKE ? "
            "ORDER BY name", ("table", "sqlite_%")).fetchall()]
        columns = [r[1] for r in conn.execute(
            "PRAGMA table_info(%s)" % TABLE).fetchall()]
        total = conn.execute(
            "SELECT SUM(capacity) FROM vehicles WHERE in_service = 1").fetchone()[0]
        trips = conn.execute("SELECT COUNT(*) FROM trips").fetchone()[0]
    finally:
        conn.close()
    return tables, columns, str(total), trips


def text_of(result):
    parts = []
    for block in getattr(result, "content", None) or []:
        value = getattr(block, "text", None)
        if value is not None:
            parts.append(str(value))
    return "\n".join(parts)


def server_params(db):
    return StdioServerParameters(
        command=sys.executable,
        args=[os.path.join(LAB, "server.py")],
        env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
             "HOME": os.environ.get("HOME", "/tmp"),
             "PYTHONDONTWRITEBYTECODE": "1",
             "LARKSPUR_SERVICE_URL": os.environ.get("LARKSPUR_SERVICE_URL", ""),
             "LARKSPUR_DB": db})


async def main(db):
    tables, columns, total, trips_before = facts(db)
    problems = []
    seen = {}
    async with AsyncExitStack() as stack:
        reader, writer = await stack.enter_async_context(
            stdio_client(server_params(db)))
        session = await stack.enter_async_context(ClientSession(reader, writer, read_timeout_seconds=READ_TIMEOUT))
        await session.initialize()

        listed = text_of(await session.call_tool("list_tables", {}))
        seen["list_tables"] = listed[:400]
        for name in tables:
            if name not in listed:
                problems.append("list_tables did not report the table %s" % name)

        described = text_of(await session.call_tool(
            "get_table_schema", {"table_name": TABLE}))
        seen["schema"] = described[:600]
        for column in columns:
            if column not in described:
                problems.append("get_table_schema(%s) did not report the column %s"
                                % (TABLE, column))

        query = "SELECT SUM(capacity) AS total FROM vehicles WHERE in_service = 1"
        ran = text_of(await session.call_tool("execute_sql", {"query": query}))
        seen["query"] = ran[:300]
        if total not in ran:
            problems.append("execute_sql returned %r for the seeded fleet total, "
                            "expected it to carry %s" % (ran[:120], total))

        # The blocked table really exists in this file, so the only thing standing
        # between the caller and its schema is the allowlist. A refusal means the
        # column that identifies it never comes back, and that something came back
        # instead of silence.
        refused = await session.call_tool("get_table_schema", {"table_name": BLOCKED})
        refused_text = text_of(refused)
        refused_flag = getattr(refused, "isError", False) is True
        seen["blocked"] = "isError=%s %s" % (refused_flag, refused_text[:200])
        if "stop_id" in refused_text:
            problems.append("get_table_schema(%s) handed back the schema of a table "
                            "that is not published: %r" % (BLOCKED, refused_text[:160]))
        elif not refused_flag and not refused_text.strip():
            problems.append("get_table_schema(%s) returned nothing at all rather "
                            "than a refusal" % BLOCKED)

        write = await session.call_tool(
            "execute_sql", {"query": "DELETE FROM trips WHERE trip_id = 3"})
        write_text = text_of(write)
        write_flag = getattr(write, "isError", False) is True
        seen["write"] = "isError=%s %s" % (write_flag, write_text[:200])
        if not write_flag and not write_text.strip():
            problems.append("the data-modifying query returned nothing at all "
                            "rather than a refusal")

        after = text_of(await session.call_tool(
            "execute_sql", {"query": "SELECT COUNT(*) AS n FROM trips"}))
        seen["count_after"] = after[:200]
        if str(trips_before) not in after:
            problems.append("the session stopped answering after the refusals: a "
                            "count of trips returned %r instead of %s"
                            % (after[:120], trips_before))

    conn = sqlite3.connect(db)
    try:
        trips_now = conn.execute("SELECT COUNT(*) FROM trips").fetchone()[0]
    finally:
        conn.close()
    if trips_now != trips_before:
        problems.append("the data-modifying query was executed: trips went from "
                        "%s rows to %s" % (trips_before, trips_now))
    PAYLOAD["seen"] = seen
    PAYLOAD["problems"] = problems


try:
    workdir = tempfile.mkdtemp(prefix="larkspur-probe-")
    target = os.path.join(workdir, "probe.db")
    build(target)
    asyncio.run(main(target))
except BaseException as exc:
    PAYLOAD["error"] = describe(exc)
with open(os.environ["LARKSPUR_OUT"], "w") as handle:
    handle.write(json.dumps(PAYLOAD))
PY
)"
    [ -z "$out" ] && { no_probe_output "The three tools in server.py could not be called over stdio"; return; }
    problems="$(probe_json "$out" '.problems | join("; ")' '')"
    err="$(probe_json "$out" '.error' 'none')"
    if [ -z "$problems" ]; then
        report "success" "tools/call did real database work - the live table set, the real columns of vehicles, a value only the database can produce - and both guards refused their input without executing it or dropping the session"
    else
        report "failed" "The three tools in server.py did not behave correctly when called over MCP: $problems. Each tool must return what the matching transit_kit function returns, and a ValueError from one of the provided guards must travel back as an error in the tool result without ending the session. Error from your server: $err.$(maybe_server_said "$err") What the tools actually returned: $(probe_json "$out" '.seen | @json' 'nothing')"
    fi
}
Test02
