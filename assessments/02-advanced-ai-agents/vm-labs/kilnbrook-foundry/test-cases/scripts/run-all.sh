#!/bin/bash
# LOCAL validation harness. NEVER shipped in TestCase.zip.
#
# Assembles a scratch lab dir from app/ plus a candidate solution, builds the
# foundry database, starts the model endpoint, runs script_01..05 in order and
# tallies the score.
#
#   ./run-all.sh                                     # grade reference-solution/solution.py
#   SOLUTION=reference-solution/alt1_x.py ./run-all.sh
#   LAB_DIR=/tmp/lab-alt SOLUTION=... ./run-all.sh
#
# PY may point at a venv interpreter holding the openai package.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$(cd "$DIR/../.." && pwd)"

LAB_DIR="${LAB_DIR:-/tmp/kilnbrook-lab-ref}"
SOLUTION="${SOLUTION:-$PACK/reference-solution/solution.py}"
SVC_URL="${SVC_URL:-http://127.0.0.1:8781}"
SVC_BIN="${SVC_BIN:-$PACK/service/foundryd.py}"
PY="${PY:-python3}"
POINTS_PER_TEST="${POINTS_PER_TEST:-10}"

# Keep the endpoint on whatever port SVC_URL names, so parallel runs stay isolated.
SVC_PORT="$(printf '%s' "$SVC_URL" | sed 's|.*:||; s|/.*||')"
DB_FILE="$LAB_DIR/data/foundry.db"
export LAB_DIR SVC_URL SVC_BIN PY DB_FILE
export KILN_PORT="$SVC_PORT" KILN_DB="$DB_FILE" KILN_ENDPOINT="${SVC_URL}/v1"
LOG_DIR="${LOG_DIR:-${LAB_DIR%/}-logs}"
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
export LOG_DIR

echo "=== assembling $LAB_DIR ==="
rm -rf "$LAB_DIR"
mkdir -p "$LAB_DIR/data"
cp -R "$PACK/app/kiln_kit" "$LAB_DIR/"
cp "$PACK/app/check_local.py" "$LAB_DIR/"
cp "$SOLUTION" "$LAB_DIR/solution.py"
find "$LAB_DIR" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
"$PY" "$PACK/service/make_db.py" "$DB_FILE" >/dev/null || {
    echo "ERROR: could not build the foundry database"; exit 1; }
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
    # Wait for the port to go quiet, so a run started right after this one cannot
    # health-check a dying endpoint and then lose it mid-test.
    local i
    for i in $(seq 1 20); do
        curl -sf -m 1 "${SVC_URL}/health" >/dev/null 2>&1 || return 0
        sleep 0.5
    done
    return 0
}
trap cleanup EXIT

echo "=== starting the model endpoint ==="
if curl -sf -m 3 "${SVC_URL}/health" >/dev/null 2>&1; then
    echo "already running (reusing)"
else
    KILN_PORT="$SVC_PORT" KILN_DB="$DB_FILE" "$PY" "$SVC_BIN" \
        >"/tmp/kilnbrook_svc_runall_${SVC_PORT}.log" 2>&1 &
    SVC_PID=$!
    for i in $(seq 1 30); do
        curl -sf -m 2 "${SVC_URL}/health" >/dev/null 2>&1 && break
        sleep 1
    done
    curl -sf -m 2 "${SVC_URL}/health" >/dev/null 2>&1 || {
        echo "ERROR: the model endpoint never became healthy"
        cat "/tmp/kilnbrook_svc_runall_${SVC_PORT}.log"
        exit 1
    }
fi
echo "endpoint healthy"

