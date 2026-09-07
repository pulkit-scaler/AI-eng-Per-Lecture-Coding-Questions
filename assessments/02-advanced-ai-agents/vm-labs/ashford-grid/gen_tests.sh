#!/bin/bash
# Regenerate test-cases/scripts/script_01..05.sh from one shared preamble plus
# one body per behavioural theme. The platform runs every file in the test
# scripts/ folder as a test, so each script must be fully self-contained --
# hence the duplicated preamble, emitted here so it can never drift.
#
# The platform accepts at most FIVE test scripts, so each script asserts the
# cluster of facts one theme implies and is worth 10 points.
#
# NO APOSTROPHES inside any <<'PY' ... PY body. That heredoc sits inside a $( )
# command substitution and bash counts quote characters while scanning for the
# matching paren, so a single apostrophe makes the generated file unparseable in a
# place that looks nothing like the cause. build.sh enforces this.
#
# The bodies below are written into an UNQUOTED heredoc, so every dollar sign that
# must survive to run time is escaped as \$ and every graded input is spliced in
# unescaped. build.sh runs bash -n on the result.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$DIR/test-cases/scripts"
mkdir -p "$OUT"

# ---------------------------------------------------------------------------
# Graded inputs. Deliberately disjoint from every question, request and query
# that appears in problem-statement.md or check_local.py, so no published worked
# example is itself a graded case. Written without apostrophes so they are safe
# to carry through the shell.
# ---------------------------------------------------------------------------
Q_BAD="Which feeders carry more than ten megawatts of peak load?"
SQL_BAD="SELECT feeder_code, peak_load_mw FROM feeders WHERE capacity_mw > 10"
Q_GOOD="Which feeders are rated above ten megawatts?"
SQL_GOOD="SELECT feeder_code, capacity_mw FROM feeders WHERE capacity_mw > 10 ORDER BY capacity_mw DESC"
BAD_COLUMN="peak_load_mw"

Q_CONVERGE="What is the total feeder capacity in megawatts for each region?"
CONVERGE_ATTEMPTS=4
CONVERGE_EXPECTED=2
Q_UNSAT="Which feeder has the worst reactive power factor?"
UNSAT_ATTEMPTS=3

Q_EXEC="Which outage cause affected the most customers in total?"
EXEC_ATTEMPTS=3
EXEC_EXPECTED=3
EXEC_ERROR_ONE="no such column: cause_type"
EXEC_ERROR_TWO="no such column: affected_customers"

R_OUTAGE="How long was the north loop down after the storm last month, and how many homes went dark?"
R_CAPACITY="Can we hand another twelve megawatts to the Tarrant Quay run without pushing it past its rating?"
R_LOAD="Give me the megawatt draw over the last few readings so I can see where it is heading."
R_SCHEMA="Remind me what fields the register keeps for each substation."

SQL_BLOCKED="SELECT * FROM load_readings"
SQL_CLEAN="SELECT cause, COUNT(*) AS n FROM outages GROUP BY cause"
# Four guard calls are each held for a fixed interval. Run together they finish in
# about one interval, so busy time divided by elapsed span lands near 4; run one
# after another it lands near 1. Reported in tenths by the endpoint so the check
# compares integers. Measured on the authoring host: 39-40 tenths for the
# reference and every concurrent alternative, 10 tenths for the sequential probe,
# so 25 separates them with a wide margin. The wait is on the endpoint rather than
# on the CPU, so the margin does not depend on the core count of the VM.
MIN_FACTOR=25

# Log files were a bring-up aid and are OFF by default now that the lab is
# validated. Re-enable for a debugging session with:  TEST_LOGGING=on ./gen_tests.sh
# The single-verdict guarantee (report() + EXIT trap) is NOT part of this switch:
# it stays in both modes, because a script that dies before reporting would
# otherwise score a silent zero with no diagnostic.
TEST_LOGGING="${TEST_LOGGING:-off}"

if [ "$TEST_LOGGING" = "off" ]; then
read -r -d '' LOGGING_BLOCK <<'LOGOFF' || true
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
LOGOFF
else
read -r -d '' LOGGING_BLOCK <<'LOGON' || true
# Every stderr line and learner traceback is captured to a per-check log file.
TC="$(basename "${BASH_SOURCE[0]}" .sh | sed 's/[^0-9]//g')"
LOG_DIR="${LOG_DIR:-/tmp/ashford-lab-logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp"
LOG_TC="${LOG_DIR}/tc${TC}.log"
: > "$LOG_TC" 2>/dev/null || true
exec 2>>"$LOG_TC"          # stderr to the log; stdout stays clean for the verdict
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S' 2>/dev/null || echo -)" "$*" >>"$LOG_TC" 2>/dev/null || true; }
log_verdict() {
    printf '[%s] TC%s %-7s %s\n' "$(date '+%H:%M:%S' 2>/dev/null || echo -)" \
        "$TC" "$1" "$2" >>"${LOG_DIR}/all-tests.log" 2>/dev/null || true
}
log_file() { sed 's/^/    | /' "$1" >>"$LOG_TC" 2>/dev/null || true; }
learner_log() { printf '%s/learner_%s.log' "$LOG_DIR" "$1"; }
LOGON
fi

