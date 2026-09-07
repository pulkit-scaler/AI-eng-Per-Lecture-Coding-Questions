#!/bin/bash
# Ordering matrix. The happy path passing tells you almost nothing: the failures
# that reach learners come from orderings nobody tried - submitting before
# running anything, a grading run killed half way, a second submission.
#
# Every row asserts the score AND that the learner is not locked out of their
# own project afterwards. The thing to watch here is reports/eval.json:
# a check runs the gate, and the gate WRITES that file. If a check creates it
# first, it is root-owned and every later run of the learner own gate fails.
#
# Run as root on the target VM once before the first cohort. On an authoring
# host with no `user` account the ownership rows self-report as vacuous.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$(cd "$DIR/.." && pwd)"
SCRIPTS="$PACK/test-cases/scripts"
LAB_DIR="${LAB_DIR:-/tmp/pelham-perm}"
DESK_URL="${DESK_URL:-http://127.0.0.1:8859}"
PY="${PY:-python3}"
export LAB_DIR DESK_URL PY
export PELHAM_DESK_URL="$DESK_URL"
SVC_URL="${SVC_URL:-http://127.0.0.1:8861}"
export SVC_URL
export SVC_LOG="/tmp/pelham_perm_service.log"
export DEPS_READY_FILE="${DEPS_READY_FILE:-/tmp/pelham-deps.ready}"
export TIMING_LOG="/tmp/pelham_perm_timing.log"
export DESK_BIN="$PACK/service/expensesvc.py"
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
    PELHAM_PORT="$port" "$PY" "$DESK_BIN" >/tmp/pelham_perm_desk.log 2>&1 &
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
    mkdir -p "$LAB_DIR/bdi"
    cp -R "$PACK/app/pelham_kit" "$LAB_DIR/"
    cp "$PACK/app/check_local.py" "$LAB_DIR/"
    cp "$PACK/app/bdi/__init__.py" "$LAB_DIR/bdi/"
    if [ "$1" = "1" ]; then
        cp "$PACK/reference-solution/bdi"/*.py "$LAB_DIR/bdi/"
        cp "$PACK/reference-solution/server.py" "$LAB_DIR/"
    else
        cp "$PACK/app/bdi/nodes_stub.py" "$LAB_DIR/bdi/nodes.py"
        cp "$PACK/app/bdi/graph_stub.py" "$LAB_DIR/bdi/graph.py"
        cp "$PACK/app/server_stub.py" "$LAB_DIR/server.py"
    fi
    # This lab keeps its state in the running service, so there is no on-disk
    # state to pre-create. What has to survive grading is the port.
    [ "$HAVE_USER" -eq 1 ] && chown -R user:user "$LAB_DIR" 2>/dev/null
    return 0
}

grade() {  # grade [n-scripts] -> echoes score
    local limit="${1:-5}" n=0 good=0 bad=0 line
    for s in "$SCRIPTS"/script_*.sh; do
        n=$((n + 1))
        [ "$n" -gt "$limit" ] && break
        # The judge grades the LAST line of stdout+stderr. A matrix that greps
        # for a verdict anywhere in the output scores every row green even when
        # a trailing line has voided every one of them on the portal - and a row
        # that only counts successes cannot see it at all, because a voided
        # verdict and an honest failure both score zero. So the shape of the
        # last line is asserted separately from the score.
        line="$(bash "$s" 2>&1 | tail -n 1)"
        case "$line" in
            *'"status"'*'"success"'*) good=$((good + 1)) ;;
            *'"status"'*'"failed"'*)  ;;
            *) bad=$((bad + 1))
               printf '  FAIL %s ended on a non-verdict, so the portal would post\n' "$(basename "$s")" >&2
               printf '       no results at all: %s\n' "$line" >&2 ;;
        esac
    done
    echo "$bad" > /tmp/pelham_perm_unparseable
    echo $((good * 10))
}

check_verdicts() {
    local bad; bad="$(cat /tmp/pelham_perm_unparseable 2>/dev/null || echo 0)"
    [ "${bad:-0}" -eq 0 ] \
        && pass "$1: every check ended on a parseable verdict" \
        || fail "$1: ${bad} check(s) ended on a non-verdict - empty panel on the portal"
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

# The thing grading can take away here is the port. A check that started the
# service must have stopped it again, or the learner cannot start their own.
check_learner_can_work() {
    local port rc
    port="$(printf '%s' "$SVC_URL" | sed 's|.*:||; s|/.*||')"
    if curl -sf -m 2 "${SVC_URL}/health" >/dev/null 2>&1; then
        fail "$1: something is still listening on ${port} after grading; the learner cannot start their own service"
        return
    fi
    ( cd "$LAB_DIR" && exec env PYTHONPATH="$LAB_DIR" \
        PELHAM_SERVICE_PORT="$port" PELHAM_DESK_URL="$DESK_URL" \
        PYTHONDONTWRITEBYTECODE=1 "$PY" server.py \
        >/tmp/pelham_perm_learner.log 2>&1 ) &
    echo $! >/tmp/pelham_perm_learner.pid
    local i
    rc=1
    for i in $(seq 1 30); do
        if curl -sf -m 2 "${SVC_URL}/health" >/dev/null 2>&1; then rc=0; break; fi
        sleep 1
    done
    kill "$(cat /tmp/pelham_perm_learner.pid 2>/dev/null)" >/dev/null 2>&1
    sleep 1
    if [ "$rc" -eq 0 ]; then
        pass "$1: the learner can still start their own service on ${port}"
    else
        fail "$1: the learner service would not start after grading"
    fi
}

row() { ROWS=$((ROWS + 1)); echo; echo "--- row ${ROWS}: $* ---"; }

start_desk || { echo "the finance desk would not start"; exit 1; }

row "starters untouched"
assemble 0
S="$(grade)"
[ "$S" = "0" ] && pass "score ${S}/50 as expected" || fail "score ${S}/50, expected 0/50"
check_verdicts "row ${ROWS}"
check_ownership "row ${ROWS}"

row "written, never run by the learner"
assemble 1
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 - the checks run the gate themselves" \
                || fail "score ${S}/50, expected 50/50"
check_verdicts "row ${ROWS}"
check_ownership "row ${ROWS}"
check_learner_can_work "row ${ROWS}"

row "learner left their own service running, then graded"
assemble 1
PORT_LEARNER="$(printf '%s' "$SVC_URL" | sed 's|.*:||; s|/.*||')"
( cd "$LAB_DIR" && exec env PYTHONPATH="$LAB_DIR" \
    PELHAM_SERVICE_PORT="$PORT_LEARNER" PELHAM_DESK_URL="$DESK_URL" \
    PYTHONDONTWRITEBYTECODE=1 "$PY" server.py \
    >/tmp/pelham_perm_own.log 2>&1 ) &
echo $! >/tmp/pelham_perm_own.pid
for i in $(seq 1 30); do
    curl -sf -m 2 "${SVC_URL}/health" >/dev/null 2>&1 && break
    sleep 1
done
[ "$HAVE_USER" -eq 1 ] && chown -R user:user "$LAB_DIR" 2>/dev/null
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 as expected" || fail "score ${S}/50, expected 50/50"
check_verdicts "row ${ROWS}"
check_ownership "row ${ROWS}"
if curl -sf -m 2 "${SVC_URL}/health" >/dev/null 2>&1; then
    pass "row ${ROWS}: the service the learner started is still running"
else
    fail "row ${ROWS}: grading stopped a service it did not start"
fi
kill "$(cat /tmp/pelham_perm_own.pid 2>/dev/null)" >/dev/null 2>&1
sleep 1

row "grading killed after three checks (partial run)"
S="$(grade 3)"
[ "$S" = "30" ] && pass "partial score ${S}/50 as expected" || fail "partial score ${S}/50, expected 30/50"
check_verdicts "row ${ROWS}"
check_ownership "row ${ROWS}"
check_learner_can_work "row ${ROWS}"

row "graded a second time on the same VM"
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 on the repeat" || fail "score ${S}/50 on the repeat, expected 50/50"
check_verdicts "row ${ROWS}"
check_ownership "row ${ROWS}"

row "graded a third time - thread ids must not collide with the earlier runs"
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 on the third pass" \
                || fail "score ${S}/50 on the third pass, expected 50/50"
check_verdicts "row ${ROWS}"
check_ownership "row ${ROWS}"
check_learner_can_work "row ${ROWS}"

echo
echo "================================================================"
echo "rows: ${ROWS}   failures: ${BAD}"
[ "$HAVE_USER" -eq 0 ] && echo "NOTE: ownership rows were vacuous - no user account on this host"
echo "================================================================"
[ "$BAD" -eq 0 ]
