#!/bin/bash
# Ordering matrix. The happy path passing tells you almost nothing: the failures
# that reach learners come from orderings nobody tried - submitting before
# running anything, a grading run killed half way, a second submission.
#
# Every row asserts the score AND that the learner is not locked out of their
# own project afterwards. The checkpoint store is the thing to watch here:
# running the program creates state/claims.db, and a root-owned SQLite file
# gives the learner a readonly database from then on.
#
# Run as root on the target VM once before the first cohort. On an authoring
# host with no `user` account the ownership rows self-report as vacuous.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$(cd "$DIR/.." && pwd)"
SCRIPTS="$PACK/test-cases/scripts"
LAB_DIR="${LAB_DIR:-/tmp/westmere-perm}"
DESK_URL="${DESK_URL:-http://127.0.0.1:8579}"
PY="${PY:-python3}"
export LAB_DIR DESK_URL PY
export WESTMERE_DESK_URL="$DESK_URL"
export DEPS_READY_FILE="${DEPS_READY_FILE:-/tmp/westmere-deps.ready}"
export TIMING_LOG="/tmp/westmere_perm_timing.log"
export DESK_BIN="$PACK/service/claimsvc.py"
touch "$DEPS_READY_FILE"

HAVE_USER=0
id -u user >/dev/null 2>&1 && HAVE_USER=1
ROWS=0; BAD=0
note() { printf '  %s\n' "$*"; }
fail() { BAD=$((BAD + 1)); printf '  FAIL %s\n' "$*"; }
pass() { printf '  ok   %s\n' "$*"; }

DESK_PID=""
start_desk() {
    curl -sf -m 2 "${DESK_URL}/health" >/dev/null 2>&1 && return 0
    local port; port="$(printf '%s' "$DESK_URL" | sed 's|.*:||; s|/.*||')"
    WESTMERE_PORT="$port" WESTMERE_CLAIMS="$PACK/app/data/claims.json" \
        "$PY" "$DESK_BIN" >/tmp/westmere_perm_desk.log 2>&1 &
    DESK_PID=$!
    disown "$DESK_PID" 2>/dev/null || true
    local i
    for i in $(seq 1 20); do
        curl -sf -m 2 "${DESK_URL}/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}
cleanup() { [ -n "$DESK_PID" ] && kill "$DESK_PID" 2>/dev/null; return 0; }
trap cleanup EXIT

assemble() {  # assemble <written:0|1> [candidate.py]
    rm -rf "$LAB_DIR"
    mkdir -p "$LAB_DIR/data" "$LAB_DIR/state"
    cp -R "$PACK/app/claim_kit" "$LAB_DIR/"
    cp "$PACK/app/check_local.py" "$LAB_DIR/"
    cp "$PACK/app/data/claims.json" "$LAB_DIR/data/"
    if [ -n "${2:-}" ]; then
        cp "$2" "$LAB_DIR/claimctl.py"
    elif [ "$1" = "1" ]; then
        cp "$PACK/reference-solution/claimctl.py" "$LAB_DIR/claimctl.py"
    else
        cp "$PACK/app/claimctl_stub.py" "$LAB_DIR/claimctl.py"
    fi
    # Setup pre-creates the store as the learner. Reproduce that here, because
    # it is the defence being tested.
    : > "$LAB_DIR/state/claims.db"
    [ "$HAVE_USER" -eq 1 ] && chown -R user:user "$LAB_DIR" 2>/dev/null
    return 0
}

grade() {  # grade [n-scripts] -> echoes score
    local limit="${1:-5}" n=0 good=0 verdict
    for s in "$SCRIPTS"/script_*.sh; do
        n=$((n + 1))
        [ "$n" -gt "$limit" ] && break
        # The verdict is the LAST line, exactly as the judge reads it, and it
        # is JSON whenever common.sh is present - which it always is, next to
        # these scripts. Grepping for the RESULT: fallback scored every row
        # 0/50 and made the whole matrix vacuous.
        verdict="$(bash "$s" 2>&1 | tail -1)"
        if printf '%s' "$verdict" | jq -e '.status == "success"' >/dev/null 2>&1 \
           || printf '%s' "$verdict" | grep -q '^RESULT:success'; then
            good=$((good + 1))
        fi
    done
    echo $((good * 10))
}

check_ownership() {
    if [ "$HAVE_USER" -eq 0 ]; then
        note "ownership assertion VACUOUS on this host (no user account) - run this on the VM"
        return 0
    fi
    local rooted
    rooted="$(find "$LAB_DIR" -user root 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${rooted:-0}" -ne 0 ]; then
        fail "$1: ${rooted} root-owned paths under the project"
        find "$LAB_DIR" -user root 2>/dev/null | head -5 | sed 's/^/       /'
    else
        pass "$1: nothing under the project is root-owned"
    fi
}