read -r -d '' PREAMBLE <<PRE || true
DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
source "/usr/local/bin/judge/test/common.sh" 2>/dev/null || source "\$DIR/common.sh" 2>/dev/null || true
type print_status >/dev/null 2>&1 || print_status() { echo "RESULT:\$1 | \$2"; }

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
${LOGGING_BLOCK}

# One verdict per script, whatever happens. report() is idempotent, so the EXIT
# trap can safely supply a diagnostic failure if the body never reached one.
STATUS_SENT=0
report() {
    if [ "\$STATUS_SENT" -eq 1 ]; then log "suppressed extra verdict: \$1 | \$2"; return 0; fi
    STATUS_SENT=1
    log "VERDICT \$1 | \$2"
    log_verdict "\$1" "\$2"
    print_status "\$1" "\$2"
}

LAB_DIR="\${LAB_DIR:-/home/user/ashford-grid}"
SVC_URL="\${SVC_URL:-http://127.0.0.1:8836}"
SVC_BIN="\${SVC_BIN:-/opt/ashford-svc/gridd.py}"
GKEY="X-Grader-Key: ashford-grader-q7w2"
GPATH="__agq7w2"
PY="\${PY:-python3}"
TO="\$(command -v timeout || command -v gtimeout || true)"
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
    local rc=\$?
    if id -u user >/dev/null 2>&1; then
        case "\$LAB_DIR" in
            ""|"/") : ;;
            *) chown -R user:user "\$LAB_DIR" >/dev/null 2>&1 ;;
        esac
    fi
    log "script exiting rc=\$rc after \${SECONDS}s"
    printf 'script_%s %ss\n' "\$TC" "\$SECONDS" >>/tmp/ashford_timing.log 2>/dev/null || true
    report "failed" "TC\${TC} ended without reaching a verdict (rc=\$rc)"
}
trap on_exit EXIT

log "TC\${TC} starting"

# --- time budget --------------------------------------------------------
# The portal kills a test case that runs much beyond two minutes and reports a
# blocking process instead of a score, so every wait in this script is bounded:
# 12s waiting for the endpoint + 55s for the one learner run + at most ten 5s
# grader calls is about 117s worst case. Setup already started the endpoint and
# paid the import cost, so a healthy VM finishes in a couple of seconds; these
# numbers only cap the pathological run. Nothing below may loop without one of
# these constants.
SVC_WAIT=\${SVC_WAIT:-12}
RUN_BUDGET=\${RUN_BUDGET:-55}
CURL_MAX=\${CURL_MAX:-5}
DEPS_WAIT=\${DEPS_WAIT:-20}
DEPS_READY_FILE="\${DEPS_READY_FILE:-/var/log/ashford-lab/deps.ready}"

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
    [ -f "\$DEPS_READY_FILE" ] && return 0
    "\$PY" -c 'import openai' >/dev/null 2>&1 && return 0
    local i
    for i in \$(seq 1 "\$DEPS_WAIT"); do
        sleep 1
        [ -f "\$DEPS_READY_FILE" ] && return 0
    done
    "\$PY" -c 'import openai' >/dev/null 2>&1
}

# jq is load-bearing on BOTH sides: the platform helper builds its verdict line with
# jq -n, and every expected value below is read out of JSON with jq -r. Without it
# this check cannot produce a verdict at all, let alone a correct one, so it is an
# environment fault and must be reported as one.
ensure_tools() {
    local missing=""
    command -v curl >/dev/null 2>&1 || missing="\${missing} curl"
    command -v jq   >/dev/null 2>&1 || missing="\${missing} jq"
    [ -z "\$missing" ] && return 0
    report "failed" "This VM is missing the command-line tool(s)\${missing}, which the checks need to reach the model endpoint and read its JSON. This is an environment fault, not a problem with your code: the install log is /var/log/ashford-lab/pip.log and re-provisioning the lab on a fresh VM is the remedy"
    return 1
}

# Bound the learner run even where coreutils timeout(1) is absent (macOS has
# none, and a silently missing bound reports a stalled run as a very slow test
# case instead of killing it, which is how an unbounded run passes for a fast
# one during authoring). The fallback watchdog needs nothing but the shell.
run_bounded() {
    if [ -n "\$TO" ]; then
        "\$TO" -k 5 "\$RUN_BUDGET" "\$@"
        return \$?
    fi
    "\$@" &
    local pid=\$! rc=0 wd
    ( sleep "\$RUN_BUDGET"; kill -9 "\$pid" ) >/dev/null 2>&1 &
    wd=\$!
    wait "\$pid"; rc=\$?
    kill "\$wd" >/dev/null 2>&1
    return \$rc
}

