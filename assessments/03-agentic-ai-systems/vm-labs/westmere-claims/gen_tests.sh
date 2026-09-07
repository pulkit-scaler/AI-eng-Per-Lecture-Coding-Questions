#!/bin/bash
# Regenerate test-cases/scripts/script_01..05.sh from one shared preamble.
# The platform runs every file in the test scripts folder as a test, so there is
# nowhere to put a shared helper - and generated duplication cannot drift while
# hand-edited duplication always does.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$DIR/test-cases/scripts"
mkdir -p "$OUT"

preamble() {
cat <<'PRE'
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
PRE
}

emit() {
    local n="$1" title="$2" body="$3"
    {
        echo '#!/bin/bash'
        echo "# TC${n} (10 pts): ${title}"
        preamble
        echo ""
        cat "$body"
    } > "$OUT/script_${n}.sh"
    chmod +x "$OUT/script_${n}.sh"
    bash -n "$OUT/script_${n}.sh"
    echo "  wrote script_${n}.sh"
}

BODY="$(mktemp -d)"
trap 'rm -rf "$BODY"' EXIT

# ---------------------------------------------------------------- TC01 ------
cat > "$BODY/01" <<'B01'
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
B01

# ---------------------------------------------------------------- TC02 ------
cat > "$BODY/02" <<'B02'
Test02() {
    preflight || return

    local rid claim got want branch tool audit_first audit_last tools
    for claim in WM-3140 WM-3168 WM-3185; do
        rid="tc02_${claim}_$$"
        reset_run "$rid"
        want="$(oracle route "$claim")"
        require_expected "$(printf '%s' "$want" | jq -r '.branch')" || return
        run_ctl "$rid" route --claim "$claim"
        got="$RUN_OUT"
        if [ -z "$got" ]; then
            fail_no_json "route ${claim} returned nothing"
            return
        fi
        branch="$(printf '%s' "$got" | jq -r '.branch')"
        if [ "$branch" != "$(printf '%s' "$want" | jq -r '.branch')" ]; then
            report "failed" "route ${claim} took the ${branch} branch where the record it produced routes to $(printf '%s' "$want" | jq -r '.branch')"
            return
        fi
        audit_first="$(printf '%s' "$got" | jq -r '.audit[0]')"
        audit_last="$(printf '%s' "$got" | jq -r '.audit[-1]')"
        if [ "$audit_first" != "triage" ] || [ "$audit_last" != "$branch" ]; then
            report "failed" "route ${claim} recorded an audit trail running ${audit_first} .. ${audit_last}, which does not start at the triage step and end at the branch it says it took"
            return
        fi
        tool="$(printf '%s' "$want" | jq -r '.tool')"
        tools="$(trace_field "$rid" '.tools | join(",")')"
        if [ "$tools" != "$tool" ]; then
            report "failed" "the ${branch} branch of ${claim} used [${tools}] where that branch has to consult ${tool} exactly once"
            return
        fi
    done

    report "success" "three claims routed to three different branches on the typed record rather than on the narrative text, each consulting exactly the one desk tool its branch owns"
}

Test02
B02

# ---------------------------------------------------------------- TC03 ------
cat > "$BODY/03" <<'B03'
Test03() {
    preflight || return

    local rid got want attempts visits steps branch calls
    # A claim the desk resolves on the second look, and one it never resolves.
    for probe in WM-3204:recovers WM-3231:exhausts; do
        local claim="${probe%%:*}"
        rid="tc03_${claim}_$$"
        reset_run "$rid"
        want="$(oracle route "$claim")"
        require_expected "$(printf '%s' "$want" | jq -r '.attempts')" || return
        run_ctl "$rid" route --claim "$claim"
        got="$RUN_OUT"
        if [ -z "$got" ]; then
            fail_no_json "route ${claim} returned nothing"
            return
        fi
        attempts="$(printf '%s' "$got" | jq -r '.attempts')"
        steps="$(printf '%s' "$got" | jq -r '.steps')"
        visits="$(printf '%s' "$got" | jq -r '.audit | length')"
        branch="$(printf '%s' "$got" | jq -r '.branch')"
        calls="$(trace_field "$rid" '.structured')"

        if [ "$attempts" != "$(printf '%s' "$want" | jq -r '.attempts')" ]; then
            report "failed" "route ${claim} triaged ${attempts} times where a confidence floor of 0.55 and a cap of three attempts means $(printf '%s' "$want" | jq -r '.attempts')"
            return
        fi
        if [ "${calls:-0}" != "$attempts" ]; then
            report "failed" "the desk saw ${calls} record requests while ${claim} reported ${attempts} attempts - the two have to be the same number"
            return
        fi
        if [ "$visits" != "$(printf '%s' "$want" | jq -r '.visits')" ]; then
            report "failed" "route ${claim} recorded ${visits} visits in its audit trail where the run makes $(printf '%s' "$want" | jq -r '.visits') - one per triage attempt, then the classify step, then the branch"
            return
        fi
        if [ "$steps" != "$(printf '%s' "$want" | jq -r '.steps')" ]; then
            report "failed" "route ${claim} reported steps=${steps} where the ceiling of 4 makes it $(printf '%s' "$want" | jq -r '.steps') - the step counter needs a reducer that clamps, not one that just adds"
            return
        fi
        if [ "$branch" != "$(printf '%s' "$want" | jq -r '.branch')" ]; then
            report "failed" "route ${claim} ended on the ${branch} branch where a run that $( [ "$(printf '%s' "$want" | jq -r '.exhausted')" = "true" ] && echo "never clears the confidence floor" || echo "clears the confidence floor on a later look" ) has to end on $(printf '%s' "$want" | jq -r '.branch')"
            return
        fi
    done

    report "success" "the re-triage loop stopped as soon as the desk was confident, ran out at the attempt cap on the claim it never resolves, kept the audit trail complete, and clamped the step counter at 4"
}

