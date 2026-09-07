#!/bin/bash
# TC04 (10 pts): one shared conversation carries what earlier turns discovered
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "/usr/local/bin/judge/test/common.sh" 2>/dev/null || source "$DIR/common.sh" 2>/dev/null || true
type print_status >/dev/null 2>&1 || print_status() { echo "RESULT:$1 | $2"; }

# The platform helper we just sourced ends by installing an ERR trap of its own:
#     trap 'handle_script_error $LINENO $? "$BASH_COMMAND"' ERR
# That trap fires on ANY non-zero simple command, whether or not set -e is in
# effect, and that includes a deliberate  return 1  from one of the guards below.
# Its handler prints an INTERNAL_ERROR line and exits, landing a second line after
# our verdict. The judge grades the LAST line of stdout and stderr combined, so the
# verdict would be discarded and the submission would report no test cases at all.
# Drop the inherited trap, and turn off both error-exit options for good measure.
trap - ERR
set +eE

# --- logging & result reporting -----------------------------------------
# Nothing below can abort the script: a check must always end in one verdict.
TC="$(basename "${BASH_SOURCE[0]}" .sh | sed 's/[^0-9]//g')"

# The judge captures stdout and stderr together and grades only the LAST line of
# the two combined. One stray line on stderr - a bash job-control notice, a tool
# warning, a Python traceback - would therefore land after the verdict and void
# it, exactly as an inherited ERR trap would. Send this check's stderr to a file
# on the VM: the diagnostics stay available there, and stdout can only ever end
# in the verdict.
exec 2>>"/tmp/kilnbrook_tc${TC}.err"
log() { :; }
log_verdict() { :; }
log_file() { :; }
learner_log() { printf '/tmp/kilnbrook_out_%s.log' "$1"; }

