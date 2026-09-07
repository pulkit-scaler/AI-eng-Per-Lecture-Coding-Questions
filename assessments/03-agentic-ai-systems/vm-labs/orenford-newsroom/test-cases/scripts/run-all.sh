#!/bin/bash
# LOCAL validation harness. NEVER shipped in TestCase.zip.
#
#   ./run-all.sh
#   SOLUTION=reference-solution/alt1_supervisor.py ./run-all.sh
#   LAB_DIR=/tmp/o-alt WIRE_URL=http://127.0.0.1:8901 \
#       SERVE_URL=http://127.0.0.1:8401 SERVE_PORT=8401 SOLUTION=... ./run-all.sh
#
# PY must point at an interpreter that has langgraph and langchain-core.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$(cd "$DIR/../.." && pwd)"

LAB_DIR="${LAB_DIR:-/tmp/orenford-lab-ref}"
SOLUTION="${SOLUTION:-$PACK/reference-solution/serve.py}"
WIRE_URL="${WIRE_URL:-http://127.0.0.1:8317}"
WIRE_BIN="${WIRE_BIN:-$PACK/service/wired.py}"
SERVE_PORT="${SERVE_PORT:-8300}"
SERVE_URL="${SERVE_URL:-http://127.0.0.1:${SERVE_PORT}}"
PY="${PY:-python3}"
POINTS_PER_TEST="${POINTS_PER_TEST:-10}"

WIRE_PORT="$(printf '%s' "$WIRE_URL" | sed 's|.*:||; s|/.*||')"
export LAB_DIR WIRE_URL WIRE_BIN SERVE_URL SERVE_PORT PY
export ORENFORD_WIRE_URL="$WIRE_URL"
export ORENFORD_SERVE_PORT="$SERVE_PORT"
export DEPS_READY_FILE="${DEPS_READY_FILE:-/tmp/orenford-deps.ready}"
export TIMING_LOG="${TIMING_LOG:-/tmp/orenford_timing.log}"
export SERVE_LOG="${SERVE_LOG:-/tmp/orenford_serve_${SERVE_PORT}.log}"
touch "$DEPS_READY_FILE"
: > "$TIMING_LOG"

echo "=== assembling $LAB_DIR ==="
rm -rf "$LAB_DIR"
mkdir -p "$LAB_DIR/data"
cp -R "$PACK/app/news_kit" "$LAB_DIR/"
cp "$PACK/app/check_local.py" "$LAB_DIR/"
cp "$PACK/app/data/assignments.json" "$LAB_DIR/data/"
cp "$SOLUTION" "$LAB_DIR/serve.py"
CAND_DIR="$(dirname "$SOLUTION")"
for extra in "$CAND_DIR"/_lib_*.py; do
    [ -f "$extra" ] && cp "$extra" "$LAB_DIR/"
done
find "$LAB_DIR" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
if ! cmp -s "$SOLUTION" "$LAB_DIR/serve.py"; then
    echo "ERROR: WRONG-FILE-GRADED - $LAB_DIR/serve.py is not $SOLUTION"
    exit 1
fi
echo "candidate under test: $SOLUTION"

WIRE_PID=""; SERVE_PID=""
cleanup() {
    # Each check restarts the service, so the pid this harness started is not
    # the one still listening at the end.
    pkill -f "serve\.py" 2>/dev/null
    [ -n "$SERVE_PID" ] && kill "$SERVE_PID" 2>/dev/null
    [ -n "$WIRE_PID" ] && kill "$WIRE_PID" 2>/dev/null
    local i
    for i in $(seq 1 20); do
        curl -sf -m 1 "${WIRE_URL}/health" >/dev/null 2>&1 || return 0
        sleep 0.5
    done
    return 0
}
trap cleanup EXIT

echo "=== starting the newsroom wire ==="
if curl -sf -m 3 "${WIRE_URL}/health" >/dev/null 2>&1; then
    if [ "${REUSE_WIRE:-0}" != "1" ]; then
        echo "ERROR: something is already answering on ${WIRE_URL} - pick another port or set REUSE_WIRE=1"
        exit 1
    fi
    echo "reusing the wire already on that port"
