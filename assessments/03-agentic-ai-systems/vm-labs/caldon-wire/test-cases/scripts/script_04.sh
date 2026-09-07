#!/bin/bash
# TC04 (10 pts): a deadline abandons a call that is still running and lets a finishable one through
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "/usr/local/bin/judge/test/common.sh" 2>/dev/null || source "$DIR/common.sh" 2>/dev/null || true
type print_status >/dev/null 2>&1 || print_status() { echo "RESULT:$1 | $2"; }

# The platform helper installs , which fires on ANY non-zero
# command regardless of set -e - including a deliberate  from a guard.
# Its handler posts an internal error and exits, landing a second line after our
# verdict; the judge grades the LAST line, so the verdict is discarded and the
# submission reports no test cases at all. Drop the inherited trap.
trap - ERR
set +eE

# --- logging & result reporting -----------------------------------------
# Nothing below can abort the script: a check must always end in one verdict,
# so there is no set -e and no set -u anywhere in this file.
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

LAB_DIR="${LAB_DIR:-/home/user/caldon-wire}"
SVC_URL="${SVC_URL:-http://127.0.0.1:8794}"
SVC_BIN="${SVC_BIN:-/opt/caldon-svc/wired.py}"
GKEY="X-Grader-Key: caldon-grader-k4m8"
GPATH="__cwk4m8"
PY="${PY:-python3}"
TO="$(command -v timeout || command -v gtimeout || true)"
export PYTHONDONTWRITEBYTECODE=1

