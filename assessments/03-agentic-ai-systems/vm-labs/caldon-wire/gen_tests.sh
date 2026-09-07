#!/bin/bash
# Regenerate test-cases/scripts/script_01..05.sh from one shared preamble plus
# one body per behavioural theme. The platform runs every file in the test
# scripts/ folder as a test, so each script must be fully self-contained --
# hence the duplicated preamble, emitted here so it can never drift.
#
# The platform accepts at most FIVE test scripts, so each script asserts the
# cluster of facts one theme implies and is worth 10 points.
#
# NO APOSTROPHES anywhere in the generated scripts, and especially not inside a
# <<'PY' ... PY body: that heredoc sits inside a $( ) command substitution and
# bash counts quote characters while scanning for the matching paren, so one
# apostrophe makes the generated file unparseable somewhere that looks fine.
# build.sh enforces this.
#
# The bodies below are written into an UNQUOTED heredoc, so every dollar sign
# that must survive to run time is escaped as \$ and every graded input is
# spliced in unescaped. build.sh runs bash -n on the result.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$DIR/test-cases/scripts"
mkdir -p "$OUT"

# ---------------------------------------------------------------------------
# Graded inputs. Deliberately disjoint from every story that appears in
# problem-statement.md or check_local.py, so no published worked example is
# itself a graded case.
# ---------------------------------------------------------------------------
BATCH_IDS="wf-3140,wf-3147,wf-3178,wf-3185,wf-3115"
BATCH_N=5
# All five summaries go out together, so the peak has to reach the batch size.
# Measured on the authoring host across repeated runs: 5 every time, and 1 for
# a sequential loop. One is allowed off the top so a loaded VM that staggers
# one connection cannot fail a correct solution.
BATCH_MIN_PEAK=4
# A sequential run of five would take about 2.8s at the wire desk holding
# time; a concurrent one lands near 0.7s.
BATCH_MAX_SPAN_TENTHS=20

QUEUE_IDS="wf-3115,wf-3126,wf-3140,wf-3147,wf-3159,wf-3178,wf-3185"
QUEUE_N=7
QUEUE_LIMIT=3

# Six requests, two of them naming desks the wire does not staff. Order is
# fixed so the check can say exactly which entry was wrong.
NOTE_PAIRS="wf-3140:newsroom,wf-3147:sports,wf-3159:legal,wf-3178:travel,wf-3185:standards,wf-3115:picture"
NOTE_N=6
NOTE_STAFFED=4
NOTE_REJECTED=2
# The four staffed calls each hold the desk for half a second, so they overlap
# whatever order they start in. Observed 5 or 6; sequential would be 1.
NOTE_MIN_PEAK=3

# wf-3159 is a long pull; the budget is far under it, so a caller that waits
# for the reply cannot come back in time.
SLOW_STORY="wf-3159"
SLOW_BUDGET="1.2"
# Returning by 2.5s proves the wait was abandoned rather than ridden out: the
# pull itself runs to 4s.
SLOW_MAX_TENTHS=25
FAST_STORY="wf-3147"
FAST_BUDGET="10"

# A caller that stops waiting at its deadline leaves the desk holding the pull
# for about the budget. One that leaves the call running is only noticed when
# its program ends, which the harness below makes land much later. Measured:
# 12 tenths for a real deadline, 33+ for a call nobody cancelled.
ABORT_MAX_TENTHS=20

STREAM_STORY="wf-3185"
STREAM_MIN_PIECES=2
# The desk spaces the bulletin out over about a second. A caller that reads the
# whole reply and then cuts it up shows a spread near zero.
STREAM_MIN_SPREAD_TENTHS=4

# Log files were a bring-up aid and are OFF by default now that the lab is
# validated. Re-enable for a debugging session with:  TEST_LOGGING=on ./gen_tests.sh
# The single-verdict guarantee (report() + EXIT trap) is NOT part of this
# switch: it stays in both modes, because a script that dies before reporting
# would otherwise score a silent zero with no diagnostic.
TEST_LOGGING="${TEST_LOGGING:-off}"

if [ "$TEST_LOGGING" = "off" ]; then
read -r -d '' LOGGING_BLOCK <<'LOGOFF' || true
TC="$(basename "${BASH_SOURCE[0]}" .sh | sed 's/[^0-9]//g')"

