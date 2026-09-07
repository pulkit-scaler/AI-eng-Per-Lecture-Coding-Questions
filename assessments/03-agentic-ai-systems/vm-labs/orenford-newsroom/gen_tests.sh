#!/bin/bash
# Regenerate test-cases/scripts/script_01..05.sh from one shared preamble.
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
exec 2>>"/tmp/orenford_tc${TC}.err"
STATUS_SENT=0
report() {
    if [ "$STATUS_SENT" -eq 1 ]; then return 0; fi
    STATUS_SENT=1
    print_status "$1" "$2"
}

LAB_DIR="${LAB_DIR:-/home/user/orenford-newsroom}"
WIRE_URL="${WIRE_URL:-http://127.0.0.1:8317}"
WIRE_BIN="${WIRE_BIN:-/opt/orenford-svc/wired.py}"
SERVE_URL="${SERVE_URL:-http://127.0.0.1:8300}"
SERVE_PORT="${SERVE_PORT:-8300}"
GKEY="X-Grader-Key: orenford-grader-n3k7"
GPATH="__on3k"
MAX_REVISIONS="${MAX_REVISIONS:-2}"
PY="${PY:-python3}"
DEPS_READY_FILE="${DEPS_READY_FILE:-/var/log/orenford-lab/deps.ready}"
TIMING_LOG="${TIMING_LOG:-/tmp/orenford_timing.log}"
SERVE_LOG="${SERVE_LOG:-/tmp/orenford_serve.log}"
export PYTHONDONTWRITEBYTECODE=1