# Grading runs as root while the learner is user, so anything this check
# materialises under the project would be root-owned and the learner could not
# write it afterwards. Ownership is handed back from the EXIT trap rather than
# from a success path, so a run killed at the time cap still leaves a usable
# VM. The case statement bounds the chown: a mis-set or empty variable must
# never be able to reach the filesystem root.
on_exit() {
    local rc=$?
    case "$LAB_DIR" in
        /home/user/*) chown -R user:user "$LAB_DIR" >/dev/null 2>&1 ;;
    esac
    log "script exiting rc=$rc after ${SECONDS}s"
    printf 'script_%s %ss\n' "$TC" "$SECONDS" >>/tmp/caldon_timing.log 2>/dev/null || true
    report "failed" "TC${TC} ended without reaching a verdict (rc=$rc)"
}
trap on_exit EXIT

log "TC${TC} starting"

# --- time budget --------------------------------------------------------
# The portal kills a test case that runs much beyond two minutes and reports a
# blocking process instead of a score, so every wait in this script is
# bounded: 12s waiting for the desk + 55s for the one learner run + at most a
# handful of 5s grader calls is about 90s worst case. Setup already started the
# desk and paid the import cost, so a healthy VM finishes in a few seconds;
# these numbers only cap the pathological run. Nothing below may loop without
# one of these constants.
SVC_WAIT=${SVC_WAIT:-12}
RUN_BUDGET=${RUN_BUDGET:-55}
CURL_MAX=${CURL_MAX:-5}
DEPS_WAIT=${DEPS_WAIT:-20}
DEPS_READY_FILE="${DEPS_READY_FILE:-/var/log/caldon-lab/deps.ready}"

# The dependency install is deliberately detached from provisioning, so setup
# cannot be killed by the portal for running long. That means a check starting
# seconds after the VM came up could race the install. Wait a bounded moment
# for the file that install job writes; if this VM was provisioned by an older
# setup script that does not write one, fall back to an import probe so a
# missing file can never by itself fail a check. That file also gates curl and
# jq, which the detached job installs and which the helpers below need, so
# this has to run before anything that shells out to them.
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
    setsid nohup "$PY" "$SVC_BIN" >/tmp/caldon_svc.log 2>&1 </dev/null &
    local i
    for i in $(seq 1 "$SVC_WAIT"); do
        curl -sf -m 2 "${SVC_URL}/health" >/dev/null 2>&1 && return 0
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
    curl -sf -m "$CURL_MAX" -H "$GKEY" --get \
        --data-urlencode "$2" --data-urlencode "$3" \
        "${SVC_URL}/${GPATH}/oracle" 2>/dev/null | jq -r "$1"
}

trace_field() {
    curl -sf -m "$CURL_MAX" -H "$GKEY" \
        "${SVC_URL}/${GPATH}/trace?run=$1" 2>/dev/null | jq -r "$2"
}

reset_run() {
    curl -sf -m "$CURL_MAX" -X POST -H "$GKEY" \
        "${SVC_URL}/${GPATH}/reset?run=$1" >/dev/null 2>&1
    return 0
}

# run_learner <run-id>  (python harness on stdin) -> echoes the LABJSON payload
run_learner() {
    local rid="$1" tmp rc
    # Trailing X characters only: a suffix after them is not substituted by
    # every mktemp, which would hand back one fixed filename and collide
    # between runs.
    tmp="$(mktemp /tmp/caldon_h_XXXXXX)" || return 1
    cat > "$tmp"
    local out; out="$(learner_log "$rid")"
    ( cd "$LAB_DIR" && export CALDON_RUN_ID="$rid" PYTHONPATH="$LAB_DIR" && \
        run_bounded "$PY" "$tmp" ) >"$out" 2>&1
    rc=$?
    rm -f "$tmp"
    log "learner run $rid exited rc=$rc; output in $out"
    log_file "$out"
    grep -o 'LABJSON:.*' "$out" | head -1 | cut -c9-
    return $rc
}

fail_no_output() {
    report "failed" "$1 - Python error in $(learner_log "$2")$(trace_hint)"
}

# The interface contract says every model call goes through the provided
# client, which is what attributes a call to the run being graded. A client the
# caller assembled themselves is not attributed, so the desk sees the work but
# cannot tell whose it is. Checked in every script rather than one, because a
# call that is not attributed cannot be reasoned about at all.
require_via_kit() {
    local rid="$1" total via
    total="$(trace_field "$rid" '.total')"
    via="$(trace_field "$rid" '.via_kit')"
    if [ "${via:-0}" != "${total:-0}" ]; then
        report "failed" "$(( ${total:-0} - ${via:-0} )) of the ${total:-0} calls the wire desk received did not come through make_async_client() - every model call has to go through the provided client, which is what attributes it to you"
        return 1
    fi
    return 0
}

# Guard: an unreadable expected value must never silently match an empty result.
require_expected() {
    if [ -z "$1" ] || [ "$1" = "null" ]; then
        report "failed" "Grader could not read the expected result from the wire desk on ${SVC_URL}"
        return 1
    fi
    return 0
}

# Refuse an untouched project in about a second rather than timing out with no
# message. Both plausible causes are named, because from the outside they look
# the same.
require_started() {
    local left
    if [ ! -f "${LAB_DIR}/solution.py" ]; then
        report "failed" "No solution.py in ${LAB_DIR} - the checks read the file you write there"
        return 1
    fi
    left="$(grep -c 'raise NotImplementedError' "${LAB_DIR}/solution.py" 2>/dev/null | tr -d ' ')"
    # Both conditions, so a learner whose own helpers happen to raise
    # NotImplementedError is never refused: a finished solution always contains
    # a model call, because there is no other way to reach the wire desk.
    if [ "${left:-0}" -ge 5 ] \
       && ! grep -q 'chat.completions' "${LAB_DIR}/solution.py" 2>/dev/null; then
        report "failed" "${LAB_DIR}/solution.py is still the untouched starter - write the five functions, then run python3 check_local.py from ${LAB_DIR} before submitting"
        return 1
    fi
    return 0
}

preflight() {
    ensure_deps || { report "failed" "The Python dependency for this lab (openai) is not installed on this VM - see /var/log/caldon-lab/pip.log"; return 1; }
    ensure_service || { report "failed" "The wire desk is not reachable on ${SVC_URL}"; return 1; }
    require_started || return 1
    return 0
}

Test04() {
    preflight || return
    local want rid out slow_ok slow_tenths fast_ok fast_text arrived aborted held
    want="$(oracle2 '.text' "kind=bulletin" "id=wf-3147")"
    require_expected "$want" || return

    rid="tc04_$$"
    reset_run "$rid"
    out="$(SLOW="wf-3159" SLOW_BUDGET="1.2" FAST="wf-3147" FAST_BUDGET="10" \
            run_learner "$rid" <<'PY'
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
    if [ -z "$out" ]; then
        fail_no_output "bulletin_under_deadline did not return a result for both budgets" "$rid"
        return
    fi

    slow_ok="$(printf '%s' "$out" | jq -r '.slow_ok')"
    slow_tenths="$(printf '%s' "$out" | jq -r '.slow_tenths')"
    fast_ok="$(printf '%s' "$out" | jq -r '.fast_ok')"
    fast_text="$(printf '%s' "$out" | jq -r '.fast_text')"
    arrived="$(trace_field "$rid" '.total')"
    aborted="$(trace_field "$rid" '.aborted')"
    held="$(trace_field "$rid" '.abort_held_tenths')"

    require_via_kit "$rid" || return
    if [ "$slow_ok" != "false" ]; then
        report "failed" "the pull that could not finish inside 1.2s was reported as a success - a bulletin that missed its deadline has to say so"
        return
    fi
    if [ "${slow_tenths:-999}" -gt "25" ]; then
        report "failed" "the call with a 1.2s budget took ${slow_tenths}00ms to come back, so the wait ran on well past the deadline instead of being abandoned at it"
        return
    fi
    if [ "${arrived:-0}" -lt 2 ]; then
        report "failed" "the wire desk received ${arrived:-0} requests across the two budgets - a deadline is something you place on a call you actually made"
        return
    fi
    if [ "${aborted:-0}" -lt 1 ]; then
        report "failed" "the wire desk was still holding the reply for wf-3159 when it finished, so the call was left running rather than dropped at the deadline"
        return
    fi
    if [ "${held:-999}" -gt "20" ]; then
        report "failed" "the wire desk went on holding the reply for wf-3159 for ${held}00ms - far past the 1.2s deadline - so the call was never actually dropped, it just ended when the program did"
        return
    fi
    if [ "$fast_ok" != "true" ]; then
        report "failed" "the pull that had 10s of budget was reported as a miss - a generous deadline must let the bulletin through"
        return
    fi
    if [ "$fast_text" != "$want" ]; then
        report "failed" "the bulletin returned inside the generous budget is not the one the desk wrote for wf-3147"
        return
    fi
    report "success" "the long pull was dropped at its deadline after ${slow_tenths}00ms and the desk stopped holding it ${held}00ms in, while the pull with room to finish returned its bulletin"
}

Test04