LAB_DIR="${LAB_DIR:-/home/user/kilnbrook-foundry}"
DB_FILE="${DB_FILE:-${LAB_DIR}/data/foundry.db}"
SVC_URL="${SVC_URL:-http://127.0.0.1:8781}"
SVC_BIN="${SVC_BIN:-/opt/kilnbrook-svc/foundryd.py}"
AUDIT="X-Kiln-Audit: kilnbrook-audit-q7z2"
PY="${PY:-python3}"
TO="$(command -v timeout || command -v gtimeout || true)"
CEILING=${CEILING:-8}
export PYTHONDONTWRITEBYTECODE=1
# The learner client reads this; exporting it here keeps the checks and the code
# under test pointed at the same endpoint even when the harness moves the port.
export KILN_ENDPOINT="${SVC_URL}/v1"

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
on_exit() {
    local rc=$?
    # Grading runs as root while the lab user is "user", and merely running the
    # learner code can create files under their project. Hand ownership back from
    # the trap, not from a success path: a run killed at the time cap still has to
    # leave a usable VM.
    #
    # Gated on the account existing rather than on where LAB_DIR points. The
    # earlier form only fired for /home/user/*, and every local harness runs with
    # LAB_DIR=/tmp/..., so the one repair written to stop a learner being locked
    # out of their own project never ran in the environment that tests it. The
    # case arm still refuses an empty variable and a bare "/", so no expansion
    # accident can chown the filesystem root.
    case "${LAB_DIR:-}" in
        ""|/) : ;;
        /*)   id -u user >/dev/null 2>&1 && chown -R user:user "$LAB_DIR" >/dev/null 2>&1 ;;
    esac
    printf 'script_%s %ss\n' "$TC" "$SECONDS" >>/tmp/kilnbrook_timing.log 2>/dev/null || true
    log "script exiting rc=$rc"
    report "failed" "This check stopped before it reached a verdict (rc=$rc), so nothing about your submission was assessed here. That is a fault in the lab rather than in your code: the check's own error output is in /tmp/kilnbrook_tc${TC}.err"
}
trap on_exit EXIT

log "TC${TC} starting"

# --- time budget --------------------------------------------------------
# The portal kills a test case that runs much beyond two minutes and reports a
# blocking process instead of a score, so every wait in this script is bounded:
# 12s waiting for the endpoint + 55s for the one learner run + at most eight 5s
# audit calls is ~107s worst case. Setup already started the endpoint and paid the
# import cost, so a healthy VM finishes in seconds; these numbers only cap the
# pathological run. Nothing below may loop without one of these constants.
SVC_WAIT=${SVC_WAIT:-12}
RUN_BUDGET=${RUN_BUDGET:-55}
CURL_MAX=${CURL_MAX:-5}
DEPS_WAIT=${DEPS_WAIT:-20}
DEPS_READY_FILE="${DEPS_READY_FILE:-/var/log/kilnbrook-lab/deps.ready}"

# The dependency install is deliberately detached from provisioning, so setup cannot be
# killed by the portal for running long. That means a check starting seconds after the VM
# came up could race the install. Wait a bounded moment for the readiness marker the
# install job writes, which it writes last and only once apt has installed curl and jq
# and pip has resolved openai. All three matter here: the learner code imports openai,
# and every helper below shells out to curl and jq.
#
# deps_present() probes all three directly rather than treating "curl and jq exist" as a
# stand-in for "the pip install finished". That stand-in is always true once curl and jq
# are in the foreground, and a check built on it would go on to blame the learner code
# for a library the VM never installed.
deps_present() {
    command -v curl >/dev/null 2>&1 || return 1
    command -v jq   >/dev/null 2>&1 || return 1
    "$PY" -c 'import openai' >/dev/null 2>&1
}

# Names the first thing that is missing, so the verdict can say which dependency the VM
# lacks instead of reporting a bare "not installed".
missing_dep() {
    command -v curl >/dev/null 2>&1 || { printf 'curl'; return 0; }
    command -v jq   >/dev/null 2>&1 || { printf 'jq'; return 0; }
    "$PY" -c 'import openai' >/dev/null 2>&1 || { printf 'the openai Python package'; return 0; }
    printf 'nothing, but the readiness marker never appeared'
}

ensure_deps() {
    [ -f "$DEPS_READY_FILE" ] && return 0
    deps_present && return 0
    local i
    for i in $(seq 1 "$DEPS_WAIT"); do
        sleep 1
        [ -f "$DEPS_READY_FILE" ] && return 0
    done
    # Only after the wait: a VM provisioned by an older setup script publishes no
    # marker, and a missing file must not by itself fail a check.
    deps_present
}

# env_fault : one sentence for a verdict when the VM, not the submission, is at fault.
env_fault() {
    printf 'This VM is not ready to be graded: %s is not installed, so the lab environment is incomplete and this is not a fault in your code. The dependency install log is /var/log/kilnbrook-lab/pip.log and the readiness marker it writes when it finishes is %s' \
        "$(missing_dep)" "$DEPS_READY_FILE"
}

# Bound the learner run even where coreutils timeout(1) is absent (macOS has none,
# and a silently missing bound reports a stalled run as a very slow test case
# instead of killing it, which is how an unbounded run passes for a fast one during
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
    setsid nohup "$PY" "$SVC_BIN" >/tmp/kilnbrook_svc.log 2>&1 </dev/null &
    local i
    for i in $(seq 1 "$SVC_WAIT"); do
        curl -sf -m 2 "${SVC_URL}/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

oracle_field() {
    curl -sf -m "$CURL_MAX" -H "$AUDIT" --get --data-urlencode "q=$1" \
        "${SVC_URL}/__kbz7q/oracle" 2>/dev/null | jq -c "$2"
}

query_values() {
    curl -sf -m "$CURL_MAX" -H "$AUDIT" --get --data-urlencode "sql=$1" \
        "${SVC_URL}/__kbz7q/query" 2>/dev/null | jq -c ".values"
}

schema_field() {
    curl -sf -m "$CURL_MAX" -H "$AUDIT" --get --data-urlencode "table=$1" \
        "${SVC_URL}/__kbz7q/schema" 2>/dev/null | jq -c "$2"
}

trace_field() {
    curl -sf -m "$CURL_MAX" -H "$AUDIT" \
        "${SVC_URL}/__kbz7q/trace?session=$1" 2>/dev/null | jq -r "$2" 2>/dev/null
}

# word_or <default> <value> : a verdict built from jq output must still read as a
# sentence when the JSON was absent and jq printed nothing, or the literal null.
word_or() {
    case "${2:-}" in
        ""|null) printf '%s' "$1" ;;
        *)       printf '%s' "$2" ;;
    esac
}

# json_field <payload> <filter> <default> : one scalar out of the LABJSON payload.
json_field() {
    word_or "$3" "$(printf '%s' "$1" | jq -r "$2" 2>/dev/null)"
}

# json_compact <payload> <filter> <default> : same, but for a list. jq -c keeps the
# list on one line, which matters twice over: the comparisons below are string
# comparisons against a compact expected list, and a verdict is one line.
json_compact() {
    word_or "$3" "$(printf '%s' "$1" | jq -c "$2" 2>/dev/null)"
}

db_hash() {
    [ -s "$1" ] || { echo "MISSING"; return 0; }
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d" " -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | cut -d" " -f1
    else
        wc -c <"$1" | tr -d " "
    fi
}

# contains_all <json-array-of-strings> <text> : every value must appear verbatim.
# Values come from the database, so this grades the number the query produced
# without grading how a solution chose to lay its rows out.
MISSING_VALUE=""
contains_all() {
    local text="$2" value
    MISSING_VALUE=""
    while IFS= read -r value; do
        [ -n "$value" ] || continue
        case "$text" in
            *"$value"*) ;;
            *) MISSING_VALUE="$value"; return 1 ;;
        esac
    done < <(printf '%s' "$1" | jq -r ".[]" 2>/dev/null)
    return 0
}

# run_learner <session-id>  (python harness on stdin) -> echoes the LABJSON payload
run_learner() {
    local rid="$1" tmp rc
    # Trailing X characters only: a suffix after them is not substituted by every
    # mktemp, which would hand back one fixed filename and collide between runs.
    tmp="$(mktemp /tmp/kilnbrook_h_XXXXXX)" || return 1
    cat > "$tmp"
    local out; out="$(learner_log "$rid")"
    ( cd "$LAB_DIR" && export KILN_SESSION="$rid" PYTHONPATH="$LAB_DIR" && \
        run_bounded "$PY" "$tmp" ) >"$out" 2>&1
    rc=$?
    rm -f "$tmp"
    log "learner run $rid exited rc=$rc; output in $out"
    log_file "$out"
    grep -o 'LABJSON:.*' "$out" | head -1 | cut -c9-
    return $rc
}

# log_tail <file> : the last few lines of a log flattened onto one line, so a
# traceback can ride inside the verdict itself. The portal shows the learner only
# the verdict message, so evidence that stays in a file is evidence they never see.
log_tail() {
    [ -s "$1" ] || return 0
    tail -n 3 "$1" 2>/dev/null | paste -s -d '|' - | sed 's/|/ | /g' | cut -c1-280
}

# run_evidence <file> : what to say about the output a learner run left behind.
# The empty case is the one that used to read as a broken lab: the message named a
# log file as evidence and the file had nothing in it. A module that only defines
# functions exits 0 having printed nothing, which is exactly how that happens.
run_evidence() {
    if [ -s "$1" ]; then
        printf 'it printed: %s  [full output in %s]' "$(log_tail "$1")" "$1"
    else
        printf 'it printed nothing at all, so %s is empty. A module that only defines functions exits quietly like this: check that solution.py defines every callable in the interface contract, that importing it raises nothing, and run  cd %s && python3 check_local.py  to see what each one returns' \
            "$1" "$LAB_DIR"
    fi
}

fail_no_output() {
    report "failed" "$1. The check ran your solution.py in a fresh python3 process from ${LAB_DIR} and no result came back, so $(run_evidence "$(learner_log "$2")")"
}

# Guard: an unreadable expected value must never silently match an empty result.
require_expected() {
    if [ -z "$1" ] || [ "$1" = "null" ] || [ "$1" = "[]" ]; then
        report "failed" "This check could not read the expected result from the model endpoint on ${SVC_URL}, so it did not grade your code at all. That is an environment fault: confirm the endpoint is answering with  curl -s ${SVC_URL}/health  and that jq is installed"
        return 1
    fi
    return 0
}

need_project() {
    [ -f "${LAB_DIR}/solution.py" ] || {
        report "failed" "There is no solution.py in ${LAB_DIR}, so there was nothing to grade. Write your functions in that file, then run  cd ${LAB_DIR} && python3 check_local.py  before submitting"
        return 1
    }
    [ -s "$DB_FILE" ] || {
        report "failed" "The foundry database is missing or empty at ${DB_FILE}, so no tool could read anything from it. That is an environment fault rather than a fault in your code: re-provisioning the lab rebuilds the file"
        return 1
    }
    return 0
}

Test04() {
    ensure_deps || { report "failed" "$(env_fault)"; return; }
    ensure_service || { report "failed" "The model endpoint is not answering on ${SVC_URL}, so this check could not be run at all. That is an environment fault rather than a fault in your code: curl -s ${SVC_URL}/health should print a status line, and /tmp/kilnbrook_svc.log holds the endpoint output"; return; }
    need_project || return
    local want1 want2 rid out n a1 a2 first second turns capped
    want1="$(oracle_field "What is the total weight poured on the day shift?" ".values")"; require_expected "$want1" || return
    want2="$(oracle_field "And what was the total scrap weight on the day shift?" ".values")"; require_expected "$want2" || return
    rid="tc04_$$"
    out="$(Q_S1="What is the total weight poured on the day shift?" Q_S2="And what was the total scrap weight on the day shift?" run_learner "$rid" <<'PY'
import json, os, sys
sys.path.insert(0, ".")
import solution

nothing = solution.run_session([])
answers = solution.run_session([os.environ["Q_S1"], os.environ["Q_S2"]]) or []
answers = [a if isinstance(a, str) else repr(a) for a in list(answers)]
print("LABJSON:" + json.dumps({
    "empty_ok": isinstance(nothing, (list, tuple)) and len(nothing) == 0,
    "count": len(answers),
    "first": answers[0] if len(answers) > 0 else "",
    "second": answers[1] if len(answers) > 1 else "",
}))
PY
)"
    [ -z "$out" ] && { fail_no_output "run_session did not run to completion" "$rid"; return; }
    n="$(json_field "$out" '.count' '0')"
    a1="$(json_field "$out" '.first' '')"
    a2="$(json_field "$out" '.second' '')"
    first="$(word_or none "$(trace_field "$rid" '.questions[0].planned | tostring')")"
    second="$(word_or none "$(trace_field "$rid" '.questions[1].planned | tostring')")"
    turns="$(word_or 0 "$(trace_field "$rid" '.chat_turns')")"
    capped="$(word_or unknown "$(trace_field "$rid" '.capped')")"
    empty_ok="$(json_field "$out" '.empty_ok' 'unknown')"
    if [ "$n" = "2" ] && [ "$empty_ok" = "true" ] \
       && [ "$first" = '["list_tables","get_table_schema","execute_sql"]' ] \
       && [ "$second" = '["execute_sql"]' ] && [ "$capped" = "false" ] \
       && [ "$turns" -le $((CEILING * 2)) ] 2>/dev/null \
       && contains_all "$want1" "$a1" && contains_all "$want2" "$a2"; then
        report "success" "The second question reused what the first turn discovered: it went straight to the query, and both answers carry the values the database produced"
    else
        report "failed" "run_session did not answer both questions on one shared message list. It must return one answer per question in order, return an empty list when handed an empty list of questions, keep every earlier message so the second question needs only execute_sql, and both answers must carry the database values $want1 and $want2. Observed: answers returned=$n, empty list for no questions=$empty_ok, tools requested for the first question=$first, tools requested for the second=$second, model turns used across both=$turns, first value absent from an answer=${MISSING_VALUE:-none}"
    fi
}
Test04