ensure_service() {
    curl -sf -m "\$CURL_MAX" "\${SVC_URL}/health" >/dev/null 2>&1 && return 0
    [ -f "\$SVC_BIN" ] || return 1
    setsid nohup "\$PY" "\$SVC_BIN" >/tmp/ashford_svc.log 2>&1 </dev/null &
    local i
    for i in \$(seq 1 "\$SVC_WAIT"); do
        curl -sf -m 2 "\${SVC_URL}/health" >/dev/null 2>&1 && return 0
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
    curl -sf -m "\$CURL_MAX" -H "\$GKEY" --get \\
        --data-urlencode "\$2" --data-urlencode "\$3" \\
        "\${SVC_URL}/\${GPATH}/oracle" 2>/dev/null | jq -r "\$1"
}

trace_field() {
    curl -sf -m "\$CURL_MAX" -H "\$GKEY" \\
        "\${SVC_URL}/\${GPATH}/trace?run=\$1" 2>/dev/null | jq -r "\$2"
}

# run_learner <run-id>  (python harness on stdin) -> echoes the LABJSON payload
run_learner() {
    local rid="\$1" tmp rc
    # Trailing X characters only: a suffix after them is not substituted by every
    # mktemp, which would hand back one fixed filename and collide between runs.
    tmp="\$(mktemp /tmp/ashford_h_XXXXXX)" || return 1
    cat > "\$tmp"
    local out; out="\$(learner_log "\$rid")"
    ( cd "\$LAB_DIR" && export ASHFORD_RUN_ID="\$rid" PYTHONPATH="\$LAB_DIR" && \\
        run_bounded "\$PY" "\$tmp" ) >"\$out" 2>&1
    rc=\$?
    rm -f "\$tmp"
    log "learner run \$rid exited rc=\$rc; output in \$out"
    log_file "\$out"
    grep -o 'LABJSON:.*' "\$out" | head -1 | cut -c9-
    return \$rc
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
    local what="\$1"; shift
    if "\$@"; then return 0; fi
    BROKEN_N=\$((BROKEN_N + 1))
    [ -n "\$BROKEN" ] || BROKEN="\$what"
    return 1
}
eq() { [ "\$1" = "\$2" ]; }
ge() { [ "\${1:-0}" -ge "\${2:-0}" ] 2>/dev/null; }
numeq() { [ "\${1:-x}" = "\${2:-y}" ]; }
empty() { [ -z "\$1" ]; }
first_break() {
    if [ "\$BROKEN_N" -le 1 ]; then printf '%s' "\$BROKEN"
    else printf '%s (and %d other requirement(s))' "\$BROKEN" "\$((BROKEN_N - 1))"; fi
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
    if [ -s "\$1" ]; then
        printf 'its output is in %s' "\$1"
    else
        printf 'it printed nothing at all, so %s is empty. A module that only defines its functions and never calls them exits quietly like this, and so does one that raises before reaching the end. Run  cd %s && python3 check_local.py  and confirm every task prints a result before you submit' "\$1" "\$LAB_DIR"
    fi
}

# log_tail <logfile> : the last few lines of a log, flattened onto one line and
# capped, so a traceback arrives WITH the failure and the learner never has to cat
# anything. Returns nothing when there is nothing to show.
log_tail() {
    [ -s "\$1" ] || return 0
    tail -n 3 "\$1" 2>/dev/null | tr '\\n' '|' | sed 's/|/ | /g; s/ | \$//' | cut -c1-280
}

# fail_no_output <what-did-not-finish> <run-id>
# Three distinguishable outcomes, because the fix differs for each: the run was
# stopped at the time limit, the run raised, or the run printed nothing at all.
fail_no_output() {
    local out; out="\$(learner_log "\$2")"
    local tail_text; tail_text="\$(log_tail "\$out")"
    case "\$tail_text" in
        *Killed*|*Terminated*|*"signal 9"*|*"timed out"*)
            report "failed" "\$1: it was still running after \${RUN_BUDGET}s and was stopped. Something in it does not return. Check that every loop is bounded by the max_attempts you were passed, and that nothing waits on a model call that was never made. Last output before it was stopped: \$tail_text [full output in \$out]"
            return 0 ;;
    esac
    if [ -n "\$tail_text" ]; then
        report "failed" "\$1: Python raised before it could print a result: \$tail_text [full output in \$out]"
    else
        report "failed" "\$1: \$(run_evidence "\$out")"
    fi
}

