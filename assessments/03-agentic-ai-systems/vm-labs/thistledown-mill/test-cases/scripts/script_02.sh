#!/bin/bash
# TC02 (10 pts): nothing but a plain SELECT reaches the database
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "/usr/local/bin/judge/test/common.sh" 2>/dev/null || source "$DIR/common.sh" 2>/dev/null || true
type print_status >/dev/null 2>&1 || print_status() { echo "RESULT:$1 | $2"; }

# The platform helper installs `trap ... ERR`, which fires on ANY non-zero
# command regardless of set -e - including a deliberate `return 1` from a guard.
# Its handler posts an internal error and exits, landing a second line after our
# verdict; the judge grades the LAST line, so the verdict is discarded and the
# submission reports no test cases at all. Drop the inherited trap.
trap - ERR
set +eE

# --- one verdict per script -------------------------------------------------
# Nothing below may abort the script: a check must always end in exactly one
# verdict, so there is no set -e and no set -u anywhere in this file.
TC="$(basename "${BASH_SOURCE[0]}" .sh | sed 's/[^0-9]//g')"

# The judge captures stdout+stderr together and grades the LAST line, so a
# single stray line on stderr - a bash job-control notice, a tool warning -
# would void the verdict the same way the ERR trap did. Send this check's
# stderr to a file on the VM: diagnostics stay available, and stdout can only
# ever end in the verdict.
exec 2>>"/tmp/thistledown_tc${TC}.err"
STATUS_SENT=0
report() {
    if [ "$STATUS_SENT" -eq 1 ]; then return 0; fi
    STATUS_SENT=1
    print_status "$1" "$2"
}

LAB_DIR="${LAB_DIR:-/home/user/thistledown-mill}"
MODEL_URL="${MODEL_URL:-http://127.0.0.1:8433}"
MODEL_BIN="${MODEL_BIN:-/opt/thistledown-svc/millsvc.py}"
GKEY="X-Grader-Key: thistledown-grader-tm8q"
GPATH="__tm8q"
PY="${PY:-python3}"
DEPS_READY_FILE="${DEPS_READY_FILE:-/var/log/thistledown-lab/deps.ready}"
TIMING_LOG="${TIMING_LOG:-/tmp/thistledown_timing.log}"
export PYTHONDONTWRITEBYTECODE=1
# The mill runs its planning model locally and its runs are not interactive.
# Exported here as well as in the learner profile, because the judge is a
# non-login root shell and will not read a profile script.
export CREWAI_TRACING_ENABLED=false
export CREWAI_DISABLE_TELEMETRY=true
export OTEL_SDK_DISABLED=true
export THISTLEDOWN_MODEL_URL="${MODEL_URL}/v1"
export OPENAI_API_KEY="${OPENAI_API_KEY:-thistledown-local}"
export OPENAI_API_BASE="${MODEL_URL}/v1"
export OPENAI_BASE_URL="${MODEL_URL}/v1"

# --- time budget -----------------------------------------------------------
# crewai is a heavy import - several seconds cold - and a planning run is two or
# three model turns on top of that. HARD_DEADLINE is a ceiling on the whole
# script, and every learner invocation shrinks its own bound as that deadline
# approaches, so a check that runs two jobs cannot add up past the portal cap.
CURL_MAX=${CURL_MAX:-5}
SVC_WAIT=${SVC_WAIT:-12}
DEPS_WAIT=${DEPS_WAIT:-30}
RUN_BUDGET=${RUN_BUDGET:-55}
HARD_DEADLINE=${HARD_DEADLINE:-100}

TO="$(command -v timeout || command -v gtimeout || true)"
TOK=""
if [ -n "$TO" ] && "$TO" -k 1 1 true >/dev/null 2>&1; then TOK="-k 5"; fi

bounded() {
    local secs="$1"; shift
    if [ -n "$TO" ]; then
        # shellcheck disable=SC2086
        "$TO" $TOK "$secs" "$@"
        return $?
    fi
    "$@" &
    local pid=$! rc=0 wd
    ( sleep "$secs"; kill -9 "$pid" ) >/dev/null 2>&1 &
    wd=$!
    wait "$pid"; rc=$?
    kill "$wd" >/dev/null 2>&1
    return $rc
}

spawn_detached() {
    local log="$1"; shift
    if command -v setsid >/dev/null 2>&1; then
        setsid nohup "$@" >"$log" 2>&1 </dev/null &
    else
        nohup "$@" >"$log" 2>&1 </dev/null &
    fi
    return 0
}

