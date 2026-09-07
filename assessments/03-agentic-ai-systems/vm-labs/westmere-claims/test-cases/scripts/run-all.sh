#!/bin/bash
# LOCAL validation harness. NEVER shipped in TestCase.zip.
#
# Assembles a scratch project from app/ plus one candidate claimctl.py, starts
# the claims desk, runs script_01..05 in order and tallies the score.
#
#   ./run-all.sh
#   SOLUTION=reference-solution/alt1_no_lcel.py ./run-all.sh
#   LAB_DIR=/tmp/w-alt DESK_URL=http://127.0.0.1:8901 SOLUTION=... ./run-all.sh
#
# PY must point at an interpreter that has langgraph and langchain-core.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$(cd "$DIR/../.." && pwd)"

LAB_DIR="${LAB_DIR:-/tmp/westmere-lab-ref}"
SOLUTION="${SOLUTION:-$PACK/reference-solution/claimctl.py}"
DESK_URL="${DESK_URL:-http://127.0.0.1:8571}"
DESK_BIN="${DESK_BIN:-$PACK/service/claimsvc.py}"
PY="${PY:-python3}"
POINTS_PER_TEST="${POINTS_PER_TEST:-10}"

DESK_PORT="$(printf '%s' "$DESK_URL" | sed 's|.*:||; s|/.*||')"
export LAB_DIR DESK_URL PY
export DESK_BIN="$DESK_BIN"
export WESTMERE_PORT="$DESK_PORT"
export WESTMERE_DESK_URL="$DESK_URL"
export DEPS_READY_FILE="${DEPS_READY_FILE:-/tmp/westmere-deps.ready}"
export TIMING_LOG="${TIMING_LOG:-/tmp/westmere_timing.log}"
touch "$DEPS_READY_FILE"
: > "$TIMING_LOG"

echo "=== assembling $LAB_DIR ==="
rm -rf "$LAB_DIR"
mkdir -p "$LAB_DIR/data" "$LAB_DIR/state"
cp -R "$PACK/app/claim_kit" "$LAB_DIR/"
cp "$PACK/app/check_local.py" "$LAB_DIR/"
cp "$PACK/app/data/claims.json" "$LAB_DIR/data/"
cp "$SOLUTION" "$LAB_DIR/claimctl.py"
# Any sibling module the candidate needs travels with it.
CAND_DIR="$(dirname "$SOLUTION")"
for extra in "$CAND_DIR"/_lib_*.py; do
    [ -f "$extra" ] && cp "$extra" "$LAB_DIR/"
done
find "$LAB_DIR" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
# Guard: omitting SOLUTION would grade the reference while appearing to grade
# the candidate, which turns every sheet into a row of perfect scores.
if ! cmp -s "$SOLUTION" "$LAB_DIR/claimctl.py"; then
    echo "ERROR: WRONG-FILE-GRADED - $LAB_DIR/claimctl.py is not $SOLUTION"
    exit 1
fi
echo "candidate under test: $SOLUTION"

DESK_PID=""
cleanup() {
    [ -n "$DESK_PID" ] || return 0
    kill "$DESK_PID" 2>/dev/null
    local i
    for i in $(seq 1 20); do
        curl -sf -m 1 "${DESK_URL}/health" >/dev/null 2>&1 || return 0
        sleep 0.5
    done
    return 0
}
trap cleanup EXIT

echo "=== starting the claims desk ==="
if curl -sf -m 3 "${DESK_URL}/health" >/dev/null 2>&1; then
    # Reusing whatever already answers on this port is how a sweep row ends up
    # graded against a desk that is on its way out, which reads as a broken
    # candidate rather than as a harness problem. Refuse unless asked.
    if [ "${REUSE_DESK:-0}" != "1" ]; then
        echo "ERROR: something is already answering on ${DESK_URL} - pick another port or set REUSE_DESK=1"
        exit 1
    fi
    echo "already running (reusing on request)"
else
    WESTMERE_PORT="$DESK_PORT" WESTMERE_CLAIMS="$PACK/app/data/claims.json" \
        "$PY" "$DESK_BIN" >"/tmp/westmere_desk_runall_${DESK_PORT}.log" 2>&1 &
    DESK_PID=$!
    disown "$DESK_PID" 2>/dev/null || true
    for i in $(seq 1 30); do
        curl -sf -m 2 "${DESK_URL}/health" >/dev/null 2>&1 && break
        sleep 1
    done
    curl -sf -m 2 "${DESK_URL}/health" >/dev/null 2>&1 || {
        echo "ERROR: the claims desk never became healthy"
        cat "/tmp/westmere_desk_runall_${DESK_PORT}.log"
        exit 1
    }
fi
echo "claims desk healthy"

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