# Guard: an unreadable expected value must never silently match an empty result.
require_expected() {
    if [ -z "\$1" ] || [ "\$1" = "null" ]; then
        report "failed" "The grader could not read the expected result from the model endpoint on \${SVC_URL}, so it has nothing to compare against. This is an environment fault, not a problem with your code: confirm curl -s \${SVC_URL}/health answers, and re-provision the lab on a fresh VM if it does not"
        return 1
    fi
    return 0
}

# Refuse an untouched project in about a second rather than timing out with no
# message. Both plausible causes are named, because from the outside they look the
# same.
require_started() {
    local left
    if [ ! -f "\${LAB_DIR}/solution.py" ]; then
        report "failed" "No solution.py in \${LAB_DIR} - the checks read the file you write there"
        return 1
    fi
    left="\$(grep -c 'raise NotImplementedError' "\${LAB_DIR}/solution.py" 2>/dev/null | tr -d ' ')"
    # Both conditions, so a learner whose own helpers happen to raise
    # NotImplementedError is never refused: a finished solution always contains a
    # model call, because there is no other way to reach the endpoint.
    if [ "\${left:-0}" -ge 5 ] \\
       && ! grep -q 'chat.completions' "\${LAB_DIR}/solution.py" 2>/dev/null; then
        report "failed" "\${LAB_DIR}/solution.py is still the untouched starter - write the five functions, then run python3 check_local.py from \${LAB_DIR} before submitting"
        return 1
    fi
    return 0
}

preflight() {
    ensure_deps || { report "failed" "The Python dependency for this lab (openai) is not installed on this VM, so import solution cannot succeed. This is an environment fault, not a problem with your code: check /var/log/ashford-lab/pip.log, and re-provision the lab on a fresh VM if the install failed"; return 1; }
    ensure_tools || return 1
    ensure_service || { report "failed" "The model endpoint is not answering on \${SVC_URL}/health, so nothing can be graded. Leave the endpoint running: it is started by provisioning, and \$SVC_BIN is what restarts it. Its log is /tmp/ashford_svc.log"; return 1; }
    require_started || return 1
    return 0
}
PRE

emit() {
    # emit <NN> <headline> <body-file>
    local nn="$1" headline="$2" body="$3"
    {
        echo '#!/bin/bash'
        echo "# TC${nn} (10 pts): ${headline}"
        printf '%s\n' "$PREAMBLE"
        cat "$body"
    } > "$OUT/script_${nn}.sh"
    chmod +x "$OUT/script_${nn}.sh"
    rm -f "$body"
    bash -n "$OUT/script_${nn}.sh"
}

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# --- TC01 -----------------------------------------------------------------
cat > "$TMPD/b01" <<BODY

Test01() {
    preflight || return
    local want_reason want_valid rid out bad_valid bad_reason good_valid
    local critiques ran saw_candidate
    want_reason="\$(oracle2 '.reason' "kind=critique" "sql=${SQL_BAD}")"
    require_expected "\$want_reason" || return
    want_valid="\$(oracle2 '.valid' "kind=critique" "sql=${SQL_GOOD}")"
    require_expected "\$want_valid" || return
    rid="tc01_\$\$"
    out="\$(QB="${Q_BAD}" SB="${SQL_BAD}" QG="${Q_GOOD}" SG="${SQL_GOOD}" \\
            run_learner "\$rid" <<'PY'
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
    [ -z "\$out" ] && { fail_no_output "critique_query() did not run to completion" "\$rid"; return; }
    bad_valid="\$(printf '%s' "\$out" | jq -r '.bad_valid')"
    bad_reason="\$(printf '%s' "\$out" | jq -r '.bad_reason')"
    good_valid="\$(printf '%s' "\$out" | jq -r '.good_valid')"
    # Two real round trips, both carrying the candidate query, and nothing run
    # against the database: the audit trail for this run has to be empty.
    critiques="\$(trace_field "\$rid" '.kinds.critique')"
    saw_candidate="\$(trace_field "\$rid" '[.critiques[] | select(.sql | contains("${BAD_COLUMN}"))] | length')"
    ran="\$(trace_field "\$rid" '.executed | length')"
    need "critique_query returned valid=true for a candidate naming a column the schema does not have; it must return valid=False" eq "\$bad_valid" "false"
    need "the reason string was edited instead of being passed through unchanged" eq "\$bad_reason" "\$want_reason"
    need "critique_query returned valid=false for a candidate whose every column is real; it must return valid=True" eq "\$good_valid" "true"
    need "critique_query did not send a review turn for each candidate, so the reviewer never saw them" ge "\${critiques:-0}" 2
    need "the review turn did not carry the candidate query itself, so the reviewer had nothing to review" ge "\${saw_candidate:-0}" 1
    need "critique_query executed a query against the database; it must review the candidate without running anything" numeq "\${ran:-1}" 0
    if [ "\$BROKEN_N" -eq 0 ]; then
        report "success" "A candidate naming a column the schema does not have is reviewed as invalid with the reason that names it, a candidate over real columns is reviewed as valid, and neither candidate was ever run against the database"
    else
        report "failed" "critique_query: \$(first_break). Observed: first candidate valid=\${bad_valid:-unknown} reason=[\${bad_reason:-none}] (expected valid=false reason=[\${want_reason:-none}]), second candidate valid=\${good_valid:-unknown} (expected true), \${critiques:-0} review turns of which \${saw_candidate:-0} carried the candidate (expected at least 2 and 1), \${ran:-0} queries run against the database (expected 0)"
    fi
}
Test01
BODY
emit 01 "the review gate rejects a bad query by name and never runs it" "$TMPD/b01"