Test03
B03

# ---------------------------------------------------------------- TC04 ------
cat > "$BODY/04" <<'B04'
Test04() {
    preflight || return

    local rid got want claim field calls notes
    for claim in WM-3258 WM-3277; do
        rid="tc04_${claim}_$$"
        reset_run "$rid"
        want="$(oracle settle "$claim")"
        require_expected "$(printf '%s' "$want" | jq -r '.status')" || return
        run_ctl "$rid" settle --claim "$claim"
        got="$RUN_OUT"
        if [ -z "$got" ]; then
            fail_no_json "settle ${claim} returned nothing"
            return
        fi
        for field in status attempts; do
            if [ "$(printf '%s' "$got" | jq -r ".$field")" \
                 != "$(printf '%s' "$want" | jq -r ".$field")" ]; then
                report "failed" "settle ${claim} reported ${field}=$(printf '%s' "$got" | jq -r ".$field") where a cap of three quotes against the policy limit gives $(printf '%s' "$want" | jq -r ".$field")"
                return
            fi
        done
        # Compared as a number scaled to whole pence, so 1180 and 1180.0 are
        # the same answer and neither shape of the same figure is marked wrong.
        if [ "$(printf '%s' "$got" | jq -r 'if .amount == null then "none" else (.amount * 100 | round | tostring) end')" \
             != "$(printf '%s' "$want" | jq -r 'if .amount == null then "none" else (.amount * 100 | round | tostring) end')" ]; then
            report "failed" "settle ${claim} reported amount $(printf '%s' "$got" | jq -r '.amount') where the desk quote inside the cap is $(printf '%s' "$want" | jq -r '.amount')"
            return
        fi
        notes="$(printf '%s' "$got" | jq -r '.notes | length')"
        if [ "$notes" != "$(printf '%s' "$want" | jq -r '.notes | length')" ]; then
            report "failed" "settle ${claim} recorded ${notes} rejection notes where $(printf '%s' "$want" | jq -r '.notes | length') quotes were refused - every refused quote has to be written down"
            return
        fi
        calls="$(trace_field "$rid" '.structured')"
        if [ "${calls:-0}" != "$(printf '%s' "$want" | jq -r '.attempts')" ]; then
            report "failed" "the desk was asked for ${calls} quotes on ${claim} where the bounded loop allows $(printf '%s' "$want" | jq -r '.attempts') - a retry loop without a hard cap is not bounded"
            return
        fi
    done

    report "success" "a quote inside the policy limit was approved on the first attempt, and a quote that is never inside it was refused three times, escalated with no amount, and stopped at the cap rather than looping"
}

Test04
B04

