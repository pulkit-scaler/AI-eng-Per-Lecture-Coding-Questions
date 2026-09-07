#!/bin/bash
# LOCAL validation harness. NEVER shipped in TestCase.zip.
#
# Assembles a scratch lab dir from app/ plus a candidate solution, starts the
# wire desk, runs script_01..05 in order and tallies the score.
#
#   ./run-all.sh                                        # grade the reference
#   SOLUTION=reference-solution/alt1_create_task.py ./run-all.sh
#   LAB_DIR=/tmp/lab-alt SVC_URL=http://127.0.0.1:8901 SOLUTION=... ./run-all.sh
#
# PY must point at an interpreter that has the openai package.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$(cd "$DIR/../.." && pwd)"

LAB_DIR="${LAB_DIR:-/tmp/caldon-lab-ref}"
SOLUTION="${SOLUTION:-$PACK/reference-solution/solution.py}"
SVC_URL="${SVC_URL:-http://127.0.0.1:8794}"
SVC_BIN="${SVC_BIN:-$PACK/service/wired.py}"
PY="${PY:-python3}"
POINTS_PER_TEST="${POINTS_PER_TEST:-10}"

# Keep the desk on whatever port SVC_URL names, so parallel runs stay isolated.
# CALDON_BASE_URL must move with it: that is what the provided client dials,
# and it defaults to 8794 (the port used on the real VM).
SVC_PORT="$(printf '%s' "$SVC_URL" | sed 's|.*:||; s|/.*||')"
export LAB_DIR SVC_URL SVC_BIN PY
export CALDON_PORT="$SVC_PORT"
export CALDON_BASE_URL="${SVC_URL}/v1"
export CALDON_FEED="${LAB_DIR}/data/wire_feed.json"
LOG_DIR="${LOG_DIR:-${LAB_DIR%/}-logs}"
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
export LOG_DIR

echo "=== assembling $LAB_DIR ==="
rm -rf "$LAB_DIR"
mkdir -p "$LAB_DIR/data"
cp -R "$PACK/app/wire_kit" "$LAB_DIR/"
cp "$PACK/app/check_local.py" "$LAB_DIR/"
cp "$PACK/app/data/wire_feed.json" "$LAB_DIR/data/"
cp "$SOLUTION" "$LAB_DIR/solution.py"
# The numpy probe carries the reference body in a sibling module.
[ -f "$PACK/reference-solution/solution_body.py" ] && \
    cp "$PACK/reference-solution/solution_body.py" "$LAB_DIR/" 2>/dev/null
find "$LAB_DIR" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
# Guard: omitting SOLUTION grades the reference while appearing to grade the
# candidate, which turns every sheet into a row of perfect scores.
if ! cmp -s "$SOLUTION" "$LAB_DIR/solution.py"; then
    echo "ERROR: WRONG-FILE-GRADED - $LAB_DIR/solution.py is not $SOLUTION"
    exit 1
fi
echo "solution under test: $SOLUTION"

SVC_PID=""
cleanup() {
    [ -n "$SVC_PID" ] || return 0
    kill "$SVC_PID" 2>/dev/null
    # Wait for the port to go quiet, so a run started right after this one
    # cannot health-check a dying desk and then lose it mid-test.
    local i
    for i in $(seq 1 20); do
        curl -sf -m 1 "${SVC_URL}/health" >/dev/null 2>&1 || return 0
        sleep 0.5
    done
    return 0
}
trap cleanup EXIT

echo "=== starting wire desk ==="
if curl -sf -m 3 "${SVC_URL}/health" >/dev/null 2>&1; then
    echo "already running (reusing)"
else
    CALDON_PORT="$SVC_PORT" CALDON_FEED="$PACK/app/data/wire_feed.json" \
        "$PY" "$SVC_BIN" >"/tmp/caldon_svc_runall_${SVC_PORT}.log" 2>&1 &
    SVC_PID=$!
    # Off the job table, so the shell does not print a Terminated notice over
    # the score when cleanup kills it.
    disown "$SVC_PID" 2>/dev/null || true
    for i in $(seq 1 30); do
        curl -sf -m 2 "${SVC_URL}/health" >/dev/null 2>&1 && break
        sleep 1
    done
    curl -sf -m 2 "${SVC_URL}/health" >/dev/null 2>&1 || {
        echo "ERROR: the wire desk never became healthy"
        cat "/tmp/caldon_svc_runall_${SVC_PORT}.log"
        exit 1
    }
fi
echo "wire desk healthy"

PASS=0
FAIL=0
FAILED_LIST=""
WORST=0
for s in "$DIR"/script_*.sh; do
    name="$(basename "$s")"
    # Per-script wall clock: the portal kills a test case that runs much
    # beyond two minutes, so the slowest script is a number this harness has
    # to report.
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
        printf '%s\n' "$out" | sed '$d' | sed 's/^/         /'
        tc="$(printf '%s' "$name" | sed 's/[^0-9]//g')"
        [ -f "$LOG_DIR/tc${tc}.log" ] && tail -n 12 "$LOG_DIR/tc${tc}.log" | sed 's/^/         log| /'
    fi
done

TOTAL=$(( (PASS + FAIL) * POINTS_PER_TEST ))
SCORE=$(( PASS * POINTS_PER_TEST ))
echo "----------------------------------------------------------------"
echo "SCORE: ${SCORE}/${TOTAL}   (passed ${PASS}, failed ${FAIL})"
echo "slowest test case: ${WORST}s   (portal limit is ~120s)"
echo "logs:  ${LOG_DIR}"
[ -n "$FAILED_LIST" ] && echo "failed:${FAILED_LIST}"
echo "----------------------------------------------------------------"
[ "$FAIL" -eq 0 ] || exit 1