# --- TC02 -----------------------------------------------------------------
cat > "$TMPD/b02" <<BODY

Test02() {
    preflight || return
    local want_result want_sql rid out result attempts accepted
    local u_attempts u_accepted u_result refines ran_ok ran_bad
    want_result="\$(oracle2 '.result' "kind=answer" "q=${Q_CONVERGE}")"
    require_expected "\$want_result" || return
    want_sql="\$(oracle2 '.sql' "kind=answer" "q=${Q_CONVERGE}")"
    require_expected "\$want_sql" || return
    rid="tc02_\$\$"
    out="\$(QC="${Q_CONVERGE}" NC="${CONVERGE_ATTEMPTS}" \\
            QU="${Q_UNSAT}" NU="${UNSAT_ATTEMPTS}" run_learner "\$rid" <<'PY'
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
    [ -z "\$out" ] && { fail_no_output "self_improving_query() did not run to completion" "\$rid"; return; }
    result="\$(printf '%s' "\$out" | jq -r '.result')"
    attempts="\$(printf '%s' "\$out" | jq -r '.attempts')"
    accepted="\$(printf '%s' "\$out" | jq -r '.accepted')"
    u_attempts="\$(printf '%s' "\$out" | jq -r '.u_attempts')"
    u_accepted="\$(printf '%s' "\$out" | jq -r '.u_accepted')"
    u_result="\$(printf '%s' "\$out" | jq -r '.u_result')"
    # A refinement that actually carried the review reason, at least one query run
    # successfully, and NOTHING run that the review had rejected.
    refines="\$(trace_field "\$rid" '[.refines[] | select(.used_feedback)] | length')"
    ran_ok="\$(trace_field "\$rid" '[.executed[] | select(.ok)] | length')"
    ran_bad="\$(trace_field "\$rid" '[.executed[] | select(.ok == false)] | length')"
    need "the answerable question did not return the result execute_sql gives for the correct query" eq "\$result" "\$want_result"
    need "attempts was wrong for the answerable question: it counts CANDIDATES REVIEWED, one per critique call, and the draft plus one repair is ${CONVERGE_EXPECTED}" eq "\$attempts" "${CONVERGE_EXPECTED}"
    need "accepted was not True even though a candidate passed review" eq "\$accepted" "true"
    need "the repair request did not carry the reviewer reason, so the same query came back and the loop never converged" ge "\${refines:-0}" 1
    need "the accepted query was never executed, so there is no result to report" ge "\${ran_ok:-0}" 1
    need "a query that failed review was executed anyway; only a candidate that passed review may run" numeq "\${ran_bad:-1}" 0
    need "attempts was wrong for the unanswerable question: at the ceiling the loop stops without asking for one more repair, so with max_attempts=${UNSAT_ATTEMPTS} it must report exactly ${UNSAT_ATTEMPTS}" eq "\$u_attempts" "${UNSAT_ATTEMPTS}"
    need "accepted was not False for a question no candidate could satisfy" eq "\$u_accepted" "false"
    need "result was not None for a question where nothing ever passed review" empty "\$u_result"
    if [ "\$BROKEN_N" -eq 0 ]; then
        report "success" "The first draft fails review, the refined query passes it and returns the correct result in ${CONVERGE_EXPECTED} attempts, a question the schema cannot answer stops at the attempt limit, and no rejected query was ever run"
    else
        report "failed" "self_improving_query: \$(first_break). Observed for the answerable question: result=[\${result:-none}] attempts=\${attempts:-unknown} accepted=\${accepted:-unknown} (expected result=[\${want_result:-none}] from the query [\${want_sql:-none}], attempts=${CONVERGE_EXPECTED}, accepted=true). For the unanswerable question: attempts=\${u_attempts:-unknown} accepted=\${u_accepted:-unknown} result=[\${u_result:-none}] (expected attempts=${UNSAT_ATTEMPTS}, accepted=false, result empty). The endpoint recorded \${refines:-0} repair requests carrying the reviewer reason (expected at least 1), \${ran_ok:-0} successful executions (expected at least 1) and \${ran_bad:-0} executions of a rejected query (expected 0)"
    fi
}
Test02
BODY
emit 02 "the review and refine loop converges and is bounded" "$TMPD/b02"

