#!/bin/bash
# TC04 (10 pts): the prompt primitive is advertised and fills in its argument
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

Test04() {
    ensure_deps || { deps_missing; return; }
    ensure_service || { svc_unreachable; return; }
    local out problems err canary
    canary="northfield siding QX$$-$(date +%S 2>/dev/null || echo 0)"
    # Run the learner server from a copy of the project, not the project itself:
    # a python process writes bytecode caches into the directory it starts in,
    # and this check runs as root while the project belongs to the learner.
    PROBE_CWD="$(stage_project)"
    out="$(WANT_PROMPT="transit_analyst" WANT_ARG="question" CANARY="$canary" run_probe <<'PY'
import asyncio, json, os, sys
from contextlib import AsyncExitStack
from datetime import timedelta

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

LAB = os.environ["LARKSPUR_LAB"]
WANT_PROMPT = os.environ["WANT_PROMPT"]
WANT_ARG = os.environ["WANT_ARG"]
CANARY = os.environ["CANARY"]
READ_TIMEOUT = timedelta(seconds=int(os.environ.get("LARKSPUR_MCP_WAIT") or "10"))
PAYLOAD = {"problems": ["the server did not complete an MCP handshake"], "error": "",
           "prompts": [], "rendered": ""}
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


def server_params():
    return StdioServerParameters(
        command=sys.executable,
        args=[os.path.join(LAB, "server.py")],
        env={"PATH": os.environ.get("PATH", "/usr/bin:/bin"),
             "HOME": os.environ.get("HOME", "/tmp"),
             "PYTHONDONTWRITEBYTECODE": "1",
             "LARKSPUR_SERVICE_URL": os.environ.get("LARKSPUR_SERVICE_URL", "")})


def rendered(messages):
    parts = []
    for message in messages or []:
        content = getattr(message, "content", None)
        text = getattr(content, "text", None)
        if text is None and isinstance(content, str):
            text = content
        parts.append("%s: %s" % (getattr(message, "role", "?"), text or ""))
    return "\n".join(parts)


async def main():
    problems = []
    async with AsyncExitStack() as stack:
        reader, writer = await stack.enter_async_context(stdio_client(server_params()))
        session = await stack.enter_async_context(ClientSession(reader, writer, read_timeout_seconds=READ_TIMEOUT))
        await session.initialize()
        listed = (await session.list_prompts()).prompts
        summary = [{"name": item.name,
                    "args": sorted(a.name for a in (item.arguments or []))}
                   for item in listed]
        PAYLOAD["prompts"] = summary
        match = [item for item in summary if item["name"] == WANT_PROMPT]
        if not match:
            problems.append("prompts/list does not advertise a prompt named %s "
                            "(it advertises %s)"
                            % (WANT_PROMPT, [item["name"] for item in summary]))
        elif WANT_ARG not in match[0]["args"]:
            problems.append("the %s prompt advertises arguments %s, with no %s"
                            % (WANT_PROMPT, match[0]["args"], WANT_ARG))
        result = await session.get_prompt(WANT_PROMPT, {WANT_ARG: CANARY})
        messages = getattr(result, "messages", None) or []
        body = rendered(messages)
    PAYLOAD["rendered"] = body[:600]
    if not messages:
        problems.append("prompts/get returned no messages")
    if CANARY not in body:
        problems.append("the messages prompts/get returned do not carry the %s that "
                        "was passed in" % WANT_ARG)
    PAYLOAD["problems"] = problems


try:
    asyncio.run(main())
except BaseException as exc:
    PAYLOAD["error"] = describe(exc)
with open(os.environ["LARKSPUR_OUT"], "w") as handle:
    handle.write(json.dumps(PAYLOAD))
PY
)"
    [ -z "$out" ] && { no_probe_output "The prompt in server.py could not be fetched over stdio"; return; }
    problems="$(probe_json "$out" '.problems | join("; ")' '')"
    err="$(probe_json "$out" '.error' 'none')"
    if [ -z "$problems" ]; then
        report "success" "prompts/list advertises transit_analyst with its question argument, and prompts/get returns messages that embed the argument it was given"
    else
        report "failed" "The transit_analyst prompt in server.py did not behave correctly: $problems. The prompts it advertised were $(probe_json "$out" '.prompts | @json' 'none'). The prompt must take an argument named question and the value it is given must appear in the message text it returns. What it returned: $(probe_json "$out" '.rendered' 'nothing' | tr '\n' ' ' | cut -c1-260). Error from your server: $err.$(maybe_server_said "$err")"
    fi
}
Test04
