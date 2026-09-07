#!/bin/bash
# Ordering matrix. The happy path passing tells you almost nothing: the failures
# that reach learners come from orderings nobody tried - submitting with the
# service down, a grading run killed half way, a second submission, a service
# that dies between checks.
#
# Run as root on the target VM once before the first cohort. On an authoring host
# with no `user` account the ownership rows self-report as vacuous.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$(cd "$DIR/.." && pwd)"
SCRIPTS="$PACK/test-cases/scripts"
LAB_DIR="${LAB_DIR:-/tmp/orenford-perm}"
WIRE_URL="${WIRE_URL:-http://127.0.0.1:8319}"
SERVE_PORT="${SERVE_PORT:-8309}"
SERVE_URL="${SERVE_URL:-http://127.0.0.1:${SERVE_PORT}}"
PY="${PY:-python3}"
export LAB_DIR WIRE_URL SERVE_URL SERVE_PORT PY
export WIRE_BIN="$PACK/service/wired.py"
export ORENFORD_WIRE_URL="$WIRE_URL"
export DEPS_READY_FILE="${DEPS_READY_FILE:-/tmp/orenford-deps.ready}"
export TIMING_LOG="/tmp/orenford_perm_timing.log"
export SERVE_LOG="/tmp/orenford_perm_serve.log"
touch "$DEPS_READY_FILE"

HAVE_USER=0
id -u user >/dev/null 2>&1 && HAVE_USER=1
ROWS=0; BAD=0
note() { printf '  %s\n' "$*"; }
fail() { BAD=$((BAD + 1)); printf '  FAIL %s\n' "$*"; }
pass() { printf '  ok   %s\n' "$*"; }

WIRE_PID=""
start_wire() {
    curl -sf -m 2 "${WIRE_URL}/health" >/dev/null 2>&1 && return 0
    local port; port="$(printf '%s' "$WIRE_URL" | sed 's|.*:||; s|/.*||')"
    ORENFORD_PORT="$port" \
        ORENFORD_ASSIGNMENTS="$PACK/app/data/assignments.json" \
        "$PY" "$WIRE_BIN" >/tmp/orenford_perm_wire.log 2>&1 &
    WIRE_PID=$!
    disown "$WIRE_PID" 2>/dev/null || true
    local i
    for i in $(seq 1 20); do
        curl -sf -m 2 "${WIRE_URL}/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

# A service started with `cd LAB_DIR && python serve.py` has no path in its
# command line, so a pattern built from LAB_DIR never matches it. Inside an
# authoring harness, matching serve.py outright is the reliable thing.
kill_service() {
    pkill -f "$PY .*serve\.py" >/dev/null 2>&1
    pkill -f "python.*serve\.py" >/dev/null 2>&1
    local i
    for i in $(seq 1 10); do
        curl -sf -m 1 "${SERVE_URL}/health" >/dev/null 2>&1 || return 0
        sleep 1
    done
    note "warning: something is still answering on ${SERVE_URL}"
    return 0
}

cleanup() {
    kill_service
    [ -n "$WIRE_PID" ] && kill "$WIRE_PID" 2>/dev/null
    return 0
}
trap cleanup EXIT

assemble() {  # assemble <written:0|1>
    kill_service
    rm -rf "$LAB_DIR"
    mkdir -p "$LAB_DIR/data"
    cp -R "$PACK/app/news_kit" "$LAB_DIR/"
    cp "$PACK/app/check_local.py" "$LAB_DIR/"
    cp "$PACK/app/data/assignments.json" "$LAB_DIR/data/"
    if [ "$1" = "1" ]; then
        cp "$PACK/reference-solution/serve.py" "$LAB_DIR/serve.py"
    else
        cp "$PACK/app/serve_stub.py" "$LAB_DIR/serve.py"
    fi
    [ "$HAVE_USER" -eq 1 ] && chown -R user:user "$LAB_DIR" 2>/dev/null
    return 0
}

start_service_as_learner() {
    ( cd "$LAB_DIR" && export PYTHONPATH="$LAB_DIR" \
        ORENFORD_SERVE_PORT="$SERVE_PORT" ORENFORD_WIRE_URL="$WIRE_URL" \
        ORENFORD_ASSIGNMENTS_FILE="${LAB_DIR}/data/assignments.json" \
      && { if command -v setsid >/dev/null 2>&1; then
               setsid nohup "$PY" serve.py >/tmp/orenford_learner.log 2>&1 </dev/null &
           else
               nohup "$PY" serve.py >/tmp/orenford_learner.log 2>&1 </dev/null &
           fi; } )
    local i
    for i in $(seq 1 20); do
        curl -sf -m 2 "${SERVE_URL}/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

grade() {  # grade [n-scripts] -> echoes score
    local limit="${1:-5}" n=0 good=0 verdict
    for s in "$SCRIPTS"/script_*.sh; do
        n=$((n + 1))
        [ "$n" -gt "$limit" ] && break
        # The judge grades the LAST line. With the replica common.sh present
        # that line is JSON; without it, the scripts fall back to RESULT:<status>.
        # Reading only the fallback scored every correct submission zero here,
        # which is how this matrix came to report rows it had not really run.
        verdict="$(bash "$s" 2>&1 | tail -1)"
        case "$verdict" in
            *'"status": "success"'*|*'"status":"success"'*|RESULT:success*)
                good=$((good + 1)) ;;
        esac
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
    # Grading takes the service down on its way out, so "not locked out" means
    # the learner can start their own again and drive it - which is exactly what
    # a root process still holding the port would prevent.
    if ! curl -sf -m 2 "${SERVE_URL}/health" >/dev/null 2>&1; then
        if ! start_service_as_learner; then
            fail "$1: the learner cannot start their own service afterwards"
            return
        fi
    fi
    if [ "$HAVE_USER" -eq 1 ]; then
        su - user -c "cd $LAB_DIR && ORENFORD_SERVE_URL=$SERVE_URL $PY check_local.py >/dev/null"
        rc=$?
    else
        ( cd "$LAB_DIR" && ORENFORD_SERVE_URL="$SERVE_URL" "$PY" check_local.py >/dev/null )
        rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        pass "$1: the learner can still drive their own service afterwards"
    else
        fail "$1: the learner cannot drive their own service afterwards (exit $rc)"
    fi
}

row() { ROWS=$((ROWS + 1)); echo; echo "--- row ${ROWS}: $* --- (t+${SECONDS}s)"; }

start_wire || { echo "the newsroom wire would not start"; exit 1; }

row "starter untouched"
assemble 0
S="$(grade)"
[ "$S" = "0" ] && pass "score ${S}/50 as expected" || fail "score ${S}/50, expected 0/50"
check_ownership "row ${ROWS}"

row "written, service not running"
assemble 1
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 - the checks started the service themselves" \
                || fail "score ${S}/50, expected 50/50"
check_ownership "row ${ROWS}"
check_learner_can_work "row ${ROWS}"

row "learner started it, then graded"
assemble 1
start_service_as_learner || fail "the reference service would not start"
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

row "service killed between grading runs"
kill_service
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 after the checks restarted it" \
                || fail "score ${S}/50, expected 50/50"
check_ownership "row ${ROWS}"
check_learner_can_work "row ${ROWS}"

echo
echo "================================================================"
echo "rows: ${ROWS}   failures: ${BAD}"
[ "$HAVE_USER" -eq 0 ] && echo "NOTE: ownership rows were vacuous - no user account on this host"
echo "================================================================"
[ "$BAD" -eq 0 ]