# --- TC03 -----------------------------------------------------------------
cat > "$TMPD/b03" <<BODY

Test03() {
    preflight || return
    local want_result rid out result attempts succeeded memory blob
    local mem_one mem_two carried_first carried_both failures
    want_result="\$(oracle2 '.result' "kind=answer" "q=${Q_EXEC}")"
    require_expected "\$want_result" || return
    rid="tc03_\$\$"
    out="\$(QE="${Q_EXEC}" NE="${EXEC_ATTEMPTS}" run_learner "\$rid" <<'PY'
import json, os, sys
sys.path.insert(0, ".")
import solution
answer = solution.execute_with_feedback(os.environ["QE"], int(os.environ["NE"]))
memory = list(answer.get("error_memory") or [])
print("LABJSON:" + json.dumps({
    "result": str(answer.get("result") or "").strip(),
    "attempts": answer.get("attempts"),
    "succeeded": bool(answer.get("succeeded")),
    "memory_len": len(memory),
    "memory_blob": json.dumps(memory, default=str),
}))
PY
)"
    [ -z "\$out" ] && { fail_no_output "execute_with_feedback() did not run to completion" "\$rid"; return; }
    result="\$(printf '%s' "\$out" | jq -r '.result')"
    attempts="\$(printf '%s' "\$out" | jq -r '.attempts')"
    succeeded="\$(printf '%s' "\$out" | jq -r '.succeeded')"
    memory="\$(printf '%s' "\$out" | jq -r '.memory_len')"
    blob="\$(printf '%s' "\$out" | jq -r '.memory_blob')"
    mem_one=no; mem_two=no
    printf '%s' "\$blob" | grep -q "${EXEC_ERROR_ONE}" && mem_one=yes
    printf '%s' "\$blob" | grep -q "${EXEC_ERROR_TWO}" && mem_two=yes
    # The database error has to reach the repair step, and by the second repair the
    # accumulated memory has to carry the first failure alongside the second.
    carried_first="\$(trace_field "\$rid" '[.refines[] | select(.feedback_seen | contains("${EXEC_ERROR_ONE}"))] | length')"
    carried_both="\$(trace_field "\$rid" '[.refines[] | select((.feedback_seen | contains("${EXEC_ERROR_ONE}")) and (.feedback_seen | contains("${EXEC_ERROR_TWO}")))] | length')"
    failures="\$(trace_field "\$rid" '[.executed[] | select(.ok == false)] | length')"
    need "the retry did not return the result execute_sql gives for the corrected query" eq "\$result" "\$want_result"
    need "attempts was wrong: it counts QUERIES RUN, one per execute_sql call, and two rejections plus the success is ${EXEC_EXPECTED}" eq "\$attempts" "${EXEC_EXPECTED}"
    need "succeeded was not True even though a query eventually ran without an error" eq "\$succeeded" "true"
    need "error_memory did not hold one entry per rejection; two queries were rejected, so it must hold 2" eq "\$memory" "2"
    need "the first database error is missing from error_memory" eq "\$mem_one" "yes"
    need "the second database error is missing from error_memory" eq "\$mem_two" "yes"
    need "the repair request did not carry the database error text, so the repair had nothing to correct" ge "\${carried_first:-0}" 1
    need "the second repair request carried only the newest error; it must carry the whole accumulated error memory, oldest failure included" ge "\${carried_both:-0}" 1
    need "the number of rejected executions on record is not 2, so the loop did not run each corrected query in turn" numeq "\${failures:-0}" 2
    if [ "\$BROKEN_N" -eq 0 ]; then
        report "success" "The rejected query reaches the repair step with the database error attached, the accumulated memory carries the earlier failure into the second repair, and the retry returns the correct result"
    else
        report "failed" "execute_with_feedback: \$(first_break). Observed: result=[\${result:-none}] attempts=\${attempts:-unknown} succeeded=\${succeeded:-unknown} with \${memory:-0} error_memory entries (expected result=[\${want_result:-none}], attempts=${EXEC_EXPECTED}, succeeded=true, 2 entries). The first database error was present in error_memory: \${mem_one:-unknown}; the second: \${mem_two:-unknown}. The endpoint saw \${carried_first:-0} repair requests carrying the first error and \${carried_both:-0} carrying both errors together (expected at least 1 of each), and \${failures:-0} rejected executions (expected 2)"
    fi
}
Test03
BODY
emit 03 "the database error is carried forward and the retry succeeds" "$TMPD/b03"

