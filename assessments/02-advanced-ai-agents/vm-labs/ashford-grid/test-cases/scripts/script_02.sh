#!/bin/bash
# TC02 (10 pts): the review and refine loop converges and is bounded
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "/usr/local/bin/judge/test/common.sh" 2>/dev/null || source "$DIR/common.sh" 2>/dev/null || true
type print_status >/dev/null 2>&1 || print_status() { echo "RESULT:$1 | $2"; }

# The platform helper ends by installing an ERR trap of its own, so that trap
# lands inside this check's own shell. An ERR trap fires on ANY non-zero simple
# command, regardless of whether errexit is set, including a deliberate
# "return 1" from one of the guards below. Its handler prints a line beginning
# INTERNAL_ERROR and then exits, which lands a second line after our verdict. The
# judge grades the LAST line of stdout plus stderr, so the verdict is discarded,
# the run is reported as evaluated=false, and the learner sees an empty test-case
# panel with no rows at all. Drop the inherited trap, and keep errexit and errtrace
# off for the whole file.
trap - ERR
set +eE

# --- logging & result reporting -----------------------------------------
# Nothing below can abort the script: a check must always end in one verdict, so
# there is no set -e and no set -u anywhere in this file.
TC="$(basename "${BASH_SOURCE[0]}" .sh | sed 's/[^0-9]//g')"

# The judge captures stdout and stderr together and grades the LAST line, so a
# single stray line on stderr would void the verdict exactly the way the inherited
# ERR trap did. A bash job-control notice and a tool warning both do this. Send
# this check's stderr to a file on the VM: the diagnostics stay available there,
# and stdout can only ever end in the verdict.
exec 2>>"/tmp/ashford_tc${TC}.err"
log() { :; }
log_verdict() { :; }
log_file() { :; }
learner_log() { printf '/tmp/ashford_out_%s.log' "$1"; }

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

LAB_DIR="${LAB_DIR:-/home/user/ashford-grid}"
SVC_URL="${SVC_URL:-http://127.0.0.1:8836}"
SVC_BIN="${SVC_BIN:-/opt/ashford-svc/gridd.py}"
GKEY="X-Grader-Key: ashford-grader-q7w2"
GPATH="__agq7w2"
PY="${PY:-python3}"
TO="$(command -v timeout || command -v gtimeout || true)"
export PYTHONDONTWRITEBYTECODE=1

# Grading runs as root while the learner is user, so anything this check
# materialises under the project would be root-owned and the learner could not
# write it afterwards. Ownership is handed back from the EXIT trap rather than from
# a success path, so a run killed at the time cap still leaves a usable VM.
#
# The gate is whether a lab user account exists, NOT where LAB_DIR points. Gating
# on the path meant the repair only ever fired under /home/user, and every local
# harness runs with LAB_DIR=/tmp/... - so the one line written to stop a learner
# being locked out of their own project never ran in the only environment that
# tests it. The case statement stays, but only to bound the chown: a mis-set or
# empty variable must never be able to reach the filesystem root.
on_exit() {
    local rc=$?
    if id -u user >/dev/null 2>&1; then
        case "$LAB_DIR" in
            ""|"/") : ;;
            *) chown -R user:user "$LAB_DIR" >/dev/null 2>&1 ;;
        esac
    fi
    log "script exiting rc=$rc after ${SECONDS}s"
    printf 'script_%s %ss\n' "$TC" "$SECONDS" >>/tmp/ashford_timing.log 2>/dev/null || true
    report "failed" "TC${TC} ended without reaching a verdict (rc=$rc)"
}
trap on_exit EXIT

log "TC${TC} starting"

# --- time budget --------------------------------------------------------
# The portal kills a test case that runs much beyond two minutes and reports a
# blocking process instead of a score, so every wait in this script is bounded:
# 12s waiting for the endpoint + 55s for the one learner run + at most ten 5s
# grader calls is about 117s worst case. Setup already started the endpoint and
# paid the import cost, so a healthy VM finishes in a couple of seconds; these
# numbers only cap the pathological run. Nothing below may loop without one of
# these constants.
SVC_WAIT=${SVC_WAIT:-12}
RUN_BUDGET=${RUN_BUDGET:-55}
CURL_MAX=${CURL_MAX:-5}
DEPS_WAIT=${DEPS_WAIT:-20}
DEPS_READY_FILE="${DEPS_READY_FILE:-/var/log/ashford-lab/deps.ready}"