PASS=0
FAIL=0
FAILED_LIST=""
WORST=0
# The platform's main.sh breaks out of its loop at the first check that does not
# report success, so the score a learner actually receives is the PREFIX of passing
# checks, not the sum of every theme that happened to pass. Both numbers are
# reported below: the per-theme sum says which themes work, the prefix says what
# the portal would award.
PREFIX=0
PREFIX_OPEN=1
for s in "$DIR"/script_*.sh; do
    name="$(basename "$s")"
    # Per-script wall clock: the portal kills a test case that runs much beyond two
    # minutes, so the slowest script is a number this harness has to report.
    t0=$SECONDS
    out="$(bash "$s" 2>&1)"
    took=$((SECONDS - t0))
    [ "$took" -gt "$WORST" ] && WORST=$took
    # Grade exactly what the platform grades: the LAST line of stdout and stderr
    # combined, parsed as the JSON the real common.sh emits. Matching the first
    # RESULT: line anywhere used to hide the worst failure this family has: a check
    # that printed its verdict and then one more line scored full marks here and
    # reported no test cases at all on the portal.
    line="$(printf '%s\n' "$out" | tail -n 1)"
    vstatus="$(jq -r '.status' 2>/dev/null <<<"$line")"
    msg="$(jq -r '.message' 2>/dev/null <<<"$line")"
    if [ -z "$vstatus" ] || [ "$vstatus" = "null" ]; then
        # Keep the legacy RESULT: shape gradeable, but only as the last line.
        case "$line" in
            RESULT:success\ \|\ *) vstatus="success"; msg="${line#RESULT:success | }" ;;
            RESULT:failed\ \|\ *)  vstatus="failed";  msg="${line#RESULT:failed | }" ;;
            *)                     vstatus="UNPARSEABLE" ;;
        esac
    fi
    tc="$(printf '%s' "$name" | sed 's/[^0-9]//g')"
    if [ "$vstatus" = "success" ]; then
        PASS=$((PASS + 1))
        [ "$PREFIX_OPEN" -eq 1 ] && PREFIX=$((PREFIX + 1))
        printf '  [PASS] %-16s %3ds  %s\n' "$name" "$took" "$msg"
    elif [ "$vstatus" = "UNPARSEABLE" ]; then
        PREFIX_OPEN=0
        FAIL=$((FAIL + 1))
        FAILED_LIST="$FAILED_LIST $name"
        printf '  [!!!!] %-16s %3ds  UNPARSEABLE VERDICT\n' "$name" "$took"
        printf '         The last line of this check is not a verdict, so the portal would\n'
        printf '         report this submission as having NO TEST CASES AT ALL - no rows, no\n'
        printf '         score, and no message for the learner. Last line was: %s\n' "$line"
        printf '%s\n' "$out" | sed 's/^/         /'
    else
        PREFIX_OPEN=0
        FAIL=$((FAIL + 1))
        FAILED_LIST="$FAILED_LIST $name"
        printf '  [FAIL] %-16s %3ds  %s\n' "$name" "$took" "${msg:-(no message)}"
        printf '%s\n' "$out" | sed '$d' | sed 's/^/         /'
        [ -f "$LOG_DIR/tc${tc}.log" ] && tail -n 12 "$LOG_DIR/tc${tc}.log" | sed 's/^/         log| /'
    fi
    # One line of stdout on both paths is a contract, not a hope: the judge grades
    # the last line, so a second line would void the verdict.
    nlines="$(printf '%s\n' "$out" | grep -c . || true)"
    if [ "${nlines:-0}" -ne 1 ]; then
        printf '         [warn] %s wrote %s lines to stdout+stderr; exactly 1 is required\n' \
            "$name" "$nlines"
    fi
done

TOTAL=$(( (PASS + FAIL) * POINTS_PER_TEST ))
SCORE=$(( PASS * POINTS_PER_TEST ))
echo "----------------------------------------------------------------"
echo "SCORE: ${SCORE}/${TOTAL}   (passed ${PASS}, failed ${FAIL})"
echo "PORTAL: $((PREFIX * POINTS_PER_TEST))/${TOTAL}   (main.sh stops at the first failing check)"
echo "slowest test case: ${WORST}s   (portal limit is ~120s)"
echo "logs:  ${LOG_DIR}"
[ -n "$FAILED_LIST" ] && echo "failed:${FAILED_LIST}"
echo "----------------------------------------------------------------"
[ "$FAIL" -eq 0 ] || exit 1
