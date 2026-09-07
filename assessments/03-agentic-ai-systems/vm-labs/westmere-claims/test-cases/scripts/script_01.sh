#!/bin/bash
# TC01 (10 pts): a structured triage record, produced by the chain
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
exec 2>>"/tmp/westmere_tc${TC}.err"
STATUS_SENT=0
report() {
    if [ "$STATUS_SENT" -eq 1 ]; then return 0; fi
    STATUS_SENT=1
    print_status "$1" "$2"
}

LAB_DIR="${LAB_DIR:-/home/user/westmere-claims}"
DESK_URL="${DESK_URL:-http://127.0.0.1:8571}"
DESK_BIN="${DESK_BIN:-/opt/westmere-svc/claimsvc.py}"
GKEY="X-Grader-Key: westmere-grader-w5r2"
GPATH="__wm5r"
STATE_DB="${STATE_DB:-state/claims.db}"
PY="${PY:-python3}"
DEPS_READY_FILE="${DEPS_READY_FILE:-/var/log/westmere-lab/deps.ready}"
TIMING_LOG="${TIMING_LOG:-/tmp/westmere_timing.log}"
export PYTHONDONTWRITEBYTECODE=1

# --- time budget -----------------------------------------------------------
# The portal kills a test case that runs much beyond two minutes and reports a
# blocking process instead of a score. Every wait here is bounded, and the
# learner program is additionally bounded by a HARD_DEADLINE on the whole
# script: the check with the most invocations makes five of them, and five
# independent per-call bounds would add up past the cap even though no single
# call is slow. run_ctl therefore shrinks its own bound as the deadline
# approaches, so the arithmetic is 25 (deps) + 12 (desk) + 100 (all learner
# runs together) whatever the check does.
CURL_MAX=${CURL_MAX:-5}
SVC_WAIT=${SVC_WAIT:-12}
DEPS_WAIT=${DEPS_WAIT:-25}
RUN_BUDGET=${RUN_BUDGET:-30}
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

# Grading runs as root while the learner is user. Ownership goes back from the
# EXIT trap rather than from a success path, so a run killed at the cap still
# leaves a VM the learner can work in. The checkpoint store is the reason this
# matters here: running the learner program creates state/claims.db, and a
# root-owned SQLite file gives them a readonly database from then on. The case
# statement bounds the chown so an empty variable cannot reach the root.
on_exit() {
    local rc=$?
    case "$LAB_DIR" in
        /home/user/*) chown -R user:user "$LAB_DIR" >/dev/null 2>&1 ;;
    esac
    printf 'script_%s %ss\n' "$TC" "$SECONDS" >>"$TIMING_LOG" 2>/dev/null || true
    report "failed" "TC${TC} ended without reaching a verdict (rc=${rc})"
}
trap on_exit EXIT

# One log per invocation, numbered in order. The counter is bumped inline by
# run_ctl rather than by a helper called as out="$(learner_log)": that
# substitution is a subshell, so the increment never reached this shell and
# every invocation of a check reused the _1 log, clobbering the evidence from
# the runs before it.
CALLN=0

ensure_deps() {
    [ -f "$DEPS_READY_FILE" ] && return 0
    "$PY" -c 'import langgraph, langchain_core' >/dev/null 2>&1 && return 0
    local i
    for i in $(seq 1 "$DEPS_WAIT"); do
        sleep 1
        [ -f "$DEPS_READY_FILE" ] && return 0
    done
    "$PY" -c 'import langgraph, langchain_core' >/dev/null 2>&1
}

# setsid is present on the target image and absent on macOS, and a background
# job that never starts costs the whole health-wait budget before anything
# notices. Fall back to plain nohup rather than letting the bound go silent.
spawn_detached() {
    local log="$1"; shift
    if command -v setsid >/dev/null 2>&1; then
        setsid nohup "$@" >"$log" 2>&1 </dev/null &
    else
        nohup "$@" >"$log" 2>&1 </dev/null &
    fi
    return 0
}

ensure_service() {
    curl -sf -m "$CURL_MAX" "${DESK_URL}/health" >/dev/null 2>&1 && return 0
    [ -f "$DESK_BIN" ] || return 1
    spawn_detached /tmp/westmere_desk.log "$PY" "$DESK_BIN"
    local i
    for i in $(seq 1 "$SVC_WAIT"); do
        curl -sf -m 2 "${DESK_URL}/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

oracle() {
    curl -sf -m "$CURL_MAX" -H "$GKEY" \
        "${DESK_URL}/${GPATH}/oracle?kind=$1&claim=$2&max=3&ceiling=4" 2>/dev/null
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

# run_ctl <run-id> <argv...> leaves the last JSON object the program printed in
# RUN_OUT, and the log path and exit status of that run in LAST_LOG/LAST_RC.
# It does NOT echo the JSON: a caller writing got="$(run_ctl ...)" runs the
# whole function in a subshell, so every variable it sets dies there. That cost
# a real submission its diagnosis - the call counter never advanced, so all
# five runs of a check overwrote the _1 log, and every failure message read
# "exit 0 ... its output is in " with no path and a status that was never true.
# Call it as a statement, then read RUN_OUT.
# The bound shrinks as the script deadline approaches, so a check that runs the
# program five times can never add up past the portal cap.
RUN_OUT=""
LAST_LOG=""
LAST_RC=0
run_ctl() {
    local rid="$1"; shift
    local out left budget
    RUN_OUT=""
    CALLN=$((CALLN + 1))
    out="/tmp/westmere_out_${TC}_${CALLN}.log"
    LAST_LOG="$out"
    left=$(( HARD_DEADLINE - SECONDS ))
    if [ "$left" -lt 6 ]; then
        LAST_RC=124
        return 124
    fi
    budget=$(( left < RUN_BUDGET ? left : RUN_BUDGET ))
    # WESTMERE_DESK_URL is exported from DESK_URL rather than left to the
    # default, so the program can never dial a different desk from the one this
    # check is reading. On the VM they are the same address; on a harness that
    # moves the port they would silently diverge.
    ( cd "$LAB_DIR" 2>/dev/null \
      && export WESTMERE_RUN_ID="$rid" PYTHONPATH="$LAB_DIR" \
                WESTMERE_DESK_URL="$DESK_URL" \
      && bounded "$budget" "$PY" claimctl.py "$@" ) >"$out" 2>&1
    LAST_RC=$?
    RUN_OUT="$(sed 's/^[[:space:]]*//' "$out" 2>/dev/null | grep -E '^\{.*\}$' | tail -1)"
    return "$LAST_RC"
}