# ---------------------------------------------------------------- TC05 ------
cat > "$BODY/05" <<'B05'
Test05() {
    preflight || return

    local rid="tc05_$$" left right trail turns chats first second isolated
    local thread_a="tc05a_$$" thread_b="tc05b_$$"
    reset_run "$rid"

    run_ctl "$rid" chat --thread "$thread_a" \
             --say "my policy is WM-P-4474 and the car is a 2019 estate"
    first="$RUN_OUT"
    if [ -z "$first" ]; then
        fail_no_json "the first chat turn returned nothing"
        return
    fi
    if [ "$(printf '%s' "$first" | jq -r '.turn')" != "1" ]; then
        report "failed" "the first turn on a new thread reported turn=$(printf '%s' "$first" | jq -r '.turn') instead of 1"
        return
    fi

    run_ctl "$rid" chat --thread "$thread_a" \
              --say "what policy did I give you?"
    second="$RUN_OUT"
    if [ -z "$second" ]; then
        fail_no_json "the second chat turn returned nothing"
        return
    fi
    if [ "$(printf '%s' "$second" | jq -r '.turn')" != "2" ]; then
        report "failed" "the second turn on the same thread reported turn=$(printf '%s' "$second" | jq -r '.turn') instead of 2 - the thread has to carry its earlier turns"
        return
    fi
    if ! printf '%s' "$second" | jq -r '.reply' | grep -q 'WM-P-4474'; then
        report "failed" "asked in a second process what policy was given, the desk answered \"$(printf '%s' "$second" | jq -r '.reply' | head -c 90)\" - the earlier turn was not persisted, so the desk never saw it"
        return
    fi

    run_ctl "$rid" chat --thread "$thread_b" \
                --say "what policy did I give you?"
    isolated="$RUN_OUT"
    if [ -z "$isolated" ]; then
        fail_no_json "the chat turn on the second thread returned nothing"
        return
    fi
    if printf '%s' "$isolated" | jq -r '.reply' | grep -q 'WM-P-4474'; then
        report "failed" "a different thread was told the policy from the first thread - threads have to be isolated from each other"
        return
    fi

    run_ctl "$rid" trail --thread "$thread_a"
    trail="$RUN_OUT"
    if [ -z "$trail" ]; then
        fail_no_json "trail returned nothing"
        return
    fi
    turns="$(printf '%s' "$trail" | jq -r '.turns')"
    if [ "$turns" != "2" ]; then
        report "failed" "trail reported ${turns} turns on a thread that had two - it has to read the history back out of the store"
        return
    fi
    left="$(printf '%s' "$trail" | jq -r '.messages | length')"
    if [ "${left:-0}" -lt 4 ]; then
        report "failed" "trail returned ${left} messages for two turns - both what was said and what was answered belong in the trail"
        return
    fi
    if [ "$(printf '%s' "$trail" | jq -r '.messages[0].role')" != "human" ]; then
        report "failed" "the trail does not start with what the caller said"
        return
    fi
    if ! printf '%s' "$trail" | jq -r '.messages[0].content' | grep -q '2019 estate'; then
        report "failed" "the first message in the trail is not the first thing the caller said"
        return
    fi

    if [ ! -s "${LAB_DIR}/${STATE_DB}" ]; then
        report "failed" "there is no store at ${LAB_DIR}/${STATE_DB} - thread state has to survive the process, so it cannot live in memory"
        return
    fi

    chats="$(trace_field "$rid" '.chat')"
    if [ "${chats:-0}" -ne 3 ]; then
        report "failed" "the desk answered ${chats} turns across three conversation turns - resuming a thread must not replay the turns that already happened"
        return
    fi

    report "success" "three chat turns in three separate processes: the second recalled a fact stated by the first, a different thread did not, the trail read two turns and four messages back out of ${STATE_DB}, and the desk was asked exactly three times"
}

Test05
B05

for n in 01 02 03 04 05; do
    case "$n" in
        01) t="a structured triage record, produced by the chain" ;;
        02) t="routing decided by the typed record, not by the text" ;;
        03) t="a bounded re-triage loop with a clamped step counter" ;;
        04) t="a settlement retry that stops at its cap and escalates" ;;
        05) t="thread state that outlives the process that wrote it" ;;
    esac
    emit "$n" "$t" "$BODY/$n"
done

cat > "$OUT/common.sh" <<'CS'
#!/bin/bash
# FAITHFUL REPLICA of the platform-provided /usr/local/bin/judge/test/common.sh,
# copied from a real lab VM. Used only by run-all.sh during authoring; NEVER
# shipped in TestCase.zip.
#
# It is a replica and not a convenience stub on purpose. The real helper emits
# one line of JSON and installs an ERR trap that exits the check - and a stub
# without those two behaviours let a bug through that scored a correct solution
# as "no test cases at all" on the portal. If this file is easier to pass than
# the real one, local validation is worthless.
print_status() {
    local status="$1"
    local message="$2"
    echo $(jq -n --arg status "$status" --arg message "$message" '{status: $status, message: $message}')
}

handle_internal_error() {
    echo "INTERNAL_ERROR: $1"
    exit 1
}

handle_script_error() {
    handle_internal_error "An error occurred at line $1: '$3' exited with status '$2'"
}

trap 'handle_script_error $LINENO $? "$BASH_COMMAND"' ERR
CS
echo "done"
