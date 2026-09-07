#!/bin/bash
# TC01 (10 pts): the loop acts on what came back, and the trace records it
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
exec 2>>"/tmp/redcliffe_tc${TC}.err"
STATUS_SENT=0
report() {
    if [ "$STATUS_SENT" -eq 1 ]; then return 0; fi
    STATUS_SENT=1
    print_status "$1" "$2"
}

LAB_DIR="${LAB_DIR:-/home/user/redcliffe-signals}"
DESK_URL="${DESK_URL:-http://127.0.0.1:8622}"
DESK_BIN="${DESK_BIN:-/opt/redcliffe-svc/signalsvc.py}"
GKEY="X-Grader-Key: redcliffe-grader-rc9v"
GPATH="__rc9v"
STORE="${STORE:-store/signals.jsonl}"
PY="${PY:-python3}"
MAX_STEPS="${MAX_STEPS:-4}"
MAX_ROUNDS="${MAX_ROUNDS:-2}"
RECALL_TOP_K="${RECALL_TOP_K:-3}"
TIMING_LOG="${TIMING_LOG:-/tmp/redcliffe_timing.log}"
RUN_LOG="/tmp/redcliffe_tc${TC}.log"
export PYTHONDONTWRITEBYTECODE=1

# --- time budget -----------------------------------------------------------
# Everything this lab needs is the standard library, so there is no dependency
# wait and no heavy import: a run is a few HTTP calls to a local service. The
# deadline is shared across every invocation a check makes, because the memory
# check runs the program five times and five independent bounds would add up
# past the portal cap.
CURL_MAX=${CURL_MAX:-5}
SVC_WAIT=${SVC_WAIT:-12}
RUN_BUDGET=${RUN_BUDGET:-25}
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

# Grading runs as root while the learner is user. Writing a note creates the
# store, so a check that gets there first would leave a root-owned file the
# learner cannot append to. Ownership goes back from the EXIT trap rather than
# from a success path.
on_exit() {
    local rc=$?
    case "$LAB_DIR" in
        /home/user/*) chown -R user:user "$LAB_DIR" >/dev/null 2>&1 ;;
    esac
    printf 'script_%s %ss\n' "$TC" "$SECONDS" >>"$TIMING_LOG" 2>/dev/null || true
    report "failed" "TC${TC} ended without reaching a verdict (rc=${rc})"
}
trap on_exit EXIT

ensure_desk() {
    curl -sf -m "$CURL_MAX" "${DESK_URL}/health" >/dev/null 2>&1 && return 0
    [ -f "$DESK_BIN" ] || return 1
    spawn_detached /tmp/redcliffe_desk.log "$PY" "$DESK_BIN"
    local i
    for i in $(seq 1 "$SVC_WAIT"); do
        curl -sf -m 2 "${DESK_URL}/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

oracle_react() {
    curl -sf -m "$CURL_MAX" -H "$GKEY" --get \
        --data-urlencode "question=$1" \
        "${DESK_URL}/${GPATH}/oracle?kind=react&max=${MAX_STEPS}" 2>/dev/null
}

oracle_reflect() {
    curl -sf -m "$CURL_MAX" -H "$GKEY" \
        "${DESK_URL}/${GPATH}/oracle?kind=reflect&draft=$1&max=${MAX_ROUNDS}" \
        2>/dev/null
}

trace_field() {
    curl -sf -m "$CURL_MAX" -H "$GKEY" "${DESK_URL}/${GPATH}/trace?run=$1" \
        2>/dev/null | jq -r "$2"
}

reset_run() {
    curl -sf -m "$CURL_MAX" -X POST -H "$GKEY" \
        "${DESK_URL}/${GPATH}/reset?run=$1" >/dev/null 2>&1
    return 0
}

budget_left() {
    local left
    left=$(( HARD_DEADLINE - SECONDS ))
    if [ "$left" -lt 6 ]; then echo 0; return; fi
    if [ "$left" -lt "$RUN_BUDGET" ]; then echo "$left"; else echo "$RUN_BUDGET"; fi
}

LAST_RC=0
CTL_OUT=""
# ctl <run-id> <argv...>: leaves the JSON object signalctl printed in CTL_OUT.
#
# It does NOT echo it. A caller writing ctl ...; got="$CTL_OUT" would run this in a
# subshell, where LAST_RC dies with it - and fail_no_json would then report the
# initial exit 0 for a crash, a timeout and a program that never ran alike.
# Call it as a statement and read CTL_OUT.
ctl() {
    local rid="$1" budget; shift
    CTL_OUT=""
    budget="$(budget_left)"
    if [ "$budget" -eq 0 ]; then LAST_RC=124; return 124; fi
    ( cd "$LAB_DIR" 2>/dev/null \
      && export REDCLIFFE_RUN_ID="$rid" PYTHONPATH="$LAB_DIR" \
                REDCLIFFE_DESK_URL="$DESK_URL" \
      && bounded "$budget" "$PY" signalctl.py "$@" </dev/null ) >"$RUN_LOG" 2>&1
    LAST_RC=$?
    CTL_OUT="$(sed 's/^[[:space:]]*//' "$RUN_LOG" 2>/dev/null \
               | grep -E '^\{.*\}$' | tail -1)"
    return "$LAST_RC"
}

fail_no_json() {
    report "failed" "${1} - signalctl printed no JSON object (exit ${LAST_RC}); its output is in ${RUN_LOG}"
}