check_learner_can_work() {
    local rc
    if [ "$HAVE_USER" -eq 1 ]; then
        su - user -c "cd $LAB_DIR && WESTMERE_DESK_URL=$DESK_URL $PY claimctl.py chat --thread learner-after --say 'my policy is WM-P-4410' >/dev/null"
        rc=$?
    else
        ( cd "$LAB_DIR" && WESTMERE_DESK_URL="$DESK_URL" "$PY" claimctl.py \
            chat --thread learner-after --say "my policy is WM-P-4410" >/dev/null )
        rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        pass "$1: the learner can still write to their own store afterwards"
    else
        fail "$1: the learner cannot run their own program afterwards (exit $rc)"
    fi
}

row() { ROWS=$((ROWS + 1)); echo; echo "--- row ${ROWS}: $* ---"; }

start_desk || { echo "the claims desk would not start"; exit 1; }

row "starter untouched"
assemble 0
S="$(grade)"
[ "$S" = "0" ] && pass "score ${S}/50 as expected" || fail "score ${S}/50, expected 0/50"
check_ownership "row ${ROWS}"

row "written, never run by the learner"
assemble 1
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 - the checks run the program themselves" \
                || fail "score ${S}/50, expected 50/50"
check_ownership "row ${ROWS}"
check_learner_can_work "row ${ROWS}"

row "learner ran it first, then graded"
assemble 1
( cd "$LAB_DIR" && WESTMERE_DESK_URL="$DESK_URL" "$PY" claimctl.py chat \
    --thread learner-first --say "my policy is WM-P-4425" >/dev/null 2>&1 )
[ "$HAVE_USER" -eq 1 ] && chown -R user:user "$LAB_DIR" 2>/dev/null
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 as expected" || fail "score ${S}/50, expected 50/50"
check_ownership "row ${ROWS}"
check_learner_can_work "row ${ROWS}"

row "grading killed after three checks (partial run)"
S="$(grade 3)"
[ "$S" = "30" ] && pass "partial score ${S}/50 as expected" || fail "partial score ${S}/50, expected 30/50"
check_ownership "row ${ROWS}"
check_learner_can_work "row ${ROWS}"

row "graded a second time on the same VM"
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 on the repeat" || fail "score ${S}/50 on the repeat, expected 50/50"
check_ownership "row ${ROWS}"

row "graded a third time - the store keeps growing but the score does not move"
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 on the third pass" || fail "score ${S}/50 on the third pass, expected 50/50"
DBSIZE="$(wc -c < "$LAB_DIR/state/claims.db" 2>/dev/null | tr -d ' ')"
note "store is now ${DBSIZE} bytes"
check_ownership "row ${ROWS}"
check_learner_can_work "row ${ROWS}"

row "store deleted between runs"
rm -f "$LAB_DIR/state/claims.db"
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 with the store recreated from scratch" \
                || fail "score ${S}/50, expected 50/50"
check_ownership "row ${ROWS}"

# Reported from the portal: a submission that crashed inside one branch was
# told only "printed no JSON object (exit 0); its output is in " - a status
# that was never true and a path that was never printed, because run_ctl was
# being called inside $( ) and everything it recorded died in that subshell.
# The learner had no way to reach the traceback. This row fails if a failing
# check ever again hands back a verdict that does not name a real log.
row "a crash inside one branch is diagnosable from the verdict alone"
assemble 1 "$PACK/reference-solution/_defect8_tool_args.py"
rm -f /tmp/westmere_out_02_*.log
VERDICT="$(bash "$SCRIPTS/script_02.sh" 2>&1 | tail -1)"
VSTATUS="$(printf '%s' "$VERDICT" | jq -r '.status // "UNPARSEABLE"' 2>/dev/null || echo UNPARSEABLE)"
VMSG="$(printf '%s' "$VERDICT" | jq -r '.message // empty' 2>/dev/null)"
if [ "$VSTATUS" = "failed" ]; then
    pass "the crashing branch is reported as a failure"
else
    fail "a submission that crashes in fraud_review graded ${VSTATUS}"
fi
VRC="$(printf '%s' "$VMSG" | sed -n 's/.*(exit \([0-9]*\)).*/\1/p')"
VLOG="$(printf '%s' "$VMSG" | sed -n 's|.*its output is in \(/[^ ]*\).*|\1|p')"
if [ -n "$VRC" ] && [ "$VRC" != "0" ]; then
    pass "the verdict reports the real exit status (${VRC})"
else
    fail "the verdict reports exit '${VRC:-none}' for a program that crashed"
fi
if [ -n "$VLOG" ] && [ -s "$VLOG" ]; then
    pass "the verdict names a log that exists (${VLOG})"
else
    fail "the verdict names no readable log: '${VMSG}'"
fi
if [ -n "$VLOG" ] && grep -q 'fraud_review' "$VLOG" 2>/dev/null; then
    pass "that log holds the traceback from the branch that crashed"
else
    fail "the named log does not contain the failure the learner has to fix"
fi
check_ownership "row ${ROWS}"

echo
echo "================================================================"
echo "rows: ${ROWS}   failures: ${BAD}"
[ "$HAVE_USER" -eq 0 ] && echo "NOTE: ownership rows were vacuous - no user account on this host"
echo "================================================================"
[ "$BAD" -eq 0 ]