# The judge captures stdout+stderr together and grades the LAST line, so a
# single stray line on stderr - a bash job-control notice, a tool warning -
# would void the verdict the same way the ERR trap did. Send this check's
# stderr to a file on the VM: diagnostics stay available, and stdout can only
# ever end in the verdict.
exec 2>>"/tmp/caldon_tc${TC}.err"
log() { :; }
log_verdict() { :; }
log_file() { :; }
trace_hint() { :; }
learner_log() { printf '/tmp/caldon_out_%s.log' "$1"; }
LOGOFF
else
read -r -d '' LOGGING_BLOCK <<'LOGON' || true
# Every stderr line and learner traceback is captured to a per-check log file.
TC="$(basename "${BASH_SOURCE[0]}" .sh | sed 's/[^0-9]//g')"
LOG_DIR="${LOG_DIR:-/tmp/caldon-lab-logs}"
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
trace_hint() { printf ' (full trace in %s)' "$LOG_TC"; }
learner_log() { printf '%s/learner_%s.log' "$LOG_DIR" "$1"; }
LOGON
fi

read -r -d '' PREAMBLE <<PRE || true
DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
source "/usr/local/bin/judge/test/common.sh" 2>/dev/null || source "\$DIR/common.sh" 2>/dev/null || true
type print_status >/dev/null 2>&1 || print_status() { echo "RESULT:\$1 | \$2"; }

# The platform helper installs `trap ... ERR`, which fires on ANY non-zero
# command regardless of set -e - including a deliberate `return 1` from a guard.
# Its handler posts an internal error and exits, landing a second line after our
# verdict; the judge grades the LAST line, so the verdict is discarded and the
# submission reports no test cases at all. Drop the inherited trap.
trap - ERR
set +eE

# --- logging & result reporting -----------------------------------------
# Nothing below can abort the script: a check must always end in one verdict,
# so there is no set -e and no set -u anywhere in this file.
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

LAB_DIR="\${LAB_DIR:-/home/user/caldon-wire}"
SVC_URL="\${SVC_URL:-http://127.0.0.1:8794}"
SVC_BIN="\${SVC_BIN:-/opt/caldon-svc/wired.py}"
GKEY="X-Grader-Key: caldon-grader-k4m8"
GPATH="__cwk4m8"
PY="\${PY:-python3}"
TO="\$(command -v timeout || command -v gtimeout || true)"
export PYTHONDONTWRITEBYTECODE=1