require_expected() {
    if [ -z "$1" ] || [ "$1" = "null" ]; then
        report "failed" "Grader could not read the expected result from the control desk on ${DESK_URL}"
        return 1
    fi
    return 0
}

# Refuse an unstarted project in about a second, naming every plausible cause.
require_started() {
    local missing="" f
    for f in react_loop reflect memory; do
        [ -s "${LAB_DIR}/signals/${f}.py" ] || missing="${missing} signals/${f}.py"
    done
    if [ -n "$missing" ]; then
        report "failed" "these files are missing or empty in ${LAB_DIR}:${missing}"
        return 1
    fi
    local untouched
    untouched="$(grep -l 'is not written yet' "${LAB_DIR}/signals"/*.py 2>/dev/null \
        | xargs -n1 basename 2>/dev/null | tr '\n' ' ')"
    if [ -n "$untouched" ]; then
        report "failed" "these still hold the untouched starter: ${untouched}- write the three modules, then run python3 check_local.py from ${LAB_DIR} before submitting"
        return 1
    fi
    return 0
}

preflight() {
    ensure_desk || { report "failed" "the control desk is not reachable on ${DESK_URL}"; return 1; }
    require_started || return 1
    return 0
}

Test01() {
    preflight || return

    local rid q got want n i action obs
    local got_answer want_answer got_actions want_actions want_steps
    local seen_tools want_tools got_think want_think bad reason
    for q in "why is RC-BOX-19 showing red" \
             "can AST-2210 be swapped out under possession on SEC-4"; do
        rid="tc01_$$_$(printf '%s' "$q" | tr -dc 'A-Z0-9' | head -c 10)"
        reset_run "$rid"
        want="$(oracle_react "$q")"
        want_steps="$(printf '%s' "$want" | jq -r '.steps')"
        require_expected "$want_steps" || return

        ctl "$rid" ask --question "$q"; got="$CTL_OUT"
        if [ -z "$got" ]; then
            fail_no_json "asking about ${q}"
            return
        fi

        reason="$(printf '%s' "$got" | jq -r '.stopped_because // "no reason given"')"
        if [ "$(printf '%s' "$got" | jq -r '.answered')" != "true" ]; then
            report "failed" "the loop gave up on a question the desk can answer: ${reason}"
            return
        fi
        got_answer="$(printf '%s' "$got" | jq -r '.answer')"
        want_answer="$(printf '%s' "$want" | jq -r '.answer')"
        if [ "$got_answer" != "$want_answer" ]; then
            report "failed" "the answer to ${q} is not the one the desk settled on"
            return
        fi
        got_actions="$(printf '%s' "$got" | jq -c '[.actions[]]')"
        want_actions="$(printf '%s' "$want" | jq -c '.actions')"
        if [ "$got_actions" != "$want_actions" ]; then
            report "failed" "the loop took actions ${got_actions} where this question needs ${want_actions} - each action follows from what the last one returned"
            return
        fi

        # Every step that acted has to carry a thought, the action, its input and
        # the observation that came back. An empty observation is a trace
        # written rather than recorded.
        n="$(printf '%s' "$got" | jq -r '[.trace[] | select(.action != null)] | length')"
        if [ "$n" != "$want_steps" ]; then
            report "failed" "the trace records ${n} acting steps where the run took ${want_steps}"
            return
        fi
        bad="$(printf '%s' "$got" | jq -r '[.trace[] | select(.action != null) | select((.thought // "") == "" or .observation == null)] | length')"
        if [ "$bad" != "0" ]; then
            report "failed" "${bad} step(s) in the trace have no thought or no observation against them - the trace has to record what happened, not summarise it"
            return
        fi

        i=1
        while [ "$i" -le "$n" ]; do
            action="$(printf '%s' "$got" | jq -r --argjson i "$i" '[.trace[] | select(.action != null)][$i-1].action')"
            obs="$(printf '%s' "$got" | jq -r --argjson i "$i" '[.trace[] | select(.action != null)][$i-1].observation | tostring')"
            case "$action" in
                signal_status)
                    if ! printf '%s' "$obs" | grep -q 'aspect'; then
                        report "failed" "the observation on the signal_status step is not what that tool returns"
                        return
                    fi ;;
                possession_window)
                    if ! printf '%s' "$obs" | grep -q 'window'; then
                        report "failed" "the observation on the possession_window step is not what that tool returns"
                        return
                    fi ;;
                fault_history)
                    if ! printf '%s' "$obs" | grep -q 'faults_12m'; then
                        report "failed" "the observation on the fault_history step is not what that tool returns"
                        return
                    fi ;;
            esac
            i=$((i + 1))
        done

        seen_tools="$(trace_field "$rid" '.tools | join(",")')"
        want_tools="$(printf '%s' "$want" | jq -r '.actions | join(",")')"
        if [ "$seen_tools" != "$want_tools" ]; then
            report "failed" "the desk saw tools ${seen_tools} where the trace claims ${want_tools} - the observations have to come from the tools actually running"
            return
        fi
        got_think="$(trace_field "$rid" '.think')"
        want_think="$(printf '%s' "$want" | jq -r '.think_calls')"
        if [ "$got_think" != "$want_think" ]; then
            report "failed" "the loop thought ${got_think} times where this question takes ${want_think} - one thought per action, and one more to close"
            return
        fi
    done

    report "success" "two questions answered by acting on what came back, with every step of both traces carrying the thought, the action and the observation the tool really returned"
}

Test01