# --- TC04 -----------------------------------------------------------------
cat > "$TMPD/b04" <<BODY

Test04() {
    preflight || return
    local rid out ok want_cats want_results got_cats got_results value
    local c1 c2 c3 c4 r1 r2 r3 r4 traced traced_cats desk_hits
    c1="\$(oracle2 '.category' "kind=route" "request=${R_OUTAGE}")"
    c2="\$(oracle2 '.category' "kind=route" "request=${R_CAPACITY}")"
    c3="\$(oracle2 '.category' "kind=route" "request=${R_LOAD}")"
    c4="\$(oracle2 '.category' "kind=route" "request=${R_SCHEMA}")"
    r1="\$(oracle2 '.result' "kind=route" "request=${R_OUTAGE}")"
    r2="\$(oracle2 '.result' "kind=route" "request=${R_CAPACITY}")"
    r3="\$(oracle2 '.result' "kind=route" "request=${R_LOAD}")"
    r4="\$(oracle2 '.result' "kind=route" "request=${R_SCHEMA}")"
    for value in "\$c1" "\$c2" "\$c3" "\$c4" "\$r1" "\$r2" "\$r3" "\$r4"; do
        require_expected "\$value" || return
    done
    want_cats="\${c1},\${c2},\${c3},\${c4}"
    want_results="\${r1} ;; \${r2} ;; \${r3} ;; \${r4}"
    rid="tc04_\$\$"
    out="\$(R1="${R_OUTAGE}" R2="${R_CAPACITY}" R3="${R_LOAD}" R4="${R_SCHEMA}" \\
            run_learner "\$rid" <<'PY'
import json, os, sys
sys.path.insert(0, ".")
import solution
rows = []
for name in ("R1", "R2", "R3", "R4"):
    answer = solution.route_request(os.environ[name])
    rows.append({"category": str(answer.get("category") or "").strip(),
                 "result": str(answer.get("result") or "").strip()})
print("LABJSON:" + json.dumps({
    "categories": ",".join(row["category"] for row in rows),
    "results": " ;; ".join(row["result"] for row in rows),
}))
PY
)"
    [ -z "\$out" ] && { fail_no_output "route_request() did not run to completion" "\$rid"; return; }
    got_cats="\$(printf '%s' "\$out" | jq -r '.categories')"
    got_results="\$(printf '%s' "\$out" | jq -r '.results')"
    # The category handed back must be the one the endpoint classified, in the same
    # order, and every desk must have answered from the database.
    traced_cats="\$(trace_field "\$rid" '[.routes[].category] | join(",")')"
    traced="\$(trace_field "\$rid" '.routes | length')"
    desk_hits="\$(trace_field "\$rid" '[.executed[] | select(.ok)] | length')"
    ok=yes
    need "the categories returned are not the ones the classification step produced; return the category from the reply rather than deciding it yourself" eq "\$got_cats" "\$want_cats"
    need "at least one request reached the wrong desk, or its line was reformatted; return exactly what the handler gives you" eq "\$got_results" "\$want_results"
    need "the classification turns the endpoint recorded do not match the categories returned, in order" eq "\$traced_cats" "\$want_cats"
    need "route_request did not send exactly one classification turn per request; four requests need four turns" numeq "\${traced:-0}" 4
    need "the desks did not answer from the database; call the handler rather than composing its line" ge "\${desk_hits:-0}" 4
    [ "\$BROKEN_N" -eq 0 ] && ok=yes || ok=no
    if [ "\$ok" = yes ]; then
        report "success" "Every request is classified through the endpoint and dispatched to the desk that matches the classification, and every desk answered from the database"
    else
        report "failed" "route_request: \$(first_break). Observed categories [\${got_cats:-none}] with desk lines [\${got_results:-none}]; expected categories [\${want_cats:-none}] with desk lines [\${want_results:-none}]. The endpoint recorded \${traced:-0} classification turns (expected 4) returning [\${traced_cats:-none}] and \${desk_hits:-0} desk queries against the database (expected at least 4)"
    fi
}
Test04
BODY
emit 04 "requests are classified and dispatched to the matching desk" "$TMPD/b04"

# --- TC05 -----------------------------------------------------------------
cat > "$TMPD/b05" <<BODY

