#!/bin/bash
# LOCAL validation harness. NEVER shipped in TestCase.zip.
#
#   ./run-all.sh
#   CAND=reference-solution/alt1_single_file ./run-all.sh
#
# A candidate directory may hold any subset of config/agents.yaml,
# config/tasks.yaml, tools.py and crew.py; whatever it omits comes from the
# reference, so a defect probe is one file long.
#
# PY must point at an interpreter that has crewai.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$(cd "$DIR/../.." && pwd)"

CAND="${CAND:-reference-solution}"
CAND_DIR="$PACK/$CAND"
LAB_DIR="${LAB_DIR:-/tmp/thistledown-lab-ref}"
MODEL_PORT="${MODEL_PORT:-8433}"
MODEL_URL="${MODEL_URL:-http://127.0.0.1:${MODEL_PORT}}"
MODEL_BIN="${MODEL_BIN:-$PACK/service/millsvc.py}"
PY="${PY:-python3}"
POINTS_PER_TEST="${POINTS_PER_TEST:-10}"

export LAB_DIR MODEL_URL MODEL_BIN PY
export DEPS_READY_FILE="${DEPS_READY_FILE:-/tmp/thistledown-deps.ready}"
export TIMING_LOG="${TIMING_LOG:-/tmp/thistledown_timing.log}"
export CREWAI_TRACING_ENABLED=false CREWAI_DISABLE_TELEMETRY=true OTEL_SDK_DISABLED=true
touch "$DEPS_READY_FILE"
: > "$TIMING_LOG"

[ -d "$CAND_DIR" ] || { echo "no candidate directory $CAND_DIR"; exit 1; }

echo "=== assembling $LAB_DIR ==="
rm -rf "$LAB_DIR"
mkdir -p "$LAB_DIR/data" "$LAB_DIR/out" "$LAB_DIR/config"
cp -R "$PACK/app/mill" "$LAB_DIR/"
rm -f "$LAB_DIR/mill/tools_stub.py" "$LAB_DIR/mill/crew_stub.py"
cp "$PACK/app/check_local.py" "$LAB_DIR/"
cp "$PACK/app/data/orders.json" "$LAB_DIR/data/"
"$PY" "$PACK/app/build_db.py" "$LAB_DIR/data/mill.db" >/dev/null

pick() {  # pick <relative-name> <destination>
    if [ -f "$CAND_DIR/$1" ]; then cp "$CAND_DIR/$1" "$2"; echo "  $1 <- $CAND";
    else cp "$PACK/reference-solution/$1" "$2"; echo "  $1 <- reference"; fi
}
pick config/agents.yaml "$LAB_DIR/config/agents.yaml"
pick config/tasks.yaml  "$LAB_DIR/config/tasks.yaml"
pick tools.py           "$LAB_DIR/mill/tools.py"
pick crew.py            "$LAB_DIR/mill/crew.py"
find "$LAB_DIR" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null

# crewai asks once, per project directory, whether the user wants to see
# execution traces, and waits twenty seconds for an answer. Provisioning marks
# that question answered; the harness has to do the same or every run stalls.
for base in "$HOME/.local/share" "$HOME/Library/Application Support"; do
    [ -d "$base" ] || continue
    mkdir -p "$base/$(basename "$LAB_DIR")"
    printf '{"first_execution_done": true}' \
        > "$base/$(basename "$LAB_DIR")/.crewai_user.json"
done

MODEL_PID=""
cleanup() { [ -n "$MODEL_PID" ] && kill "$MODEL_PID" 2>/dev/null; return 0; }
trap cleanup EXIT

echo "=== starting the planning model ==="
if curl -sf -m 3 "${MODEL_URL}/health" >/dev/null 2>&1; then
    if [ "${REUSE_MODEL:-0}" != "1" ]; then
        echo "ERROR: something is already answering on ${MODEL_URL} - pick another port or set REUSE_MODEL=1"
        exit 1
    fi
    echo "reusing the model already on that port"
else
    THISTLEDOWN_PORT="$MODEL_PORT" "$PY" "$MODEL_BIN" \
        >"/tmp/thistledown_model_${MODEL_PORT}.log" 2>&1 &
    MODEL_PID=$!
    disown "$MODEL_PID" 2>/dev/null || true
    for i in $(seq 1 20); do
        curl -sf -m 2 "${MODEL_URL}/health" >/dev/null 2>&1 && break
        sleep 1
    done
    curl -sf -m 2 "${MODEL_URL}/health" >/dev/null 2>&1 || {
        echo "ERROR: the planning model never became healthy"
        cat "/tmp/thistledown_model_${MODEL_PORT}.log"
        exit 1
    }
fi
echo "planning model healthy"

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
echo "CANDIDATE: $CAND"
echo "SCORE: ${SCORE}/${TOTAL}   (passed ${PASS}, failed ${FAIL})"
echo "slowest test case: ${WORST}s   (portal limit is about 120s)"
[ -n "$FAILED_LIST" ] && echo "failed:${FAILED_LIST}"
echo "----------------------------------------------------------------"
[ "$FAIL" -eq 0 ] || exit 1