# The dependency install is deliberately detached from provisioning, so setup cannot
# be killed by the portal for running long. That means a check starting seconds after
# the VM came up could race the install. Wait a bounded moment for the sentinel the
# install job writes; if this VM was provisioned by an older setup script that has no
# sentinel, fall back to an import probe so a missing file can never by itself fail a
# check.
#
# The order matters. "curl and jq exist" must NEVER be used as a proxy for "the
# detached install finished": setup installs both in its own foreground now, so the
# proxy is true from the first second and the check would go on to blame the
# learner's code for a library that is not there yet. Gate on the sentinel, fall
# back to the import probe, and only after the wait look at the tools - reporting a
# missing one as an environment fault that names its install log.
ensure_deps() {
    [ -f "$DEPS_READY_FILE" ] && return 0
    "$PY" -c 'import openai' >/dev/null 2>&1 && return 0
    local i
    for i in $(seq 1 "$DEPS_WAIT"); do
        sleep 1
        [ -f "$DEPS_READY_FILE" ] && return 0
    done
    "$PY" -c 'import openai' >/dev/null 2>&1
}

# jq is load-bearing on BOTH sides: the platform helper builds its verdict line with
# jq -n, and every expected value below is read out of JSON with jq -r. Without it
# this check cannot produce a verdict at all, let alone a correct one, so it is an
# environment fault and must be reported as one.
ensure_tools() {
    local missing=""
    command -v curl >/dev/null 2>&1 || missing="${missing} curl"
    command -v jq   >/dev/null 2>&1 || missing="${missing} jq"
    [ -z "$missing" ] && return 0
    report "failed" "This VM is missing the command-line tool(s)${missing}, which the checks need to reach the model endpoint and read its JSON. This is an environment fault, not a problem with your code: the install log is /var/log/ashford-lab/pip.log and re-provisioning the lab on a fresh VM is the remedy"
    return 1
}

# Bound the learner run even where coreutils timeout(1) is absent (macOS has
# none, and a silently missing bound reports a stalled run as a very slow test
# case instead of killing it, which is how an unbounded run passes for a fast
# one during authoring). The fallback watchdog needs nothing but the shell.
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
    setsid nohup "$PY" "$SVC_BIN" >/tmp/ashford_svc.log 2>&1 </dev/null &
    local i
    for i in $(seq 1 "$SVC_WAIT"); do
        curl -sf -m 2 "${SVC_URL}/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

# oracle2 <jq-filter> <key=value> <key=value>
#   the expected value for a graded input, computed from the grid operations
#   database. Fixed arity rather than a variadic wrapper, so no shell array is
#   needed and the helper behaves the same under every bash version the harness
#   and the judge might use.
oracle2() {
    curl -sf -m "$CURL_MAX" -H "$GKEY" --get \
        --data-urlencode "$2" --data-urlencode "$3" \
        "${SVC_URL}/${GPATH}/oracle" 2>/dev/null | jq -r "$1"
}

trace_field() {
    curl -sf -m "$CURL_MAX" -H "$GKEY" \
        "${SVC_URL}/${GPATH}/trace?run=$1" 2>/dev/null | jq -r "$2"
}

# run_learner <run-id>  (python harness on stdin) -> echoes the LABJSON payload
run_learner() {
    local rid="$1" tmp rc
    # Trailing X characters only: a suffix after them is not substituted by every
    # mktemp, which would hand back one fixed filename and collide between runs.
    tmp="$(mktemp /tmp/ashford_h_XXXXXX)" || return 1
    cat > "$tmp"
    local out; out="$(learner_log "$rid")"
    ( cd "$LAB_DIR" && export ASHFORD_RUN_ID="$rid" PYTHONPATH="$LAB_DIR" && \
        run_bounded "$PY" "$tmp" ) >"$out" 2>&1
    rc=$?
    rm -f "$tmp"
    log "learner run $rid exited rc=$rc; output in $out"
    log_file "$out"
    grep -o 'LABJSON:.*' "$out" | head -1 | cut -c9-
    return $rc
}

# --- which requirement failed -------------------------------------------
# A verdict of 400 characters of key=value tells a learner nothing about which
# rule they broke. need() records one short requirement name per broken rule, in
# the order the requirements are listed in the task, so the message can LEAD with
# the first thing that is wrong and keep the observed values behind it.
#
#   need "<requirement in plain words>" <test> [args...]
#
BROKEN=""
BROKEN_N=0
need() {
    local what="$1"; shift
    if "$@"; then return 0; fi
    BROKEN_N=$((BROKEN_N + 1))
    [ -n "$BROKEN" ] || BROKEN="$what"
    return 1
}
eq() { [ "$1" = "$2" ]; }
ge() { [ "${1:-0}" -ge "${2:-0}" ] 2>/dev/null; }
numeq() { [ "${1:-x}" = "${2:-y}" ]; }
empty() { [ -z "$1" ]; }
first_break() {
    if [ "$BROKEN_N" -le 1 ]; then printf '%s' "$BROKEN"
    else printf '%s (and %d other requirement(s))' "$BROKEN" "$((BROKEN_N - 1))"; fi
}