fail_no_json() {
    report "failed" "${1} - claimctl printed no JSON object (exit ${LAST_RC}); its output is in ${LAST_LOG}"
}

require_expected() {
    if [ -z "$1" ] || [ "$1" = "null" ]; then
        report "failed" "Grader could not read the expected answer from the claims desk on ${DESK_URL}"
        return 1
    fi
    return 0
}

# Refuse an unstarted project in about a second, naming every plausible cause,
# rather than spending the budget on work the learner has not begun.
require_started() {
    if [ ! -f "${LAB_DIR}/claimctl.py" ]; then
        report "failed" "no claimctl.py in ${LAB_DIR} - that is the program the checks run"
        return 1
    fi
    # The starter carries this sentence and nothing a working program would.
    # One condition, so an untouched project is refused in about a second.
    if grep -q 'claimctl is not implemented yet' "${LAB_DIR}/claimctl.py" 2>/dev/null; then
        report "failed" "${LAB_DIR}/claimctl.py is still the untouched starter - write the five subcommands, then run python3 check_local.py from ${LAB_DIR} before submitting"
        return 1
    fi
    return 0
}

preflight() {
    ensure_deps || { report "failed" "the Python packages this lab needs are not installed on this VM yet - see /var/log/westmere-lab/pip.log"; return 1; }
    ensure_service || { report "failed" "the claims desk is not reachable on ${DESK_URL}"; return 1; }
    require_started || return 1
    return 0
}

Test01() {
    preflight || return

    local rid="tc01_$$" claim got want field schemas calls via total
    reset_run "$rid"

    for claim in WM-3315 WM-3342 WM-3168; do
        want="$(oracle triage "$claim")"
        require_expected "$(printf '%s' "$want" | jq -r '.claim_id')" || return
        run_ctl "$rid" triage --claim "$claim"
        got="$RUN_OUT"
        if [ -z "$got" ]; then
            fail_no_json "triage ${claim} returned nothing"
            return
        fi
        for field in claim_id category severity needs_adjuster fraud_score confidence summary; do
            if [ "$(printf '%s' "$got" | jq -r ".$field")" \
                 != "$(printf '%s' "$want" | jq -r ".$field")" ]; then
                report "failed" "triage ${claim} reported ${field}=$(printf '%s' "$got" | jq -r ".$field") where the desk record has $(printf '%s' "$want" | jq -r ".$field")"
                return
            fi
        done
    done

    calls="$(trace_field "$rid" '.structured')"
    total="$(trace_field "$rid" '.total')"
    via="$(trace_field "$rid" '.via_kit')"
    schemas="$(trace_field "$rid" '[.schemas[] | select(startswith("Triage"))] | length')"

    if [ "${via:-0}" != "${total:-0}" ]; then
        report "failed" "$(( ${total:-0} - ${via:-0} )) of the ${total:-0} desk requests did not come from the provided model - every call has to go through kit.get_chat_model()"
        return
    fi
    if [ "${calls:-0}" -ne 3 ]; then
        report "failed" "the desk was asked for a record ${calls} times for three claims - one triage is one request"
        return
    fi
    if [ "${schemas:-0}" -ne 3 ]; then
        report "failed" "only ${schemas} of the three requests carried a triage schema - the record has to come back through with_structured_output, not out of free text"
        return
    fi

    report "success" "three triage records correct field for field, including the claim whose narrative names a different claim, from exactly three structured requests through the provided model"
}

Test01