else
    ORENFORD_PORT="$WIRE_PORT" \
        ORENFORD_ASSIGNMENTS="$PACK/app/data/assignments.json" \
        "$PY" "$WIRE_BIN" >"/tmp/orenford_wire_${WIRE_PORT}.log" 2>&1 &
    WIRE_PID=$!
    disown "$WIRE_PID" 2>/dev/null || true
    for i in $(seq 1 25); do
        curl -sf -m 2 "${WIRE_URL}/health" >/dev/null 2>&1 && break
        sleep 1
    done
    curl -sf -m 2 "${WIRE_URL}/health" >/dev/null 2>&1 || {
        echo "ERROR: the wire never became healthy"
        cat "/tmp/orenford_wire_${WIRE_PORT}.log"
        exit 1
    }
fi
echo "wire healthy"

echo "=== starting the candidate service (playing the learner) ==="
if curl -sf -m 2 "${SERVE_URL}/health" >/dev/null 2>&1; then
    echo "ERROR: something is already answering on ${SERVE_URL} - pick another port"
    exit 1
fi
( cd "$LAB_DIR" && export PYTHONPATH="$LAB_DIR" \
    ORENFORD_SERVE_PORT="$SERVE_PORT" ORENFORD_WIRE_URL="$WIRE_URL" \
    ORENFORD_ASSIGNMENTS_FILE="${LAB_DIR}/data/assignments.json" \
  && "$PY" serve.py >"$SERVE_LOG" 2>&1 & echo $! > /tmp/orenford_serve.pid )
SERVE_PID="$(cat /tmp/orenford_serve.pid 2>/dev/null || true)"
for i in $(seq 1 25); do
    curl -sf -m 2 "${SERVE_URL}/health" >/dev/null 2>&1 && break
    sleep 1
done
if curl -sf -m 2 "${SERVE_URL}/health" >/dev/null 2>&1; then
    echo "candidate service healthy on ${SERVE_URL}"
else
    echo "the candidate service did not start (the checks will report why):"
    tail -8 "$SERVE_LOG" 2>/dev/null | sed 's/^/    serve| /'
fi

PASS=0; FAIL=0; FAILED_LIST=""; WORST=0
for s in "$DIR"/script_*.sh; do
    name="$(basename "$s")"
    t0=$SECONDS
    out="$(bash "$s" 2>&1)"
    took=$((SECONDS - t0))
    [ "$took" -gt "$WORST" ] && WORST=$took
    # Grade exactly what the platform grades: the LAST line of stdout+stderr.
    # Matching the first RESULT: line anywhere hid a real bug - a check that
    # printed its verdict and then emitted one more line scored full marks here
    # and reported no test cases at all on the portal.
    line="$(printf '%s\n' "$out" | tail -n 1)"
    vstatus="$(printf '%s' "$line" | jq -r '.status // "UNPARSEABLE"' 2>/dev/null || echo UNPARSEABLE)"
    msg="$(printf '%s' "$line" | jq -r '.message // empty' 2>/dev/null)"
    [ -n "$msg" ] || msg="LAST LINE IS NOT A VERDICT - the portal would report this
         submission as having no test cases at all. Last line was: $line"
    if [ "$vstatus" = "success" ]; then
        PASS=$((PASS + 1))
        printf '  [PASS] %-16s %3ds  %s\n' "$name" "$took" "$msg"
    else
        FAIL=$((FAIL + 1))
        FAILED_LIST="$FAILED_LIST $name"
        printf '  [FAIL] %-16s %3ds  %s\n' "$name" "$took" "$msg"
        printf '%s\n' "$out" | sed '$d' | sed 's/^/         /' | head -6
    fi
done

TOTAL=$(( (PASS + FAIL) * POINTS_PER_TEST ))
SCORE=$(( PASS * POINTS_PER_TEST ))
echo "----------------------------------------------------------------"
echo "CANDIDATE: $(basename "$SOLUTION")"
echo "SCORE: ${SCORE}/${TOTAL}   (passed ${PASS}, failed ${FAIL})"
echo "slowest test case: ${WORST}s   (portal limit is about 120s)"
[ -n "$FAILED_LIST" ] && echo "failed:${FAILED_LIST}"
echo "----------------------------------------------------------------"
[ "$FAIL" -eq 0 ] || exit 1