Test05() {
    preflight || return
    local want_blocked_by want_names rid out blocked blocked_by guard_count names
    local clean_blocked clean_clear guards_seen tenths_blocked tenths_clean
    want_blocked_by="\$(oracle2 '.blocked_by | join(",")' "kind=guards" "sql=${SQL_BLOCKED}")"
    require_expected "\$want_blocked_by" || return
    want_names="\$(oracle2 '[.guards[].guard] | sort | join(",")' "kind=guards" "sql=${SQL_BLOCKED}")"
    require_expected "\$want_names" || return
    rid="tc05_\$\$"
    out="\$(SB="${SQL_BLOCKED}" SC="${SQL_CLEAN}" run_learner "\$rid" <<'PY'
import json, os, sys
sys.path.insert(0, ".")
import solution


def summarise(report):
    guards = list(report.get("guards") or [])
    return {
        "blocked": bool(report.get("blocked")),
        "blocked_by": ",".join(sorted(str(g) for g in
                                      (report.get("blocked_by") or []))),
        "count": len(guards),
        "names": ",".join(sorted(str(g.get("guard") or "") for g in guards)),
        "clear": len([g for g in guards if g.get("passes")]),
    }


blocked = solution.parallel_guards(os.environ["SB"])
clean = solution.parallel_guards(os.environ["SC"])
print("LABJSON:" + json.dumps({"blocked": summarise(blocked),
                               "clean": summarise(clean)}))
PY
)"
    [ -z "\$out" ] && { fail_no_output "parallel_guards() did not run to completion" "\$rid"; return; }
    blocked="\$(printf '%s' "\$out" | jq -r '.blocked.blocked')"
    blocked_by="\$(printf '%s' "\$out" | jq -r '.blocked.blocked_by')"
    guard_count="\$(printf '%s' "\$out" | jq -r '.blocked.count')"
    names="\$(printf '%s' "\$out" | jq -r '.blocked.names')"
    clean_blocked="\$(printf '%s' "\$out" | jq -r '.clean.blocked')"
    clean_clear="\$(printf '%s' "\$out" | jq -r '.clean.clear')"
    # Every guard really asked the endpoint, and the endpoint timed the requests:
    # busy time over elapsed span is near the guard count when the calls overlap and
    # near one when they are made one after another. Reported in tenths so the
    # comparison here is integer arithmetic.
    guards_seen="\$(trace_field "\$rid" '.guards | length')"
    tenths_blocked="\$(trace_field "\$rid" '([.concurrency | to_entries[] | select(.key | test("load_readings")) | .value.factor_tenths] | max) // 0')"
    tenths_clean="\$(trace_field "\$rid" '([.concurrency | to_entries[] | select(.key | test("GROUP BY cause")) | .value.factor_tenths] | max) // 0')"
    need "blocked was not True even though a guard did not pass; any single failing guard blocks the candidate" eq "\$blocked" "true"
    need "blocked_by does not hold the sorted names of exactly the guards that did not pass" eq "\$blocked_by" "\$want_blocked_by"
    need "guards did not hold one verdict per guard; all four must be asked every time, with no short-circuit" eq "\$guard_count" "4"
    need "the guard names in the verdicts are not the four names from GUARD_NAMES" eq "\$names" "\$want_names"
    need "blocked was not False for a candidate every guard passed" eq "\$clean_blocked" "false"
    need "not all four guards passed the all-clear candidate" eq "\$clean_clear" "4"
    need "the endpoint did not see four guard turns per candidate; two candidates need eight turns" numeq "\${guards_seen:-0}" 8
    need "the four guard requests for the blocked candidate did not overlap in time: at least ${MIN_FACTOR} tenths of peak overlap is required, and four requests made one after another measure about 10" ge "\${tenths_blocked:-0}" "${MIN_FACTOR}"
    need "the four guard requests for the all-clear candidate did not overlap in time: at least ${MIN_FACTOR} tenths of peak overlap is required, and four requests made one after another measure about 10" ge "\${tenths_clean:-0}" "${MIN_FACTOR}"
    if [ "\$BROKEN_N" -eq 0 ]; then
        report "success" "All four guards ran for each candidate and their calls overlapped in time rather than following one another; one failing guard blocks the aggregate verdict and an all-clear candidate passes it"
    else
        report "failed" "parallel_guards: \$(first_break). Observed for the blocked candidate: blocked=\${blocked:-unknown} blocked_by=[\${blocked_by:-none}] from \${guard_count:-0} verdicts named [\${names:-none}] (expected blocked=true, blocked_by=[\${want_blocked_by:-none}], 4 verdicts named [\${want_names:-none}]). For the all-clear candidate: blocked=\${clean_blocked:-unknown} with \${clean_clear:-0} of 4 guards passing (expected blocked=false and 4). The endpoint saw \${guards_seen:-0} guard turns in total (expected 8) and measured overlap of \${tenths_blocked:-0} and \${tenths_clean:-0} tenths for the two candidates against a required ${MIN_FACTOR} tenths"
    fi
}
Test05
BODY
emit 05 "the guards really run together and aggregate correctly" "$TMPD/b05"

echo "generated:"
ls -1 "$OUT"/script_*.sh