# --- failure evidence ---------------------------------------------------
# The portal shows the learner ONLY the verdict message, so evidence has to travel
# inside it. Two helpers do that.

# run_evidence <logfile> : one clause describing where the evidence is, or saying
# there is none. A module that only defines functions and never runs exits 0 having
# printed nothing, which leaves this log EMPTY - and a message that points at an
# empty file reads as a broken lab rather than as a broken submission. Reported
# from real VMs twice, so every message that names a log goes through here.
run_evidence() {
    if [ -s "$1" ]; then
        printf 'its output is in %s' "$1"
    else
        printf 'it printed nothing at all, so %s is empty. A module that only defines its functions and never calls them exits quietly like this, and so does one that raises before reaching the end. Run  cd %s && python3 check_local.py  and confirm every task prints a result before you submit' "$1" "$LAB_DIR"
    fi
}

# log_tail <logfile> : the last few lines of a log, flattened onto one line and
# capped, so a traceback arrives WITH the failure and the learner never has to cat
# anything. Returns nothing when there is nothing to show.
log_tail() {
    [ -s "$1" ] || return 0
    tail -n 3 "$1" 2>/dev/null | tr '\n' '|' | sed 's/|/ | /g; s/ | $//' | cut -c1-280
}

# fail_no_output <what-did-not-finish> <run-id>
# Three distinguishable outcomes, because the fix differs for each: the run was
# stopped at the time limit, the run raised, or the run printed nothing at all.
fail_no_output() {
    local out; out="$(learner_log "$2")"
    local tail_text; tail_text="$(log_tail "$out")"
    case "$tail_text" in
        *Killed*|*Terminated*|*"signal 9"*|*"timed out"*)
            report "failed" "$1: it was still running after ${RUN_BUDGET}s and was stopped. Something in it does not return. Check that every loop is bounded by the max_attempts you were passed, and that nothing waits on a model call that was never made. Last output before it was stopped: $tail_text [full output in $out]"
            return 0 ;;
    esac
    if [ -n "$tail_text" ]; then
        report "failed" "$1: Python raised before it could print a result: $tail_text [full output in $out]"
    else
        report "failed" "$1: $(run_evidence "$out")"
    fi
}

# Guard: an unreadable expected value must never silently match an empty result.
require_expected() {
    if [ -z "$1" ] || [ "$1" = "null" ]; then
        report "failed" "The grader could not read the expected result from the model endpoint on ${SVC_URL}, so it has nothing to compare against. This is an environment fault, not a problem with your code: confirm curl -s ${SVC_URL}/health answers, and re-provision the lab on a fresh VM if it does not"
        return 1
    fi
    return 0
}

# Refuse an untouched project in about a second rather than timing out with no
# message. Both plausible causes are named, because from the outside they look the
# same.
require_started() {
    local left
    if [ ! -f "${LAB_DIR}/solution.py" ]; then
        report "failed" "No solution.py in ${LAB_DIR} - the checks read the file you write there"
        return 1
    fi
    left="$(grep -c 'raise NotImplementedError' "${LAB_DIR}/solution.py" 2>/dev/null | tr -d ' ')"
    # Both conditions, so a learner whose own helpers happen to raise
    # NotImplementedError is never refused: a finished solution always contains a
    # model call, because there is no other way to reach the endpoint.
    if [ "${left:-0}" -ge 5 ] \
       && ! grep -q 'chat.completions' "${LAB_DIR}/solution.py" 2>/dev/null; then
        report "failed" "${LAB_DIR}/solution.py is still the untouched starter - write the five functions, then run python3 check_local.py from ${LAB_DIR} before submitting"
        return 1
    fi
    return 0
}

preflight() {
    ensure_deps || { report "failed" "The Python dependency for this lab (openai) is not installed on this VM, so import solution cannot succeed. This is an environment fault, not a problem with your code: check /var/log/ashford-lab/pip.log, and re-provision the lab on a fresh VM if the install failed"; return 1; }
    ensure_tools || return 1
    ensure_service || { report "failed" "The model endpoint is not answering on ${SVC_URL}/health, so nothing can be graded. Leave the endpoint running: it is started by provisioning, and $SVC_BIN is what restarts it. Its log is /tmp/ashford_svc.log"; return 1; }
    require_started || return 1
    return 0
}