# Grading runs as root while the learner is user, so anything this check
# materialises under the project would be root-owned and the learner could not
# write it afterwards. Ownership is handed back from the EXIT trap rather than
# from a success path, so a run killed at the time cap still leaves a usable
# VM. The case statement bounds the chown: a mis-set or empty variable must
# never be able to reach the filesystem root.
on_exit() {
    local rc=\$?
    case "\$LAB_DIR" in
        /home/user/*) chown -R user:user "\$LAB_DIR" >/dev/null 2>&1 ;;
    esac
    log "script exiting rc=\$rc after \${SECONDS}s"
    printf 'script_%s %ss\n' "\$TC" "\$SECONDS" >>/tmp/caldon_timing.log 2>/dev/null || true
    report "failed" "TC\${TC} ended without reaching a verdict (rc=\$rc)"
}
trap on_exit EXIT

log "TC\${TC} starting"

# --- time budget --------------------------------------------------------
# The portal kills a test case that runs much beyond two minutes and reports a
# blocking process instead of a score, so every wait in this script is
# bounded: 12s waiting for the desk + 55s for the one learner run + at most a
# handful of 5s grader calls is about 90s worst case. Setup already started the
# desk and paid the import cost, so a healthy VM finishes in a few seconds;
# these numbers only cap the pathological run. Nothing below may loop without
# one of these constants.
SVC_WAIT=\${SVC_WAIT:-12}
RUN_BUDGET=\${RUN_BUDGET:-55}
CURL_MAX=\${CURL_MAX:-5}
DEPS_WAIT=\${DEPS_WAIT:-20}
DEPS_READY_FILE="\${DEPS_READY_FILE:-/var/log/caldon-lab/deps.ready}"

# The dependency install is deliberately detached from provisioning, so setup
# cannot be killed by the portal for running long. That means a check starting
# seconds after the VM came up could race the install. Wait a bounded moment
# for the file that install job writes; if this VM was provisioned by an older
# setup script that does not write one, fall back to an import probe so a
# missing file can never by itself fail a check. That file also gates curl and
# jq, which the detached job installs and which the helpers below need, so
# this has to run before anything that shells out to them.
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
    setsid nohup "\$PY" "\$SVC_BIN" >/tmp/caldon_svc.log 2>&1 </dev/null &
    local i
    for i in \$(seq 1 "\$SVC_WAIT"); do
        curl -sf -m 2 "\${SVC_URL}/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

# oracle2/oracle3 <jq-filter> <key=value>...
#   the expected value for a graded input, computed by the wire desk itself.
#   Fixed arity rather than a variadic wrapper, so no shell array is needed and
#   the helper behaves the same under every bash version the harness and the
#   judge might use.
oracle2() {
    curl -sf -m "\$CURL_MAX" -H "\$GKEY" --get \\
        --data-urlencode "\$2" --data-urlencode "\$3" \\
        "\${SVC_URL}/\${GPATH}/oracle" 2>/dev/null | jq -r "\$1"
}

trace_field() {
    curl -sf -m "\$CURL_MAX" -H "\$GKEY" \\
        "\${SVC_URL}/\${GPATH}/trace?run=\$1" 2>/dev/null | jq -r "\$2"
}

reset_run() {
    curl -sf -m "\$CURL_MAX" -X POST -H "\$GKEY" \\
        "\${SVC_URL}/\${GPATH}/reset?run=\$1" >/dev/null 2>&1
    return 0
}

# run_learner <run-id>  (python harness on stdin) -> echoes the LABJSON payload
run_learner() {
    local rid="\$1" tmp rc
    # Trailing X characters only: a suffix after them is not substituted by
    # every mktemp, which would hand back one fixed filename and collide
    # between runs.
    tmp="\$(mktemp /tmp/caldon_h_XXXXXX)" || return 1
    cat > "\$tmp"
    local out; out="\$(learner_log "\$rid")"
    ( cd "\$LAB_DIR" && export CALDON_RUN_ID="\$rid" PYTHONPATH="\$LAB_DIR" && \\
        run_bounded "\$PY" "\$tmp" ) >"\$out" 2>&1
    rc=\$?
    rm -f "\$tmp"
    log "learner run \$rid exited rc=\$rc; output in \$out"
    log_file "\$out"
    grep -o 'LABJSON:.*' "\$out" | head -1 | cut -c9-
    return \$rc
}

fail_no_output() {
    report "failed" "\$1 - Python error in \$(learner_log "\$2")\$(trace_hint)"
}

# The interface contract says every model call goes through the provided
# client, which is what attributes a call to the run being graded. A client the
# caller assembled themselves is not attributed, so the desk sees the work but
# cannot tell whose it is. Checked in every script rather than one, because a
# call that is not attributed cannot be reasoned about at all.
require_via_kit() {
    local rid="\$1" total via
    total="\$(trace_field "\$rid" '.total')"
    via="\$(trace_field "\$rid" '.via_kit')"
    if [ "\${via:-0}" != "\${total:-0}" ]; then
        report "failed" "\$(( \${total:-0} - \${via:-0} )) of the \${total:-0} calls the wire desk received did not come through make_async_client() - every model call has to go through the provided client, which is what attributes it to you"
        return 1
    fi
    return 0
}

# Guard: an unreadable expected value must never silently match an empty result.
require_expected() {
    if [ -z "\$1" ] || [ "\$1" = "null" ]; then
        report "failed" "Grader could not read the expected result from the wire desk on \${SVC_URL}"
        return 1
    fi
    return 0
}

# Refuse an untouched project in about a second rather than timing out with no
# message. Both plausible causes are named, because from the outside they look
# the same.
require_started() {
    local left
    if [ ! -f "\${LAB_DIR}/solution.py" ]; then
        report "failed" "No solution.py in \${LAB_DIR} - the checks read the file you write there"
        return 1
    fi
    left="\$(grep -c 'raise NotImplementedError' "\${LAB_DIR}/solution.py" 2>/dev/null | tr -d ' ')"
    # Both conditions, so a learner whose own helpers happen to raise
    # NotImplementedError is never refused: a finished solution always contains
    # a model call, because there is no other way to reach the wire desk.
    if [ "\${left:-0}" -ge 5 ] \\
       && ! grep -q 'chat.completions' "\${LAB_DIR}/solution.py" 2>/dev/null; then
        report "failed" "\${LAB_DIR}/solution.py is still the untouched starter - write the five functions, then run python3 check_local.py from \${LAB_DIR} before submitting"
        return 1
    fi
    return 0
}

preflight() {
    ensure_deps || { report "failed" "The Python dependency for this lab (openai) is not installed on this VM - see /var/log/caldon-lab/pip.log"; return 1; }
    ensure_service || { report "failed" "The wire desk is not reachable on \${SVC_URL}"; return 1; }
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
    local want rid out got n peak span_t
    want="\$(oracle2 '.texts | join("|")' "kind=summary" "ids=${BATCH_IDS}")"
    require_expected "\$want" || return

    rid="tc01_\$\$"
    reset_run "\$rid"
    out="\$(IDS="${BATCH_IDS}" run_learner "\$rid" <<'PY'
import asyncio, json, os, sys
sys.path.insert(0, ".")
import solution

ids = os.environ["IDS"].split(",")
got = asyncio.run(solution.summarise_batch(ids))
print("LABJSON:" + json.dumps({
    "n": len(got),
    "joined": "|".join(str(x).strip() for x in got),
}))
PY
)"
    if [ -z "\$out" ]; then
        fail_no_output "summarise_batch did not return a list of summaries" "\$rid"
        return
    fi

    n="\$(printf '%s' "\$out" | jq -r '.n')"
    got="\$(printf '%s' "\$out" | jq -r '.joined')"
    peak="\$(trace_field "\$rid" '.peak')"
    span_t="\$(trace_field "\$rid" '(.span * 10) | round')"
    total="\$(trace_field "\$rid" '.total')"

    require_via_kit "\$rid" || return
    if [ "\$n" != "${BATCH_N}" ]; then
        report "failed" "summarise_batch returned \$n summaries for ${BATCH_N} stories"
        return
    fi
    if [ "\$got" != "\$want" ]; then
        report "failed" "summarise_batch returned the wrong summaries or the wrong order - the list must line up with the story ids it was given"
        return
    fi
    if [ "\${total:-0}" != "${BATCH_N}" ]; then
        report "failed" "the wire desk saw \${total:-0} requests for ${BATCH_N} stories - each story needs exactly one call"
        return
    fi
    if [ "\${peak:-0}" -lt "${BATCH_MIN_PEAK}" ]; then
        report "failed" "the wire desk never had more than \${peak:-0} of the ${BATCH_N} requests open at once, so the calls were made one after another rather than together"
        return
    fi
    if [ "\${span_t:-999}" -gt "${BATCH_MAX_SPAN_TENTHS}" ]; then
        report "failed" "the ${BATCH_N} calls took \${span_t}00ms end to end, which is close to the sum of them rather than the longest one"
        return
    fi
    report "success" "${BATCH_N} summaries correct and in order, \$peak of them open at the desk at once, all ${BATCH_N} done in \${span_t}00ms"
}

Test01
BODY
emit 01 "summaries fan out together and come back in the order they were asked for" "$TMPD/b01"

# --- TC02 -----------------------------------------------------------------
cat > "$TMPD/b02" <<BODY

Test02() {
    preflight || return
    local want rid out got peak total
    want="\$(oracle2 '.ranking | join(",")' "kind=urgency" "ids=${QUEUE_IDS}")"
    require_expected "\$want" || return

    rid="tc02_\$\$"
    reset_run "\$rid"
    out="\$(IDS="${QUEUE_IDS}" LIMIT="${QUEUE_LIMIT}" run_learner "\$rid" <<'PY'
import asyncio, json, os, sys
sys.path.insert(0, ".")
import solution

ids = os.environ["IDS"].split(",")
got = asyncio.run(solution.rank_urgency(ids, int(os.environ["LIMIT"])))
print("LABJSON:" + json.dumps({
    "n": len(got),
    "joined": ",".join(str(x).strip() for x in got),
}))
PY
)"
    if [ -z "\$out" ]; then
        fail_no_output "rank_urgency did not return a ranking" "\$rid"
        return
    fi

    got="\$(printf '%s' "\$out" | jq -r '.joined')"
    peak="\$(trace_field "\$rid" '.peak')"
    total="\$(trace_field "\$rid" '.total')"

    require_via_kit "\$rid" || return
    if [ "\${total:-0}" != "${QUEUE_N}" ]; then
        report "failed" "the wire desk scored \${total:-0} stories out of ${QUEUE_N} - every story in the queue needs exactly one call"
        return
    fi
    if [ "\${peak:-0}" -gt "${QUEUE_LIMIT}" ]; then
        report "failed" "\${peak} calls were open at the wire desk at once with a limit of ${QUEUE_LIMIT} - the cap has to hold for the whole queue, not just the first few"
        return
    fi
    if [ "\${peak:-0}" -lt "${QUEUE_LIMIT}" ]; then
        report "failed" "never more than \${peak:-0} call was open at once against a limit of ${QUEUE_LIMIT}, so the queue was worked through slower than it was allowed to be"
        return
    fi
    if [ "\$got" != "\$want" ]; then
        report "failed" "rank_urgency returned the wrong order - rank by the score the desk returns, hardest push first"
        return
    fi
    report "success" "all ${QUEUE_N} stories scored and ranked correctly with exactly ${QUEUE_LIMIT} calls open at the busiest moment"
}

Test02
BODY
emit 02 "the whole queue is scored, never more than the allowed number at a time" "$TMPD/b02"

# --- TC03 -----------------------------------------------------------------
cat > "$TMPD/b03" <<BODY

Test03() {
    preflight || return
    local want_notes want_flags rid out got_notes got_flags peak total rejected n
    want_notes="\$(oracle2 '[.entries[] | select(.staffed) | .text] | join("|")' "kind=notes" "pairs=${NOTE_PAIRS}")"
    require_expected "\$want_notes" || return
    want_flags="\$(oracle2 '[.entries[] | if .staffed then "1" else "0" end] | join("")' "kind=notes" "pairs=${NOTE_PAIRS}")"
    require_expected "\$want_flags" || return

    rid="tc03_\$\$"
    reset_run "\$rid"
    out="\$(PAIRS="${NOTE_PAIRS}" run_learner "\$rid" <<'PY'
import asyncio, json, os, sys
sys.path.insert(0, ".")
import solution

requests = []
for pair in os.environ["PAIRS"].split(","):
    story_id, _, desk = pair.partition(":")
    requests.append({"story_id": story_id, "desk": desk})

got = asyncio.run(solution.gather_desk_notes(requests))
flags, notes, blank = "", [], 0
for entry in got:
    entry = entry if isinstance(entry, dict) else {}
    if entry.get("ok"):
        flags += "1"
        notes.append(str(entry.get("note") or "").strip())
    else:
        flags += "0"
        if not str(entry.get("error") or "").strip():
            blank += 1
print("LABJSON:" + json.dumps({
    "n": len(got),
    "flags": flags,
    "notes": "|".join(notes),
    "blank_errors": blank,
}))
PY
)"
    if [ -z "\$out" ]; then
        fail_no_output "gather_desk_notes did not return one entry per request - a rejected desk has to come back as a value, not as an exception" "\$rid"
        return
    fi

    n="\$(printf '%s' "\$out" | jq -r '.n')"
    got_flags="\$(printf '%s' "\$out" | jq -r '.flags')"
    got_notes="\$(printf '%s' "\$out" | jq -r '.notes')"
    blank="\$(printf '%s' "\$out" | jq -r '.blank_errors')"
    peak="\$(trace_field "\$rid" '.peak')"
    total="\$(trace_field "\$rid" '.total')"
    rejected="\$(trace_field "\$rid" '.rejected')"

    require_via_kit "\$rid" || return
    if [ "\$n" != "${NOTE_N}" ]; then
        report "failed" "gather_desk_notes returned \$n entries for ${NOTE_N} requests - every request needs an entry, in the order it was given"
        return
    fi
    if [ "\$got_flags" != "\$want_flags" ]; then
        report "failed" "the ok flags came back as \$got_flags but the desks staffed for these requests are \$want_flags - a request the desk rejects is not ok, and one it answers is"
        return
    fi
    if [ "\${blank:-0}" != "0" ]; then
        report "failed" "\${blank} of the failed entries carry no error text - record what went wrong so the caller can see it"
        return
    fi
    if [ "\$got_notes" != "\$want_notes" ]; then
        report "failed" "the notes that did come back do not match what those desks wrote"
        return
    fi
    if [ "\${total:-0}" != "${NOTE_N}" ]; then
        report "failed" "the wire desk saw \${total:-0} requests for ${NOTE_N} - every request goes out, including the ones that will be rejected"
        return
    fi
    if [ "\${rejected:-0}" != "${NOTE_REJECTED}" ]; then
        report "failed" "the wire desk rejected \${rejected:-0} requests where ${NOTE_REJECTED} were expected"
        return
    fi
    if [ "\${peak:-0}" -lt "${NOTE_MIN_PEAK}" ]; then
        report "failed" "the wire desk never had more than \${peak:-0} requests open at once, so a rejection stopped the rest from running alongside it"
        return
    fi
    report "success" "all ${NOTE_N} requests came back as values with ${NOTE_STAFFED} notes and ${NOTE_REJECTED} recorded failures, \$peak open at the desk at once"
}

Test03
BODY
emit 03 "one rejected desk becomes a value and the rest of the batch still runs" "$TMPD/b03"

# --- TC04 -----------------------------------------------------------------
cat > "$TMPD/b04" <<BODY

Test04() {
    preflight || return
    local want rid out slow_ok slow_tenths fast_ok fast_text arrived aborted held
    want="\$(oracle2 '.text' "kind=bulletin" "id=${FAST_STORY}")"
    require_expected "\$want" || return

    rid="tc04_\$\$"
    reset_run "\$rid"
    out="\$(SLOW="${SLOW_STORY}" SLOW_BUDGET="${SLOW_BUDGET}" FAST="${FAST_STORY}" FAST_BUDGET="${FAST_BUDGET}" \\
            run_learner "\$rid" <<'PY'
import asyncio, json, os, sys, time
sys.path.insert(0, ".")
import solution


async def main():
    started = time.perf_counter()
    slow = await solution.bulletin_under_deadline(
        os.environ["SLOW"], float(os.environ["SLOW_BUDGET"]))
    elapsed = time.perf_counter() - started
    fast = await solution.bulletin_under_deadline(
        os.environ["FAST"], float(os.environ["FAST_BUDGET"]))
    # The desk notices a dropped call while it is still holding the reply. This
    # wait is long enough that a call which was genuinely abandoned at the
    # deadline and one that was simply left running look nothing alike from the
    # desk side, because the second is only noticed when this process ends.
    await asyncio.sleep(1.6)
    slow = slow if isinstance(slow, dict) else {}
    fast = fast if isinstance(fast, dict) else {}
    print("LABJSON:" + json.dumps({
        "slow_ok": bool(slow.get("ok")),
        "slow_tenths": int(round(elapsed * 10)),
        "slow_keys": sorted(str(k) for k in slow.keys()),
        "fast_ok": bool(fast.get("ok")),
        "fast_text": str(fast.get("text") or "").strip(),
    }))

asyncio.run(main())
PY
)"
    if [ -z "\$out" ]; then
        fail_no_output "bulletin_under_deadline did not return a result for both budgets" "\$rid"
        return
    fi

    slow_ok="\$(printf '%s' "\$out" | jq -r '.slow_ok')"
    slow_tenths="\$(printf '%s' "\$out" | jq -r '.slow_tenths')"
    fast_ok="\$(printf '%s' "\$out" | jq -r '.fast_ok')"
    fast_text="\$(printf '%s' "\$out" | jq -r '.fast_text')"
    arrived="\$(trace_field "\$rid" '.total')"
    aborted="\$(trace_field "\$rid" '.aborted')"
    held="\$(trace_field "\$rid" '.abort_held_tenths')"

    require_via_kit "\$rid" || return
    if [ "\$slow_ok" != "false" ]; then
        report "failed" "the pull that could not finish inside ${SLOW_BUDGET}s was reported as a success - a bulletin that missed its deadline has to say so"
        return
    fi
    if [ "\${slow_tenths:-999}" -gt "${SLOW_MAX_TENTHS}" ]; then
        report "failed" "the call with a ${SLOW_BUDGET}s budget took \${slow_tenths}00ms to come back, so the wait ran on well past the deadline instead of being abandoned at it"
        return
    fi
    if [ "\${arrived:-0}" -lt 2 ]; then
        report "failed" "the wire desk received \${arrived:-0} requests across the two budgets - a deadline is something you place on a call you actually made"
        return
    fi
    if [ "\${aborted:-0}" -lt 1 ]; then
        report "failed" "the wire desk was still holding the reply for ${SLOW_STORY} when it finished, so the call was left running rather than dropped at the deadline"
        return
    fi
    if [ "\${held:-999}" -gt "${ABORT_MAX_TENTHS}" ]; then
        report "failed" "the wire desk went on holding the reply for ${SLOW_STORY} for \${held}00ms - far past the ${SLOW_BUDGET}s deadline - so the call was never actually dropped, it just ended when the program did"
        return
    fi
    if [ "\$fast_ok" != "true" ]; then
        report "failed" "the pull that had ${FAST_BUDGET}s of budget was reported as a miss - a generous deadline must let the bulletin through"
        return
    fi
    if [ "\$fast_text" != "\$want" ]; then
        report "failed" "the bulletin returned inside the generous budget is not the one the desk wrote for ${FAST_STORY}"
        return
    fi
    report "success" "the long pull was dropped at its deadline after \${slow_tenths}00ms and the desk stopped holding it \${held}00ms in, while the pull with room to finish returned its bulletin"
}

Test04
BODY
emit 04 "a deadline abandons a call that is still running and lets a finishable one through" "$TMPD/b04"

# --- TC05 -----------------------------------------------------------------
cat > "$TMPD/b05" <<BODY

Test05() {
    preflight || return
    local want rid out isgen pieces spread text streamed
    want="\$(oracle2 '.text' "kind=bulletin" "id=${STREAM_STORY}")"
    require_expected "\$want" || return

    rid="tc05_\$\$"
    reset_run "\$rid"
    out="\$(STORY="${STREAM_STORY}" run_learner "\$rid" <<'PY'
import asyncio, inspect, json, os, sys, time
sys.path.insert(0, ".")
import solution


async def main():
    stamps, parts = [], []
    async for piece in solution.stream_bulletin(os.environ["STORY"]):
        stamps.append(time.perf_counter())
        parts.append(str(piece))
    spread = (stamps[-1] - stamps[0]) if len(stamps) > 1 else 0.0
    print("LABJSON:" + json.dumps({
        "isgen": bool(inspect.isasyncgenfunction(solution.stream_bulletin)),
        "pieces": len(parts),
        "spread_tenths": int(round(spread * 10)),
        "text": "".join(parts).strip(),
    }))

asyncio.run(main())
PY
)"
    if [ -z "\$out" ]; then
        fail_no_output "stream_bulletin did not yield anything that async for could read" "\$rid"
        return
    fi

    isgen="\$(printf '%s' "\$out" | jq -r '.isgen')"
    pieces="\$(printf '%s' "\$out" | jq -r '.pieces')"
    spread="\$(printf '%s' "\$out" | jq -r '.spread_tenths')"
    text="\$(printf '%s' "\$out" | jq -r '.text')"
    streamed="\$(trace_field "\$rid" '.streamed')"

    require_via_kit "\$rid" || return
    if [ "\$isgen" != "true" ]; then
        report "failed" "stream_bulletin is not an async generator, so a caller cannot drive it with async for"
        return
    fi
    if [ "\${pieces:-0}" -lt "${STREAM_MIN_PIECES}" ]; then
        report "failed" "stream_bulletin yielded \${pieces:-0} pieces - a bulletin arrives in more than one"
        return
    fi
    if [ "\$text" != "\$want" ]; then
        report "failed" "the pieces joined together are not the bulletin the desk wrote for ${STREAM_STORY}"
        return
    fi
    if [ "\${streamed:-0}" -lt 1 ]; then
        report "failed" "the wire desk was never asked for a streamed bulletin, so the pieces were cut from a reply that had already arrived whole"
        return
    fi
    if [ "\${spread:-0}" -lt "${STREAM_MIN_SPREAD_TENTHS}" ]; then
        report "failed" "every piece arrived within \${spread}00ms of the first, so they were handed over after the bulletin was complete rather than as it came in"
        return
    fi
    report "success" "the bulletin arrived as \${pieces} pieces spread over \${spread}00ms and joins back into exactly what the desk wrote"
}

Test05
BODY
emit 05 "the bulletin is yielded piece by piece as it arrives, not after it lands" "$TMPD/b05"

echo "wrote $(ls -1 "$OUT"/script_*.sh | wc -l | tr -d ' ') test scripts to $OUT"
