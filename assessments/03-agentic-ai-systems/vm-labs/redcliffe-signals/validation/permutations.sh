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
LAB_DIR="${LAB_DIR:-/tmp/redcliffe-perm}"
DESK_URL="${DESK_URL:-http://127.0.0.1:8679}"
PY="${PY:-python3}"
export LAB_DIR DESK_URL PY
export REDCLIFFE_DESK_URL="$DESK_URL"
export DEPS_READY_FILE="${DEPS_READY_FILE:-/tmp/redcliffe-deps.ready}"
export TIMING_LOG="/tmp/redcliffe_perm_timing.log"
export DESK_BIN="$PACK/service/signalsvc.py"
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
    REDCLIFFE_PORT="$port"  \
        "$PY" "$DESK_BIN" >/tmp/redcliffe_perm_desk.log 2>&1 &
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

assemble() {  # assemble <written:0|1>
    rm -rf "$LAB_DIR"
    mkdir -p "$LAB_DIR/store" "$LAB_DIR/signals"
    cp -R "$PACK/app/signal_kit" "$LAB_DIR/"
    cp "$PACK/app/signalctl.py" "$PACK/app/check_local.py" "$LAB_DIR/"
    cp "$PACK/app/signals/__init__.py" "$LAB_DIR/signals/"
    if [ "$1" = "1" ]; then
        cp "$PACK/reference-solution/signals"/*.py "$LAB_DIR/signals/"
    else
        cp "$PACK/app/signals/react_loop_stub.py" "$LAB_DIR/signals/react_loop.py"
        cp "$PACK/app/signals/reflect_stub.py" "$LAB_DIR/signals/reflect.py"
        cp "$PACK/app/signals/memory_stub.py" "$LAB_DIR/signals/memory.py"
    fi
    # Provisioning pre-creates the store as the learner. Reproduce that here,
    # because it is the defence being tested.
    : > "$LAB_DIR/store/signals.jsonl"
    [ "$HAVE_USER" -eq 1 ] && chown -R user:user "$LAB_DIR" 2>/dev/null
    return 0
}

grade() {  # grade [n-scripts] -> echoes score
    local limit="${1:-5}" n=0 good=0 out line status
    for s in "$SCRIPTS"/script_*.sh; do
        n=$((n + 1))
        [ "$n" -gt "$limit" ] && break
        # Grade exactly what the portal grades: the LAST line of stdout+stderr,
        # read as the JSON the faithful common.sh replica prints. Grepping for
        # the `RESULT:` fallback shape instead scored every row 0/50 the moment
        # that replica was added, which is the failure mode the replica exists
        # to prevent - a local harness easier to pass than the real one.
        out="$(bash "$s" 2>&1)"
        line="$(printf '%s\n' "$out" | tail -n 1)"
        status="$(printf '%s' "$line" | jq -r '.status // empty' 2>/dev/null)"
        [ -n "$status" ] || status="$(printf '%s' "$line" \
            | sed -n 's/^RESULT:\([a-z]*\).*/\1/p')"
        if [ "$status" = "success" ]; then good=$((good + 1)); fi
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
        su - user -c "cd $LAB_DIR && REDCLIFFE_DESK_URL=$DESK_URL $PY signalctl.py note --session learner-after --say 'shift handed over' >/dev/null"
        rc=$?
    else
        ( cd "$LAB_DIR" && REDCLIFFE_DESK_URL="$DESK_URL" "$PY" signalctl.py \
            note --session learner-after --say "shift handed over" >/dev/null )
        rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        pass "$1: the learner can still append to their own store afterwards"
    else
        fail "$1: the learner cannot write to their own store afterwards (exit $rc)"
    fi
}

row() { ROWS=$((ROWS + 1)); echo; echo "--- row ${ROWS}: $* ---"; }

start_desk || { echo "the control desk would not start"; exit 1; }

row "starters untouched"
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
( cd "$LAB_DIR" && REDCLIFFE_DESK_URL="$DESK_URL" "$PY" signalctl.py note \
    --session learner-first --say "possession booked for SEC-7" >/dev/null 2>&1 )
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
LINES="$(wc -l < "$LAB_DIR/store/signals.jsonl" 2>/dev/null | tr -d ' ')"
note "the store now holds ${LINES} notes"
check_ownership "row ${ROWS}"
check_learner_can_work "row ${ROWS}"

row "store deleted between runs"
rm -f "$LAB_DIR/store/signals.jsonl"
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 with the store recreated from scratch" \
                || fail "score ${S}/50, expected 50/50"
check_ownership "row ${ROWS}"

echo
echo "================================================================"
echo "rows: ${ROWS}   failures: ${BAD}"
[ "$HAVE_USER" -eq 0 ] && echo "NOTE: ownership rows were vacuous - no user account on this host"
echo "================================================================"
[ "$BAD" -eq 0 ]