# Grading runs as root while the learner is user. A planning run writes into
# out/ and crewai writes a per-project data file under the learner home, so
# ownership goes back from the EXIT trap rather than from a success path.
on_exit() {
    local rc=$?
    case "$LAB_DIR" in
        /home/user/*) chown -R user:user "$LAB_DIR" >/dev/null 2>&1 ;;
    esac
    [ -d /home/user/.local/share/thistledown-mill ] && \
        chown -R user:user /home/user/.local/share/thistledown-mill >/dev/null 2>&1
    printf 'script_%s %ss\n' "$TC" "$SECONDS" >>"$TIMING_LOG" 2>/dev/null || true
    report "failed" "TC${TC} ended without reaching a verdict (rc=${rc})"
}
trap on_exit EXIT

ensure_deps() {
    [ -f "$DEPS_READY_FILE" ] && return 0
    "$PY" -c 'import crewai' >/dev/null 2>&1 && return 0
    local i
    for i in $(seq 1 "$DEPS_WAIT"); do
        sleep 1
        [ -f "$DEPS_READY_FILE" ] && return 0
    done
    "$PY" -c 'import crewai' >/dev/null 2>&1
}

ensure_model() {
    curl -sf -m "$CURL_MAX" "${MODEL_URL}/health" >/dev/null 2>&1 && return 0
    [ -f "$MODEL_BIN" ] || return 1
    spawn_detached /tmp/thistledown_model.log "$PY" "$MODEL_BIN"
    local i
    for i in $(seq 1 "$SVC_WAIT"); do
        curl -sf -m 2 "${MODEL_URL}/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

trace_field() {
    curl -sf -m "$CURL_MAX" -H "$GKEY" "${MODEL_URL}/${GPATH}/trace?run=$1" \
        2>/dev/null | jq -r "$2"
}

reset_run() {
    curl -sf -m "$CURL_MAX" -X POST -H "$GKEY" \
        "${MODEL_URL}/${GPATH}/reset?run=$1" >/dev/null 2>&1
    return 0
}

# These helpers are called inside a command substitution, which is a subshell,
# so nothing they assign survives the call. The log path is therefore derived
# from the check number alone: it is the same string on both sides, and a
# failure message can always name a file that exists.
RUN_LOG="/tmp/thistledown_tc${TC}.log"
LAST_RC=0

# The learner program never reads its source from stdin. A background job in a
# non-interactive shell has stdin on /dev/null, so a heredoc piped into
# `python3 -` arrives empty exactly when the shell has no timeout(1) and the
# watchdog path is taken - silently, on some hosts and not others. Write the
# body out and run the file.
run_python() {
    local budget="$1" tmp rc
    shift
    tmp="$(mktemp /tmp/thistledown_body_XXXXXX)" || return 1
    cat > "$tmp"
    ( cd "$LAB_DIR" 2>/dev/null && export PYTHONPATH="$LAB_DIR" \
      && bounded "$budget" "$PY" "$tmp" "$@" </dev/null ) >"$RUN_LOG" 2>&1
    rc=$?
    rm -f "$tmp"
    return $rc
}

budget_left() {
    local left
    left=$(( HARD_DEADLINE - SECONDS ))
    if [ "$left" -lt 6 ]; then echo 0; return; fi
    if [ "$left" -lt "$RUN_BUDGET" ]; then echo "$left"; else echo "$RUN_BUDGET"; fi
}

# tool_batch <json-array-of-{tool,args}> -> a JSON array of results.
# One interpreter start however many calls are in it: importing crewai costs
# several seconds on this image, and grading cost here is interpreter starts
# rather than computation.
tool_batch() {
    local budget
    budget="$(budget_left)"
    if [ "$budget" -eq 0 ]; then LAST_RC=124; return 124; fi
    run_python "$budget" "$1" <<'TOOLBODY'
import json
import sys

from mill.tools import RunQueryTool, StockLookupTool

TOOLS = {"run_query": RunQueryTool(), "stock_lookup": StockLookupTool()}
results = []
for item in json.loads(sys.argv[1]):
    tool, args = item["tool"], item.get("args") or {}
    try:
        results.append({"tool": tool, "text": str(TOOLS[tool].run(**args))})
    except NotImplementedError as exc:
        results.append({"tool": tool, "error": "not implemented",
                        "detail": str(exc)})
    except Exception as exc:
        results.append({"tool": tool, "raised": type(exc).__name__,
                        "detail": str(exc)[:200]})
print("TOOLJSON:" + json.dumps(results))
TOOLBODY
    LAST_RC=$?
    grep -o 'TOOLJSON:.*' "$RUN_LOG" 2>/dev/null | head -1 | cut -c10-
    return "$LAST_RC"
}

# inspect_crew, with the python body on stdin -> its INSPECTJSON line
inspect_crew() {
    local budget
    budget="$(budget_left)"
    if [ "$budget" -eq 0 ]; then LAST_RC=124; return 124; fi
    run_python "$budget"
    LAST_RC=$?
    grep -o 'INSPECTJSON:.*' "$RUN_LOG" 2>/dev/null | head -1 | cut -c13-
    return "$LAST_RC"
}

# run_order <order> -> exit status of one planning job; the note is on disk.
run_order() {
    local budget
    budget="$(budget_left)"
    if [ "$budget" -eq 0 ]; then LAST_RC=124; return 124; fi
    ( cd "$LAB_DIR" 2>/dev/null && export PYTHONPATH="$LAB_DIR" \
      && bounded "$budget" "$PY" -m mill.main --order "$1" </dev/null \
    ) >"$RUN_LOG" 2>&1
    LAST_RC=$?
    return "$LAST_RC"
}

db_hash() {
    sha256sum "${LAB_DIR}/data/mill.db" 2>/dev/null | cut -d' ' -f1
}

require_started() {
    local missing="" untouched=""
    [ -s "${LAB_DIR}/config/agents.yaml" ] || missing="${missing} config/agents.yaml"
    [ -s "${LAB_DIR}/config/tasks.yaml" ]  || missing="${missing} config/tasks.yaml"
    [ -s "${LAB_DIR}/mill/tools.py" ]      || missing="${missing} mill/tools.py"
    [ -s "${LAB_DIR}/mill/crew.py" ]       || missing="${missing} mill/crew.py"
    if [ -n "$missing" ]; then
        report "failed" "these files are missing or empty in ${LAB_DIR}:${missing}"
        return 1
    fi
    # One gate per file, and never joined with &&. Joined, a learner who wrote
    # one of the four and left the others sailed through to a probe failure
    # that named a tool instead of the file they had not opened yet.
    grep -q 'the crew is not built yet' "${LAB_DIR}/mill/crew.py" 2>/dev/null \
        && untouched="${untouched} mill/crew.py"
    grep -q 'is not written yet' "${LAB_DIR}/mill/tools.py" 2>/dev/null \
        && untouched="${untouched} mill/tools.py"
    grep -q 'TODO' "${LAB_DIR}/config/agents.yaml" 2>/dev/null \
        && untouched="${untouched} config/agents.yaml"
    grep -q 'TODO' "${LAB_DIR}/config/tasks.yaml" 2>/dev/null \
        && untouched="${untouched} config/tasks.yaml"
    if [ -n "$untouched" ]; then
        report "failed" "these are still the untouched starters in ${LAB_DIR}:${untouched} - write them, then run python3 check_local.py from ${LAB_DIR} before submitting"
        return 1
    fi
    return 0
}

preflight() {
    ensure_deps || { report "failed" "crewai is not installed on this VM yet - see /var/log/thistledown-lab/pip.log"; return 1; }
    require_started || return 1
    return 0
}

preflight_model() {
    preflight || return 1
    ensure_model || { report "failed" "the planning model is not reachable on ${MODEL_URL}"; return 1; }
    return 0
}

Test02() {
    preflight || return

    local before after got n bad
    before="$(db_hash)"
    if [ -z "$before" ]; then
        report "failed" "there is no mill database at ${LAB_DIR}/data/mill.db"
        return
    fi

    # Six statements that must all be refused, in one interpreter start.
    got="$(tool_batch '[
        {"tool": "run_query", "args": {"sql": "DELETE FROM yarn_stock"}},
        {"tool": "run_query", "args": {"sql": "UPDATE yarn_stock SET cones_on_hand = 0"}},
        {"tool": "run_query", "args": {"sql": "DROP TABLE looms"}},
        {"tool": "run_query", "args": {"sql": "SELECT 1; DROP TABLE looms"}},
        {"tool": "run_query", "args": {"sql": "SELECT yarn_code FROM yarn_stock; DELETE FROM looms"}},
        {"tool": "run_query", "args": {"sql": "PRAGMA writable_schema = 1"}}
    ]')"
    if [ -z "$got" ]; then
        report "failed" "run_query produced nothing for any of the write attempts - see ${RUN_LOG}"
        return
    fi
    n="$(printf '%s' "$got" | jq -r 'length')"
    if [ "$n" != "6" ]; then
        report "failed" "only ${n} of the six write attempts came back at all - see ${RUN_LOG}"
        return
    fi
    if [ "$(printf '%s' "$got" | jq -r '[.[] | select(.raised)] | length')" != "0" ]; then
        report "failed" "run_query raised on $(printf '%s' "$got" | jq -r '[.[] | select(.raised) | .raised] | unique | join(", ")') instead of refusing in words - an agent cannot read an exception"
        return
    fi
    # A refusal must say so, and must not carry rows back.
    bad="$(printf '%s' "$got" | jq -r '
        [.[] | select((.text // "") | test("refus|not allowed|only|reject|one statement"; "i") | not) | .text // "empty"]
        | join(" /// ")')"
    if [ -n "$bad" ]; then
        report "failed" "one of the write attempts was answered with \"$(printf '%s' "$bad" | head -c 110)\" - a refusal has to say that it is one"
        return
    fi
    bad="$(printf '%s' "$got" | jq -r '[.[] | select((.text // "") | test("^(yarn_code|loom|cloth)"; "i"))] | length')"
    if [ "${bad:-0}" != "0" ]; then
        report "failed" "one of the write attempts came back with rows - a statement that is not a plain SELECT has to be refused before it runs"
        return
    fi

    after="$(db_hash)"
    if [ "$before" != "$after" ]; then
        report "failed" "the mill database changed while those statements were tried - the connection has to be opened read-only so a bypass physically cannot write"
        return
    fi

    report "success" "six write and multi-statement attempts were each refused in words, none returned rows, and the database is byte for byte what it was before"
}

Test02
