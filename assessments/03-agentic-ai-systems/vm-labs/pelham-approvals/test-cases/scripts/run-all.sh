#!/bin/bash
# LOCAL validation harness. NEVER shipped in TestCase.zip.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$(cd "$DIR/../.." && pwd)"

LAB_DIR="${LAB_DIR:-/tmp/pelham-lab-ref}"
SOLUTION="${SOLUTION:-$PACK/reference-solution}"
DESK_URL="${DESK_URL:-http://127.0.0.1:8766}"
SVC_URL="${SVC_URL:-http://127.0.0.1:8767}"
DESK_BIN="${DESK_BIN:-$PACK/service/expensesvc.py}"
PY="${PY:-python3}"
POINTS_PER_TEST="${POINTS_PER_TEST:-10}"

DESK_PORT="$(printf '%s' "$DESK_URL" | sed 's|.*:||; s|/.*||')"
SVC_PORT="$(printf '%s' "$SVC_URL" | sed 's|.*:||; s|/.*||')"
export LAB_DIR DESK_URL SVC_URL PY DESK_BIN
export PELHAM_PORT="$DESK_PORT"
export PELHAM_DESK_URL="$DESK_URL"
export PELHAM_SERVICE_PORT="$SVC_PORT"
export DEPS_READY_FILE="${DEPS_READY_FILE:-/tmp/pelham-deps.ready}"
export TIMING_LOG="${TIMING_LOG:-/tmp/pelham_timing.log}"
export SVC_LOG="${SVC_LOG:-/tmp/pelham_service_runall_${SVC_PORT}.log}"
touch "$DEPS_READY_FILE"
: > "$TIMING_LOG"

echo "=== assembling $LAB_DIR ==="
rm -rf "$LAB_DIR"
mkdir -p "$LAB_DIR/bdi"
cp -R "$PACK/app/pelham_kit" "$LAB_DIR/"
cp "$PACK/app/bdi/__init__.py" "$LAB_DIR/bdi/"
cp "$PACK/app/check_local.py" "$LAB_DIR/" 2>/dev/null
for name in nodes graph; do
    if [ -f "$SOLUTION/bdi/${name}.py" ]; then
        cp "$SOLUTION/bdi/${name}.py" "$LAB_DIR/bdi/"
        echo "  bdi/${name}.py <- $(basename "$SOLUTION")"
    else
        cp "$PACK/reference-solution/bdi/${name}.py" "$LAB_DIR/bdi/"
        echo "  bdi/${name}.py <- reference"
    fi
done
if [ -f "$SOLUTION/server.py" ]; then
    cp "$SOLUTION/server.py" "$LAB_DIR/"; echo "  server.py <- $(basename "$SOLUTION")"
else
    cp "$PACK/reference-solution/server.py" "$LAB_DIR/"; echo "  server.py <- reference"
fi
find "$LAB_DIR" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
echo "candidate under test: $SOLUTION"

DESK_PID=""; SVC_PID=""
cleanup() {
    [ -n "$SVC_PID" ] && kill "$SVC_PID" 2>/dev/null
    [ -n "$DESK_PID" ] && kill "$DESK_PID" 2>/dev/null
    return 0
}
trap cleanup EXIT

for pair in "desk:${DESK_URL}" "service:${SVC_URL}"; do
    name="${pair%%:*}"; url="${pair#*:}"
    if curl -sf -m 2 "${url}/health" >/dev/null 2>&1 && [ "${REUSE:-0}" != "1" ]; then
        echo "ERROR: something is already answering on ${url} (${name}) - pick another port or set REUSE=1"
        exit 1
    fi
done

echo "=== starting the finance desk ==="
PELHAM_PORT="$DESK_PORT" "$PY" "$DESK_BIN" \
    >"/tmp/pelham_desk_runall_${DESK_PORT}.log" 2>&1 &
DESK_PID=$!
disown "$DESK_PID" 2>/dev/null || true
for i in $(seq 1 20); do
    curl -sf -m 2 "${DESK_URL}/health" >/dev/null 2>&1 && break
    sleep 1
done
curl -sf -m 2 "${DESK_URL}/health" >/dev/null 2>&1 || {
    echo "ERROR: the finance desk never became healthy"; exit 1; }
echo "finance desk healthy"

echo "=== starting the approval service ==="
( cd "$LAB_DIR" && exec env PYTHONPATH="$LAB_DIR" \
    PELHAM_SERVICE_PORT="$SVC_PORT" PELHAM_DESK_URL="$DESK_URL" \
    PYTHONDONTWRITEBYTECODE=1 "$PY" server.py >"$SVC_LOG" 2>&1 ) &
SVC_PID=$!
for i in $(seq 1 40); do
    curl -sf -m 2 "${SVC_URL}/health" >/dev/null 2>&1 && break
    sleep 1
done
if ! curl -sf -m 2 "${SVC_URL}/health" >/dev/null 2>&1; then
    echo "the approval service did not come up from run-all; the checks will start it themselves"
    tail -5 "$SVC_LOG" 2>/dev/null | sed 's/^/    svc| /'
else
    echo "approval service healthy"
fi

PASS=0; FAIL=0; FAILED_LIST=""; WORST=0
for s in "$DIR"/script_*.sh; do
    name="$(basename "$s")"
    t0=$SECONDS
    out="$(bash "$s" 2>&1)"
    took=$((SECONDS - t0))
    [ "$took" -gt "$WORST" ] && WORST=$took
    # Grade exactly what the platform grades: the LAST line of stdout+stderr.
    # Taking the first matching line anywhere is what hid the ERR-trap bug - a
    # check that printed its verdict and then one more line scored full marks
    # here and reported no test cases at all on the portal.
    line="$(printf '%s\n' "$out" | tail -n 1)"
    msg="$(printf '%s' "$line" | jq -r '.message // empty' 2>/dev/null)"
    [ -n "$msg" ] || msg="$line"
    if printf '%s' "$line" | grep -q '"status": *"success"'; then
        PASS=$((PASS + 1))
        printf '  [PASS] %-16s %3ds  %s\n' "$name" "$took" "$msg"
    elif printf '%s' "$line" | grep -q '"status": *"failed"'; then
        FAIL=$((FAIL + 1))
        FAILED_LIST="$FAILED_LIST $name"
        printf '  [FAIL] %-16s %3ds  %s\n' "$name" "$took" "$msg"
        printf '%s\n' "$out" | sed '$d' | sed 's/^/         /' | head -6
    else
        FAIL=$((FAIL + 1))
        FAILED_LIST="$FAILED_LIST ${name}(UNPARSEABLE)"
        printf '  [!!!!] %-16s %3ds  last line is not a verdict - the portal would\n' "$name" "$took"
        printf '         report this submission as having no test cases at all:\n'
        printf '%s\n' "$out" | tail -4 | sed 's/^/         > /'
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