# --- time budget -----------------------------------------------------------
# The portal kills a test case that runs much beyond two minutes. HARD_DEADLINE
# is a ceiling on the whole script rather than on one request: the heaviest
# check commissions two briefings, and two independent per-request bounds would
# add up past the cap even with no single slow request. Each call below shrinks
# its own bound as the deadline approaches.
CURL_MAX=${CURL_MAX:-5}
WIRE_WAIT=${WIRE_WAIT:-12}
SVC_WAIT=${SVC_WAIT:-20}
DEPS_WAIT=${DEPS_WAIT:-25}
BRIEF_BUDGET=${BRIEF_BUDGET:-45}
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
# leaves a VM the learner can work in.
on_exit() {
    local rc=$?
    # Grading runs as root and the learner is user, so a service of ours left
    # holding the port is one they can neither kill nor replace when they go
    # back to work - their next `python3 serve.py` would die on an address
    # already in use with no way out. Every check starts its own; every check
    # takes it down again.
    stop_service >/dev/null 2>&1
    case "$LAB_DIR" in
        /home/user/*) chown -R user:user "$LAB_DIR" >/dev/null 2>&1 ;;
    esac
    printf 'script_%s %ss\n' "$TC" "$SECONDS" >>"$TIMING_LOG" 2>/dev/null || true
    report "failed" "TC${TC} ended without reaching a verdict (rc=${rc})"
}
trap on_exit EXIT

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

ensure_wire() {
    curl -sf -m "$CURL_MAX" "${WIRE_URL}/health" >/dev/null 2>&1 && return 0
    [ -f "$WIRE_BIN" ] || return 1
    spawn_detached /tmp/orenford_wire.log "$PY" "$WIRE_BIN"
    local i
    for i in $(seq 1 "$WIRE_WAIT"); do
        curl -sf -m 2 "${WIRE_URL}/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

# Every check restarts the service from the serve.py on disk, into a log it has
# just truncated. Running the learner program is their work executed, not work
# done on their behalf, and it buys two things a reused service cannot:
#
#   * what gets graded is the file as it stands, not whatever code a process
#     started before the last edit still holds in memory;
#   * the log named in a failure holds this run and nothing else. A log opened
#     by a process the checks did not start cannot be truncated by them, which
#     is how a learner came to be sent to a traceback from an earlier
#     submission - the same one, edit after edit, until the VM was restarted.
#
# A learner never has to stop, start or restart anything for either of those.
stop_service() {
    local i pid
    # Whatever is holding the port, by port. A pattern match on serve.py would
    # also match a learner sitting in an editor with the file open, and killing
    # that takes their unsaved work with it. The last resort narrows the pattern
    # to a python process running the file, for the same reason: a service
    # started as `cd LAB_DIR && python3 serve.py` carries no path in its command
    # line, so a pattern built from LAB_DIR would never match it either.
    if command -v lsof >/dev/null 2>&1; then
        for pid in $(lsof -ti "tcp:${SERVE_PORT}" 2>/dev/null); do
            kill "$pid" >/dev/null 2>&1
        done
    elif command -v ss >/dev/null 2>&1; then
        for pid in $(ss -lptnH "sport = :${SERVE_PORT}" 2>/dev/null \
                     | grep -o "pid=[0-9]*" | cut -d= -f2 | sort -u); do
            kill "$pid" >/dev/null 2>&1
        done
    elif command -v fuser >/dev/null 2>&1; then
        fuser -k -n tcp "$SERVE_PORT" >/dev/null 2>&1
    else
        pkill -f "python[0-9.]* .*serve\.py" >/dev/null 2>&1
    fi
    for i in $(seq 1 10); do
        curl -sf -m 1 "${SERVE_URL}/health" >/dev/null 2>&1 || return 0
        sleep 1
    done
    return 1
}

restart_learner_service() {
    [ -f "${LAB_DIR}/serve.py" ] || return 1
    stop_service
    : >"$SERVE_LOG" 2>/dev/null
    ( cd "$LAB_DIR" && export PYTHONPATH="$LAB_DIR" \
        ORENFORD_SERVE_PORT="$SERVE_PORT" ORENFORD_WIRE_URL="$WIRE_URL" \
        ORENFORD_ASSIGNMENTS_FILE="${LAB_DIR}/data/assignments.json" \
      && spawn_detached "$SERVE_LOG" "$PY" serve.py )
    local i
    for i in $(seq 1 "$SVC_WAIT"); do
        curl -sf -m 2 "${SERVE_URL}/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

oracle() {
    curl -sf -m "$CURL_MAX" -H "$GKEY" \
        "${WIRE_URL}/${GPATH}/oracle?kind=$1&assignment=$2&max=${MAX_REVISIONS}" \
        2>/dev/null
}

trace_field() {
    curl -sf -m "$CURL_MAX" -H "$GKEY" \
        "${WIRE_URL}/${GPATH}/trace?run=$1" 2>/dev/null | jq -r "$2"
}

reset_run() {
    curl -sf -m "$CURL_MAX" -X POST -H "$GKEY" \
        "${WIRE_URL}/${GPATH}/reset?run=$1" >/dev/null 2>&1
    return 0
}

# brief <assignment>: the answer lands in BRIEF_OUT and the diagnosis in
# LAST_RC, LAST_CODE and LAST_BODY. Call it as a statement, never as
# got="$(brief x)": a command substitution runs it in a subshell, every
# variable it sets there is discarded, and the failure message then reports
# the initial exit 0 for a crash, a timeout and a refused connection alike.
BRIEF_OUT=""
LAST_RC=0
LAST_CODE=""
LAST_BODY=""
brief() {
    local left budget raw
    BRIEF_OUT=""; LAST_CODE=""; LAST_BODY=""
    left=$(( HARD_DEADLINE - SECONDS ))
    if [ "$left" -lt 6 ]; then
        LAST_RC=124
        return 124
    fi
    budget=$(( left < BRIEF_BUDGET ? left : BRIEF_BUDGET ))
    # curl carries the bound itself with -m. Wrapping it in the shell watchdog
    # as well raced the background job against the command substitution closing,
    # and produced an empty body with a zero exit - a failure that reads exactly
    # like a service returning nothing.
    #
    # No -f: run_service answers a handler that raised with a 500 whose body
    # carries the exception, and -f would throw that body away. Putting the
    # exception in the verdict is the difference between a learner reading the
    # error and a learner hunting for the log file it went to.
    raw="$(jq -nc --arg a "$1" '{assignment:$a}' 2>/dev/null | \
        curl -s -m "$budget" -w '\n%{http_code}' -X POST \
            -H 'Content-Type: application/json' --data-binary @- \
            "${SERVE_URL}/brief" 2>/dev/null)"
    LAST_RC=$?
    LAST_CODE="$(printf '%s' "$raw" | tail -n 1)"
    LAST_BODY="$(printf '%s' "$raw" | sed '$d')"
    [ "$LAST_CODE" = "200" ] || return 1
    BRIEF_OUT="$LAST_BODY"
    return 0
}

require_expected() {
    if [ -z "$1" ] || [ "$1" = "null" ] || [ "$1" = "{}" ]; then
        report "failed" "Grader could not read the expected briefing from the newsroom wire on ${WIRE_URL}"
        return 1
    fi
    return 0
}

fail_no_brief() {
    local detail
    detail="$(printf '%s' "$LAST_BODY" | tr '\n\t' '  ' | cut -c1-240)"
    case "$LAST_CODE" in
        500)
            report "failed" "${1} - your service answered 500: ${detail:-with no body} - the traceback is in ${SERVE_LOG}"
            ;;
        ""|000)
            # curl writes 000 for a request that never completed, and nothing
            # at all when it was killed outright. Both mean no answer came.
            if [ "$LAST_RC" = "28" ] || [ "$LAST_RC" = "124" ]; then
                report "failed" "${1} - your service did not answer inside its ${BRIEF_BUDGET}s budget, so a step of the graph is hanging or waiting on the wire; ${SERVE_LOG} carries whatever it managed to print"
            else
                report "failed" "${1} - nothing answered on ${SERVE_URL}/brief (curl exit ${LAST_RC}) - start your service with python3 serve.py from ${LAB_DIR} and leave it running; ${SERVE_LOG} says why it did not start"
            fi
            ;;
        *)
            report "failed" "${1} - your service answered HTTP ${LAST_CODE}: ${detail:-with no body}"
            ;;
    esac
}

# Refuse an unstarted project in about a second, naming every plausible cause.
require_started() {
    if [ ! -f "${LAB_DIR}/serve.py" ]; then
        report "failed" "no serve.py in ${LAB_DIR} - that is the service the checks talk to"
        return 1
    fi
    # The starter carries this sentence and nothing a working service would.
    # One condition, so an untouched project is refused in about a second rather
    # than spending the whole budget starting a service that cannot answer.
    if grep -q 'serve.py is not implemented yet' "${LAB_DIR}/serve.py" 2>/dev/null; then
        report "failed" "${LAB_DIR}/serve.py is still the untouched starter - build the newsroom, start it with python3 serve.py, then run python3 check_local.py from ${LAB_DIR} before submitting"
        return 1
    fi
    return 0
}

preflight() {
    ensure_deps || { report "failed" "the Python packages this lab needs are not installed on this VM yet - see /var/log/orenford-lab/pip.log"; return 1; }
    ensure_wire || { report "failed" "the newsroom wire is not reachable on ${WIRE_URL}"; return 1; }
    require_started || return 1
    restart_learner_service || { report "failed" "python3 serve.py in ${LAB_DIR} did not come up on ${SERVE_URL}/health - the last lines of ${SERVE_LOG} say why"; return 1; }
    return 0
}

# jq helper: is the left list exactly the right list, same order.
same_list() {
    [ "$(printf '%s' "$1" | jq -c "$2")" = "$(printf '%s' "$3" | jq -c "$4")" ]
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

    local a="OR-4133" got want desks n audit missing
    reset_run "$a"
    want="$(oracle brief "$a")"
    require_expected "$(printf '%s' "$want" | jq -r '.assignment')" || return

    brief "$a"; got="$BRIEF_OUT"
    if [ -z "$got" ]; then
        fail_no_brief "the briefing on ${a}"
        return
    fi

    # Every key the interface contract lists, present. Stated as a requirement,
    # so graded as one rather than left to check_local.py.
    missing="$(printf '%s' "$got" | jq -r '((["assignment","status","headline","sections","claims","sources","sub_questions","findings","excluded","revisions","reservations","audit","accounting"]) - keys) | join(", ")' 2>/dev/null)"
    if [ -n "$missing" ]; then
        report "failed" "the briefing left out these keys the response has to carry: ${missing}"
        return
    fi
    missing="$(printf '%s' "$got" | jq -r '((["planner","researcher","writer","critic","total_calls"]) - ((.accounting // {}) | keys)) | join(", ")' 2>/dev/null)"
    if [ -n "$missing" ]; then
        report "failed" "the accounting block left out: ${missing}"
        return
    fi

    if ! same_list "$got" '.sub_questions' "$want" '.sub_questions'; then
        report "failed" "the briefing on ${a} worked to $(printf '%s' "$got" | jq -r '.sub_questions | length') sub-questions and not the three the plan sets out"
        return
    fi
    n="$(printf '%s' "$got" | jq -r '.findings | length')"
    if [ "$n" != "$(printf '%s' "$want" | jq -r '.finding_count')" ]; then
        report "failed" "the briefing carries ${n} findings where three desks each report one - a findings list that is assigned rather than merged keeps only the desk that finished last"
        return
    fi
    desks="$(printf '%s' "$got" | jq -c '[.findings[].desk] | sort')"
    if [ "$desks" != "$(printf '%s' "$want" | jq -c '.desks')" ]; then
        report "failed" "the findings came from ${desks} where all three desks have something on this assignment"
        return
    fi
    if ! same_list "$got" '.sources' "$want" '.sources'; then
        report "failed" "the source list is $(printf '%s' "$got" | jq -c '.sources') and should be $(printf '%s' "$want" | jq -c '.sources') - unique and in order"
        return
    fi
    audit="$(trace_field "$a" '[.desks[]] | sort | join(",")')"
    if [ "$audit" != "people,records,wire" ]; then
        report "failed" "the wire saw desk lookups [${audit}] - each of the three sub-questions goes to the desk that owns it"
        return
    fi
    if [ "$(trace_field "$a" '.via_kit')" != "$(trace_field "$a" '.total')" ]; then
        report "failed" "some wire traffic did not come from the provided model - every call has to go through news_kit.get_chat_model()"
        return
    fi

    report "success" "the plan fanned out to all three desks, their findings merged into one list of ${n}, and the source list came back unique and in order"
}

Test01
B01

# ---------------------------------------------------------------- TC02 ------
cat > "$BODY/02" <<'B02'
Test02() {
    preflight || return

    local a="OR-4148" got want n desks excluded status attempted
    reset_run "$a"
    want="$(oracle brief "$a")"
    require_expected "$(printf '%s' "$want" | jq -r '.assignment')" || return

    brief "$a"; got="$BRIEF_OUT"
    if [ -z "$got" ]; then
        fail_no_brief "the briefing on ${a}, which is the assignment with a desk out of service"
        return
    fi

    status="$(printf '%s' "$got" | jq -r '.status')"
    if [ "$status" != "$(printf '%s' "$want" | jq -r '.status')" ]; then
        report "failed" "the briefing came back ${status} where a desk being unavailable is a gap in the story, not a reason to hold it"
        return
    fi
    n="$(printf '%s' "$got" | jq -r '.findings | length')"
    if [ "$n" != "$(printf '%s' "$want" | jq -r '.finding_count')" ]; then
        report "failed" "the briefing carries ${n} findings where two of the three desks answered - one desk failing must not lose the other two"
        return
    fi
    desks="$(printf '%s' "$got" | jq -c '[.findings[].desk] | sort')"
    if [ "$desks" != "$(printf '%s' "$want" | jq -c '.desks')" ]; then
        report "failed" "the surviving findings came from ${desks} and should be $(printf '%s' "$want" | jq -c '.desks')"
        return
    fi
    excluded="$(printf '%s' "$got" | jq -c '[.excluded[].desk] | sort')"
    if [ "$excluded" != "$(printf '%s' "$want" | jq -c '.excluded_desks')" ]; then
        report "failed" "the briefing records ${excluded} as left out where it should record $(printf '%s' "$want" | jq -c '.excluded_desks') - what the story does not cover has to be written down"
        return
    fi
    if [ -z "$(printf '%s' "$got" | jq -r '.excluded[0].reason // empty')" ]; then
        report "failed" "the excluded desk is listed with no reason against it"
        return
    fi
    attempted="$(trace_field "$a" '[.desks[] | select(. == "people")] | length')"
    if [ "${attempted:-0}" -lt 1 ]; then
        report "failed" "the wire never saw the people desk asked at all - the desk has to be tried before it can be reported unavailable"
        return
    fi
    if [ "$(printf '%s' "$got" | jq -r '.claims | length')" != "$(printf '%s' "$want" | jq -r '.claim_count')" ]; then
        report "failed" "the briefing makes $(printf '%s' "$got" | jq -r '.claims | length') claims on two surviving findings"
        return
    fi

    report "success" "with one desk out of service the briefing still went out ${status}, on ${n} findings from ${desks}, with the unavailable desk recorded and its reason given"
}

Test02
B02

# ---------------------------------------------------------------- TC03 ------
cat > "$BODY/03" <<'B03'
Test03() {
    preflight || return

    local a got want revisions status writer critic
    for a in OR-4155 OR-4162; do
        reset_run "$a"
        want="$(oracle brief "$a")"
        require_expected "$(printf '%s' "$want" | jq -r '.assignment')" || return
        brief "$a"; got="$BRIEF_OUT"
        if [ -z "$got" ]; then
            fail_no_brief "the briefing on ${a}"
            return
        fi

        revisions="$(printf '%s' "$got" | jq -r '.revisions')"
        status="$(printf '%s' "$got" | jq -r '.status')"
        if [ "$revisions" != "$(printf '%s' "$want" | jq -r '.revisions')" ]; then
            report "failed" "${a} went round the night editor ${revisions} times where a cap of ${MAX_REVISIONS} gives $(printf '%s' "$want" | jq -r '.revisions')"
            return
        fi
        if [ "$status" != "$(printf '%s' "$want" | jq -r '.status')" ]; then
            report "failed" "${a} came back ${status} where the night editor verdict gives $(printf '%s' "$want" | jq -r '.status')"
            return
        fi
        if ! same_list "$got" '.reservations' "$want" '.reservations'; then
            report "failed" "${a} reported reservations $(printf '%s' "$got" | jq -c '.reservations') where the night editor raised $(printf '%s' "$want" | jq -c '.reservations') - a briefing that goes out anyway has to carry what was still wrong with it"
            return
        fi
        writer="$(trace_field "$a" '.roles.writer')"
        critic="$(trace_field "$a" '.roles.critic')"
        if [ "${writer:-0}" != "$(printf '%s' "$want" | jq -r '.calls.writer')" ] \
           || [ "${critic:-0}" != "$(printf '%s' "$want" | jq -r '.calls.critic')" ]; then
            report "failed" "${a} put the writer to work ${writer} times and the night editor ${critic} times, where the bounded loop allows $(printf '%s' "$want" | jq -r '.calls.writer') and $(printf '%s' "$want" | jq -r '.calls.critic')"
            return
        fi
    done

    report "success" "an accepted draft went out with no rework, and a draft the night editor never accepts stopped at the cap of ${MAX_REVISIONS} and went out with its reservations attached"
}

Test03
B03

# ---------------------------------------------------------------- TC04 ------
cat > "$BODY/04" <<'B04'
Test04() {
    preflight || return

    local a="OR-4171" got want blocked orphans sorted
    reset_run "$a"
    want="$(oracle brief "$a")"
    require_expected "$(printf '%s' "$want" | jq -r '.assignment')" || return

    brief "$a"; got="$BRIEF_OUT"
    if [ -z "$got" ]; then
        fail_no_brief "the briefing on ${a}, which is the assignment with a source that may not be cited"
        return
    fi

    if ! same_list "$got" '.sources' "$want" '.sources'; then
        report "failed" "the source list is $(printf '%s' "$got" | jq -c '.sources') and should be $(printf '%s' "$want" | jq -c '.sources')"
        return
    fi
    blocked="$(printf '%s' "$want" | jq -r '.excluded_desks[0] // empty')"
    if [ -n "$blocked" ]; then
        if [ "$(printf '%s' "$got" | jq -c '[.excluded[].desk] | sort')" \
             != "$(printf '%s' "$want" | jq -c '.excluded_desks')" ]; then
            report "failed" "the briefing does not record the ${blocked} desk source as left out"
            return
        fi
        if printf '%s' "$got" | jq -e --arg d "$blocked" \
              '[.claims[].source_id] | any(test($d[0:3] | ascii_upcase))' >/dev/null 2>&1; then
            report "failed" "a claim in the briefing still cites the ${blocked} desk source, which may not be cited on this assignment"
            return
        fi
    fi
    # The desk has to have been consulted before its source can be excluded.
    # Without this, a service that simply prints the right answer passes.
    local asked
    asked="$(trace_field "$a" '[.desks[]] | sort | join(",")')"
    if [ "$asked" != "people,records,wire" ]; then
        report "failed" "the wire saw desk lookups [${asked}] on this assignment - a source can only be left out after the desk holding it has been asked"
        return
    fi
    if [ "$(trace_field "$a" '.total')" = "0" ] || [ -z "$(trace_field "$a" '.total')" ]; then
        report "failed" "the wire has no record of this briefing at all"
        return
    fi
    orphans="$(printf '%s' "$got" | jq -c '[.claims[].source_id] - .sources')"
    if [ "$orphans" != "[]" ]; then
        report "failed" "these claims cite sources that are not in the source list: ${orphans} - every claim has to be traceable to a listed source"
        return
    fi
    sorted="$(printf '%s' "$got" | jq -c '.sources == (.sources | unique | sort)')"
    if [ "$sorted" != "true" ]; then
        report "failed" "the source list is not unique and sorted: $(printf '%s' "$got" | jq -c '.sources')"
        return
    fi
    if [ "$(printf '%s' "$got" | jq -r '.claims | length')" != "$(printf '%s' "$want" | jq -r '.claim_count')" ]; then
        report "failed" "the briefing makes $(printf '%s' "$got" | jq -r '.claims | length') claims where $(printf '%s' "$want" | jq -r '.claim_count') findings are citable"
        return
    fi

    report "success" "the source that may not be cited was dropped from the claims and the source list and recorded as left out, and every remaining claim traces to a listed source"
}

Test04
B04

# ---------------------------------------------------------------- TC05 ------
cat > "$BODY/05" <<'B05'
Test05() {
    preflight || return

    local a got want role claimed observed total via
    # One briefing that goes out first time and one that takes a round of
    # rework, so an accounting block that was written out in advance cannot be
    # right for both.
    for a in OR-4184 OR-4190; do
    reset_run "$a"
    want="$(oracle brief "$a")"
    require_expected "$(printf '%s' "$want" | jq -r '.assignment')" || return

    brief "$a"; got="$BRIEF_OUT"
    if [ -z "$got" ]; then
        fail_no_brief "the briefing on ${a}"
        return
    fi

    total="$(trace_field "$a" '.total')"
    via="$(trace_field "$a" '.via_kit')"
    if [ -z "$total" ] || [ "$total" = "null" ]; then
        report "failed" "the wire has no record of this briefing at all"
        return
    fi
    if [ "${via:-0}" != "${total:-0}" ]; then
        report "failed" "$(( ${total:-0} - ${via:-0} )) of the ${total} calls the wire received did not come from the provided model - every call has to go through news_kit.get_chat_model()"
        return
    fi

    claimed="$(printf '%s' "$got" | jq -r '.accounting.total_calls')"
    if [ "$claimed" != "$total" ]; then
        report "failed" "the briefing accounts for ${claimed} model calls where the wire received ${total} - the accounting has to be what actually happened"
        return
    fi
    if [ "$claimed" != "$(printf '%s' "$want" | jq -r '.total_calls')" ]; then
        report "failed" "this assignment takes $(printf '%s' "$want" | jq -r '.total_calls') calls and the run made ${claimed}"
        return
    fi
    for role in planner researcher writer critic; do
        claimed="$(printf '%s' "$got" | jq -r --arg r "$role" '.accounting[$r]')"
        observed="$(trace_field "$a" ".roles.${role}")"
        if [ "$claimed" != "$observed" ]; then
            report "failed" "on ${a} the briefing accounts for ${claimed} ${role} calls where the wire received ${observed} - each role has to ask for its own model"
            return
        fi
        if [ "$observed" != "$(printf '%s' "$want" | jq -r --arg r "$role" '.calls[$r]')" ]; then
            report "failed" "on ${a} the ${role} was called ${observed} times and should be $(printf '%s' "$want" | jq -r --arg r "$role" '.calls[$r]')"
            return
        fi
    done
    done

    report "success" "both briefings account for their model calls by role, including the one that took a round of rework, and every figure matches what the wire actually received"
}

Test05
B05

for n in 01 02 03 04 05; do
    case "$n" in
        01) t="the plan fans out to three desks and their findings merge" ;;
        02) t="a desk that fails does not take the briefing with it" ;;
        03) t="the night editor loop is bounded and its outcome is honest" ;;
        04) t="every claim traces to a source, and a barred source is dropped" ;;
        05) t="the accounting matches what the wire actually received" ;;
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
