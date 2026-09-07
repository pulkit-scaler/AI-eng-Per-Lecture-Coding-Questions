#!/bin/bash
# TC03 (10 pts): the reviewer loop stops early when it can and at its cap when it cannot
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

Test03() {
    preflight || return

    local d rid got want
    local got_rev want_rev got_acc want_acc got_out want_out
    local judges want_judges revises want_revises hint got_num
    for d in RC-D-101 RC-D-125; do
        rid="tc03_${d}_$$"
        reset_run "$rid"
        want="$(oracle_reflect "$d")"
        want_rev="$(printf '%s' "$want" | jq -r '.revisions')"
        require_expected "$want_rev" || return

        ctl "$rid" review --draft "$d"; got="$CTL_OUT"
        if [ -z "$got" ]; then
            fail_no_json "reviewing ${d}"
            return
        fi
        got_rev="$(printf '%s' "$got" | jq -r '.revisions')"
        if [ "$got_rev" != "$want_rev" ]; then
            # Under- and over-revising are opposite bugs, and a missing count
            # is a third, so the hint branches three ways. The count has to be
            # normalised to digits before any -lt: a module that never returns
            # the key hands jq a null, and a null in an integer test aborts the
            # comparison rather than failing it.
            got_num="$(printf '%s' "$got_rev" | grep -Eox '[0-9]+')"
            if [ -z "$got_num" ]; then
                hint="the result has to carry revisions as a number - how many times the draft went back to the writer"
            elif [ "$got_num" -lt "${want_rev:-0}" ]; then
                hint="the cap is on revisions, not on reviews - a revise verdict on the last review a draft is allowed still sends it back to the writer"
            else
                hint="a draft the reviewer has accepted must not go back to the writer again"
            fi
            report "failed" "${d} went back to the writer ${got_rev} times where the reviewer verdicts and a cap of ${MAX_ROUNDS} give ${want_rev} - ${hint}"
            return
        fi
        got_acc="$(printf '%s' "$got" | jq -r '.accepted')"
        want_acc="$(printf '%s' "$want" | jq -r '.accepted')"
        if [ "$got_acc" != "$want_acc" ]; then
            report "failed" "${d} came back accepted=${got_acc} where the reviewer says ${want_acc}"
            return
        fi
        got_out="$(printf '%s' "$got" | jq -c '.outstanding')"
        want_out="$(printf '%s' "$want" | jq -c '.outstanding')"
        if [ "$got_out" != "$want_out" ]; then
            report "failed" "${d} reported outstanding ${got_out} where the reviewer still had ${want_out} - a draft that goes out anyway has to carry what is still wrong with it"
            return
        fi
        judges="$(trace_field "$rid" '.judge')"
        want_judges="$(printf '%s' "$want" | jq -r '.judge_calls')"
        if [ "$judges" != "$want_judges" ]; then
            # Too many reviews and too few are opposite bugs, so the hint has to
            # follow the direction: a learner who under-reviewed was previously
            # told not to re-review, which points at a bug they do not have.
            if [ "${judges:-0}" = "0" ]; then
                hint="every verdict has to come from kit.judge and every revision from kit.revise, not from anything written into the module"
            elif [ "${judges:-0}" -gt "${want_judges:-0}" ]; then
                hint="a draft the reviewer has already accepted must not go back to it again"
            else
                hint="every revision goes back to the reviewer, the last one included - ${MAX_ROUNDS} revisions take $((MAX_ROUNDS + 1)) reviews, and the verdict on the final revision is what carries the outstanding issues"
            fi
            report "failed" "the reviewer was asked ${judges} times on ${d} where this draft takes ${want_judges} - ${hint}"
            return
        fi
        revises="$(trace_field "$rid" '.revise')"
        want_revises="$(printf '%s' "$want" | jq -r '.revise_calls')"
        if [ "$revises" != "$want_revises" ]; then
            report "failed" "the writer was asked to revise ${revises} times on ${d} where the loop allows ${want_revises}"
            return
        fi
    done

    report "success" "a draft the reviewer accepts was reviewed once and never revised, and a draft it never accepts stopped at ${MAX_ROUNDS} revisions and went out with both outstanding issues named"
}

Test03
