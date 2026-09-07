#!/bin/bash
# LOCAL validation harness. NEVER shipped in TestCase.zip.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$(cd "$DIR/../.." && pwd)"

LAB_DIR="${LAB_DIR:-/tmp/norbury-lab-ref}"
SOLUTION="${SOLUTION:-$PACK/reference-solution}"
DESK_URL="${DESK_URL:-http://127.0.0.1:8788}"
DESK_BIN="${DESK_BIN:-$PACK/service/flowsvc.py}"
PY="${PY:-python3}"
POINTS_PER_TEST="${POINTS_PER_TEST:-10}"

DESK_PORT="$(printf '%s' "$DESK_URL" | sed 's|.*:||; s|/.*||')"
export LAB_DIR DESK_URL PY DESK_BIN
export NORBURY_PORT="$DESK_PORT"
export NORBURY_BASE_URL="$DESK_URL"
export DEPS_READY_FILE="${DEPS_READY_FILE:-/tmp/norbury-deps.ready}"
export TIMING_LOG="${TIMING_LOG:-/tmp/norbury_timing.log}"
touch "$DEPS_READY_FILE"
: > "$TIMING_LOG"

echo "=== assembling $LAB_DIR ==="
rm -rf "$LAB_DIR"
mkdir -p "$LAB_DIR/flow" "$LAB_DIR/runs"
cp -R "$PACK/app/flow_kit" "$PACK/app/flows" "$LAB_DIR/"
cp "$PACK/app/flow/__init__.py" "$LAB_DIR/flow/"
cp "$PACK/app/check_local.py" "$LAB_DIR/" 2>/dev/null
for name in spec runtime; do
    if [ -f "$SOLUTION/flow/${name}.py" ]; then
        cp "$SOLUTION/flow/${name}.py" "$LAB_DIR/flow/"
        echo "  flow/${name}.py <- $(basename "$SOLUTION")"
    else
        cp "$PACK/reference-solution/flow/${name}.py" "$LAB_DIR/flow/"
        echo "  flow/${name}.py <- reference"
    fi
done
if [ -f "$SOLUTION/flowctl.py" ]; then
    cp "$SOLUTION/flowctl.py" "$LAB_DIR/"; echo "  flowctl.py <- $(basename "$SOLUTION")"
else
    cp "$PACK/reference-solution/flowctl.py" "$LAB_DIR/"; echo "  flowctl.py <- reference"
fi
find "$LAB_DIR" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
echo "candidate under test: $SOLUTION"

DESK_PID=""
cleanup() { [ -n "$DESK_PID" ] && kill "$DESK_PID" 2>/dev/null; return 0; }
trap cleanup EXIT

echo "=== starting the model endpoint ==="
if curl -sf -m 3 "${DESK_URL}/health" >/dev/null 2>&1; then
    if [ "${REUSE_DESK:-0}" != "1" ]; then
        echo "ERROR: something is already answering on ${DESK_URL} - pick another port or set REUSE_DESK=1"
        exit 1
    fi
    echo "already running (reusing on request)"
else
    NORBURY_PORT="$DESK_PORT" "$PY" "$DESK_BIN" \
        >"/tmp/norbury_desk_runall_${DESK_PORT}.log" 2>&1 &
    DESK_PID=$!
    disown "$DESK_PID" 2>/dev/null || true
    for i in $(seq 1 30); do
        curl -sf -m 2 "${DESK_URL}/health" >/dev/null 2>&1 && break
        sleep 1
    done
    curl -sf -m 2 "${DESK_URL}/health" >/dev/null 2>&1 || {
        echo "ERROR: the model endpoint never became healthy"
        cat "/tmp/norbury_desk_runall_${DESK_PORT}.log"
        exit 1
    }
fi
echo "model endpoint healthy"

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
