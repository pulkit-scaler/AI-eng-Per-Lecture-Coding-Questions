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
PRE
}

write_01() {
cat <<'BODY01'
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
BODY01
}

write_02() {
cat <<'BODY02'
Test02() {
    preflight || return

    local q="who signed off the SEC-9 possession last winter"
    local rid="tc02_$$" got want reason answered given steps want_steps
    local tools_seen got_think want_think
    reset_run "$rid"
    want="$(oracle_react "$q")"
    want_steps="$(printf '%s' "$want" | jq -r '.steps')"
    require_expected "$want_steps" || return

    ctl "$rid" ask --question "$q"; got="$CTL_OUT"
    if [ -z "$got" ]; then
        fail_no_json "asking about something the desk does not record"
        return
    fi

    answered="$(printf '%s' "$got" | jq -r '.answered')"
    if [ "$answered" != "false" ]; then
        report "failed" "the loop reported answered=${answered} for something the desk does not record - a bounded loop that runs out has to say so, not produce something"
        return
    fi
    given="$(printf '%s' "$got" | jq -r '.answer // "null"')"
    if [ "$given" != "null" ]; then
        report "failed" "the loop returned an answer while reporting that it could not answer"
        return
    fi
    reason="$(printf '%s' "$got" | jq -r '.stopped_because // ""')"
    if [ ${#reason} -lt 8 ]; then
        report "failed" "the loop gave up without saying why - a refusal that does not say what was missing is not an honest failure"
        return
    fi
    steps="$(printf '%s' "$got" | jq -r '.steps')"
    if [ "$steps" != "$want_steps" ]; then
        report "failed" "the loop took ${steps} actions where the desk has ${want_steps} places to look"
        return
    fi
    if [ "${steps:-0}" -gt "$MAX_STEPS" ]; then
        report "failed" "the loop took ${steps} actions, past the cap of ${MAX_STEPS} - the step cap is what makes it terminate"
        return
    fi
    tools_seen="$(trace_field "$rid" '.tools | length')"
    if [ "${tools_seen:-0}" -gt "$MAX_STEPS" ]; then
        report "failed" "the desk saw ${tools_seen} tool calls, past the cap of ${MAX_STEPS}"
        return
    fi
    got_think="$(trace_field "$rid" '.think')"
    want_think="$(printf '%s' "$want" | jq -r '.think_calls')"
    if [ "$got_think" != "$want_think" ]; then
        report "failed" "the loop thought ${got_think} times where the cap allows ${want_think}"
        return
    fi

    report "success" "a question the desk cannot settle stopped after ${steps} actions with answered false and a stated reason, inside the cap of ${MAX_STEPS}"
}

Test02
BODY02
}

write_03() {
cat <<'BODY03'
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
BODY03
}

write_04() {
cat <<'BODY04'
Test04() {
    preflight || return

    local rid="tc04_$$" a="tc04a_$$" b="tc04b_$$" got n i turns note last
    reset_run "$rid"

    # Five notes on one session, in five separate processes. Nothing is held in
    # memory between them.
    i=1
    for note in "AST-2210 point machine sticking on the down line" \
                "SEC-4 possession granted 01:20 to 04:40 for three nights" \
                "RC-BOX-14 dropped to double yellow at 23:40" \
                "AST-2261 axle counter reset loop, fourth time this month" \
                "relay spares collected from the depot store"; do
        ctl "$rid" note --session "$a" --say "$note"; got="$CTL_OUT"
        if [ -z "$got" ]; then
            fail_no_json "writing note ${i} down"
            return
        fi
        turns="$(printf '%s' "$got" | jq -r '.turns')"
        if [ "$turns" != "$i" ]; then
            report "failed" "after ${i} notes the session reports ${turns} turns - each run is a separate process, so the count only grows if the notes reached the store"
            return
        fi
        i=$((i + 1))
    done

    if [ ! -s "${LAB_DIR}/${STORE}" ]; then
        report "failed" "there is no store at ${LAB_DIR}/${STORE} - what the desk remembers has to survive the process, so it cannot live in memory"
        return
    fi

    ctl "$rid" note --session "$b" --say "night shift handover complete"; got="$CTL_OUT"
    turns="$(printf '%s' "$got" | jq -r '.turns')"
    if [ "$turns" != "1" ]; then
        report "failed" "the first note on a new session reports ${turns} turns - two sessions are two conversations"
        return
    fi

    ctl "$rid" window --session "$a"; got="$CTL_OUT"
    if [ -z "$got" ]; then
        fail_no_json "reading the window back"
        return
    fi
    turns="$(printf '%s' "$got" | jq -r '.turns')"
    if [ "$turns" != "5" ]; then
        report "failed" "the window reports ${turns} turns on a session that had five"
        return
    fi
    n="$(printf '%s' "$got" | jq -r '.window | length')"
    if [ "$n" != "4" ]; then
        report "failed" "the window returned ${n} turns where it keeps the last four - a window that keeps everything is not a window"
        return
    fi
    last="$(printf '%s' "$got" | jq -r '.window[-1]')"
    if ! printf '%s' "$last" | grep -q 'relay spares'; then
        report "failed" "the window ends with ${last} instead of the most recent turn"
        return
    fi
    if printf '%s' "$got" | jq -r '.window | join(" ")' | grep -q 'point machine sticking'; then
        report "failed" "the window still holds the oldest turn, which is the one it should have dropped"
        return
    fi

    report "success" "five notes written in five separate processes all reached the store, a second session stayed separate, and the window kept the last four turns in order"
}

Test04
BODY04
}

write_05() {
cat <<'BODY05'
Test05() {
    preflight || return

    local rid="tc05_$$" s="tc05_$$" got n first second considered ordered under
    local thinks note
    reset_run "$rid"

    for note in "AST-2261 axle counter reset loop on RC-BOX-19" \
                "SEC-4 possession granted from 01:20 to 04:40 for three nights" \
                "the mess room kettle needs descaling" \
                "spare relays reordered from the depot store"; do
        ctl "$rid" note --session "$s" --say "$note"
        if [ "$LAST_RC" -ne 0 ]; then
            report "failed" "writing a note down failed with exit ${LAST_RC}; see ${RUN_LOG}"
            return
        fi
    done

    ctl "$rid" recall --session "$s" --about "axle counter reset loop"; got="$CTL_OUT"
    if [ -z "$got" ]; then
        fail_no_json "recalling by similarity"
        return
    fi

    considered="$(printf '%s' "$got" | jq -r '.considered')"
    if [ "$considered" != "4" ]; then
        report "failed" "the recall looked at ${considered} notes where the session holds four - every note in the session has to be ranked, not just the recent ones"
        return
    fi
    n="$(printf '%s' "$got" | jq -r '.recalled | length')"
    if [ "$n" != "2" ]; then
        report "failed" "the recall returned ${n} notes where two of the four are related to the query and two are not - anything below the relevance floor is noise and has to be left out"
        return
    fi
    first="$(printf '%s' "$got" | jq -r '.recalled[0].note')"
    second="$(printf '%s' "$got" | jq -r '.recalled[1].note')"
    if ! printf '%s' "$first" | grep -q 'axle counter'; then
        report "failed" "the closest note came back as ${first} - the results have to be ordered by similarity, best first"
        return
    fi
    if ! printf '%s' "$second" | grep -q 'SEC-4'; then
        report "failed" "the second result came back as ${second} instead of the possession note"
        return
    fi
    if printf '%s' "$got" | jq -r '.recalled | map(.note) | join(" ")' | grep -qE 'kettle|relays'; then
        report "failed" "an unrelated note was recalled - the relevance floor is what keeps noise out of the context"
        return
    fi
    ordered="$(printf '%s' "$got" | jq -r '[.recalled[].score] as $s | ($s == ($s | sort | reverse))')"
    if [ "$ordered" != "true" ]; then
        report "failed" "the recalled notes are not in descending order of similarity"
        return
    fi
    under="$(printf '%s' "$got" | jq -r '[.recalled[] | select(.score < 0.25)] | length')"
    if [ "$under" != "0" ]; then
        report "failed" "${under} note(s) below the relevance floor were recalled anyway"
        return
    fi
    thinks="$(trace_field "$rid" '.think')"
    if [ "$thinks" != "0" ]; then
        report "failed" "the recall asked the desk to think ${thinks} times - ranking notes by similarity is arithmetic over the store"
        return
    fi

    report "success" "all four notes were ranked, the two related ones came back best first, and both notes below the relevance floor were left out - with no help from the desk"
}

Test05
BODY05
}

for n in 01 02 03 04 05; do
    case "$n" in
        01) t="the loop acts on what came back, and the trace records it" ;;
        02) t="a question the desk cannot settle ends honestly, inside the cap" ;;
        03) t="the reviewer loop stops early when it can and at its cap when it cannot" ;;
        04) t="what the desk remembers survives the process that wrote it" ;;
        05) t="recall is ranked by similarity and floored against noise" ;;
    esac
    {
        echo '#!/bin/bash'
        echo "# TC${n} (10 pts): ${t}"
        preamble
        echo ""
        "write_${n}"
    } > "$OUT/script_${n}.sh"
    chmod +x "$OUT/script_${n}.sh"
    bash -n "$OUT/script_${n}.sh"
    echo "  wrote script_${n}.sh"
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