Test02() {
    preflight || return
    local want_result want_sql rid out result attempts accepted
    local u_attempts u_accepted u_result refines ran_ok ran_bad
    want_result="$(oracle2 '.result' "kind=answer" "q=What is the total feeder capacity in megawatts for each region?")"
    require_expected "$want_result" || return
    want_sql="$(oracle2 '.sql' "kind=answer" "q=What is the total feeder capacity in megawatts for each region?")"
    require_expected "$want_sql" || return
    rid="tc02_$$"
    out="$(QC="What is the total feeder capacity in megawatts for each region?" NC="4" \
            QU="Which feeder has the worst reactive power factor?" NU="3" run_learner "$rid" <<'PY'
import json, os, sys
sys.path.insert(0, ".")
import solution
first = solution.self_improving_query(os.environ["QC"], int(os.environ["NC"]))
# A question the schema cannot answer must stop at the attempt limit rather than
# loop, and nothing may be run because nothing ever passed review.
second = solution.self_improving_query(os.environ["QU"], int(os.environ["NU"]))
print("LABJSON:" + json.dumps({
    "result": str(first.get("result") or "").strip(),
    "attempts": first.get("attempts"),
    "accepted": bool(first.get("accepted")),
    "sql": str(first.get("sql") or "").strip(),
    "u_attempts": second.get("attempts"),
    "u_accepted": bool(second.get("accepted")),
    "u_result": str(second.get("result") or "").strip(),
}))
PY
)"
    [ -z "$out" ] && { fail_no_output "self_improving_query() did not run to completion" "$rid"; return; }
    result="$(printf '%s' "$out" | jq -r '.result')"
    attempts="$(printf '%s' "$out" | jq -r '.attempts')"
    accepted="$(printf '%s' "$out" | jq -r '.accepted')"
    u_attempts="$(printf '%s' "$out" | jq -r '.u_attempts')"
    u_accepted="$(printf '%s' "$out" | jq -r '.u_accepted')"
    u_result="$(printf '%s' "$out" | jq -r '.u_result')"
    # A refinement that actually carried the review reason, at least one query run
    # successfully, and NOTHING run that the review had rejected.
    refines="$(trace_field "$rid" '[.refines[] | select(.used_feedback)] | length')"
    ran_ok="$(trace_field "$rid" '[.executed[] | select(.ok)] | length')"
    ran_bad="$(trace_field "$rid" '[.executed[] | select(.ok == false)] | length')"
    need "the answerable question did not return the result execute_sql gives for the correct query" eq "$result" "$want_result"
    need "attempts was wrong for the answerable question: it counts CANDIDATES REVIEWED, one per critique call, and the draft plus one repair is 2" eq "$attempts" "2"
    need "accepted was not True even though a candidate passed review" eq "$accepted" "true"
    need "the repair request did not carry the reviewer reason, so the same query came back and the loop never converged" ge "${refines:-0}" 1
    need "the accepted query was never executed, so there is no result to report" ge "${ran_ok:-0}" 1
    need "a query that failed review was executed anyway; only a candidate that passed review may run" numeq "${ran_bad:-1}" 0
    need "attempts was wrong for the unanswerable question: at the ceiling the loop stops without asking for one more repair, so with max_attempts=3 it must report exactly 3" eq "$u_attempts" "3"
    need "accepted was not False for a question no candidate could satisfy" eq "$u_accepted" "false"
    need "result was not None for a question where nothing ever passed review" empty "$u_result"
    if [ "$BROKEN_N" -eq 0 ]; then
        report "success" "The first draft fails review, the refined query passes it and returns the correct result in 2 attempts, a question the schema cannot answer stops at the attempt limit, and no rejected query was ever run"
    else
        report "failed" "self_improving_query: $(first_break). Observed for the answerable question: result=[${result:-none}] attempts=${attempts:-unknown} accepted=${accepted:-unknown} (expected result=[${want_result:-none}] from the query [${want_sql:-none}], attempts=2, accepted=true). For the unanswerable question: attempts=${u_attempts:-unknown} accepted=${u_accepted:-unknown} result=[${u_result:-none}] (expected attempts=3, accepted=false, result empty). The endpoint recorded ${refines:-0} repair requests carrying the reviewer reason (expected at least 1), ${ran_ok:-0} successful executions (expected at least 1) and ${ran_bad:-0} executions of a rejected query (expected 0)"
    fi
}
Test02
