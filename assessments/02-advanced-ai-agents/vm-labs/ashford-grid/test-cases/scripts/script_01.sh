#!/bin/bash
# TC01 (10 pts): the review gate rejects a bad query by name and never runs it
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

Test01() {
    preflight || return
    local want_reason want_valid rid out bad_valid bad_reason good_valid
    local critiques ran saw_candidate
    want_reason="$(oracle2 '.reason' "kind=critique" "sql=SELECT feeder_code, peak_load_mw FROM feeders WHERE capacity_mw > 10")"
    require_expected "$want_reason" || return
    want_valid="$(oracle2 '.valid' "kind=critique" "sql=SELECT feeder_code, capacity_mw FROM feeders WHERE capacity_mw > 10 ORDER BY capacity_mw DESC")"
    require_expected "$want_valid" || return
    rid="tc01_$$"
    out="$(QB="Which feeders carry more than ten megawatts of peak load?" SB="SELECT feeder_code, peak_load_mw FROM feeders WHERE capacity_mw > 10" QG="Which feeders are rated above ten megawatts?" SG="SELECT feeder_code, capacity_mw FROM feeders WHERE capacity_mw > 10 ORDER BY capacity_mw DESC" \
            run_learner "$rid" <<'PY'
import json, os, sys
sys.path.insert(0, ".")
import solution
bad = solution.critique_query(os.environ["QB"], os.environ["SB"])
good = solution.critique_query(os.environ["QG"], os.environ["SG"])
print("LABJSON:" + json.dumps({
    "bad_valid": bool(bad.get("valid")),
    "bad_reason": str(bad.get("reason") or "").strip(),
    "good_valid": bool(good.get("valid")),
    "good_reason": str(good.get("reason") or "").strip(),
}))
PY
)"
    [ -z "$out" ] && { fail_no_output "critique_query() did not run to completion" "$rid"; return; }
    bad_valid="$(printf '%s' "$out" | jq -r '.bad_valid')"
    bad_reason="$(printf '%s' "$out" | jq -r '.bad_reason')"
    good_valid="$(printf '%s' "$out" | jq -r '.good_valid')"
    # Two real round trips, both carrying the candidate query, and nothing run
    # against the database: the audit trail for this run has to be empty.
    critiques="$(trace_field "$rid" '.kinds.critique')"
    saw_candidate="$(trace_field "$rid" '[.critiques[] | select(.sql | contains("peak_load_mw"))] | length')"
    ran="$(trace_field "$rid" '.executed | length')"
    need "critique_query returned valid=true for a candidate naming a column the schema does not have; it must return valid=False" eq "$bad_valid" "false"
    need "the reason string was edited instead of being passed through unchanged" eq "$bad_reason" "$want_reason"
    need "critique_query returned valid=false for a candidate whose every column is real; it must return valid=True" eq "$good_valid" "true"
    need "critique_query did not send a review turn for each candidate, so the reviewer never saw them" ge "${critiques:-0}" 2
    need "the review turn did not carry the candidate query itself, so the reviewer had nothing to review" ge "${saw_candidate:-0}" 1
    need "critique_query executed a query against the database; it must review the candidate without running anything" numeq "${ran:-1}" 0
    if [ "$BROKEN_N" -eq 0 ]; then
        report "success" "A candidate naming a column the schema does not have is reviewed as invalid with the reason that names it, a candidate over real columns is reviewed as valid, and neither candidate was ever run against the database"
    else
        report "failed" "critique_query: $(first_break). Observed: first candidate valid=${bad_valid:-unknown} reason=[${bad_reason:-none}] (expected valid=false reason=[${want_reason:-none}]), second candidate valid=${good_valid:-unknown} (expected true), ${critiques:-0} review turns of which ${saw_candidate:-0} carried the candidate (expected at least 2 and 1), ${ran:-0} queries run against the database (expected 0)"
    fi
}
Test01
