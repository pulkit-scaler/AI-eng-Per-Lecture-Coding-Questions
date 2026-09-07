#!/bin/bash
# LOCAL validation harness. NEVER shipped in TestCase.zip.
#
# Assembles a scratch lab dir from app/ plus a candidate solution, seeds the grid
# operations database, starts the model endpoint, runs script_01..05 in order and
# tallies the score.
#
#   ./run-all.sh                                        # grade the reference
#   SOLUTION=reference-solution/alt1_x.py ./run-all.sh
#   LAB_DIR=/tmp/lab-alt SVC_URL=http://127.0.0.1:8901 SOLUTION=... ./run-all.sh
#
# PY may point at a venv interpreter that has the pinned openai package.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$(cd "$DIR/../.." && pwd)"

LAB_DIR="${LAB_DIR:-/tmp/ashford-lab-ref}"
SOLUTION="${SOLUTION:-$PACK/reference-solution/solution.py}"
SVC_URL="${SVC_URL:-http://127.0.0.1:8836}"
SVC_BIN="${SVC_BIN:-$PACK/service/gridd.py}"
SEED_BIN="${SEED_BIN:-$PACK/service/seed_db.py}"
PY="${PY:-python3}"
POINTS_PER_TEST="${POINTS_PER_TEST:-10}"

# Keep the endpoint on whatever port SVC_URL names, so parallel runs stay isolated.
# ASHFORD_BASE_URL and ASHFORD_AUDIT_URL must move with it: those are what the
# learner's provided client and tools dial, and they default to 8836 (the port used
# on the real VM).
SVC_PORT="$(printf '%s' "$SVC_URL" | sed 's|.*:||; s|/.*||')"
export LAB_DIR SVC_URL SVC_BIN PY
export ASHFORD_PORT="$SVC_PORT"
export ASHFORD_BASE_URL="${SVC_URL}/v1"
export ASHFORD_AUDIT_URL="${SVC_URL}/v1/audit/query"
export ASHFORD_DB="${LAB_DIR}/data/grid_ops.db"
LOG_DIR="${LOG_DIR:-${LAB_DIR%/}-logs}"
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
export LOG_DIR

echo "=== assembling $LAB_DIR ==="
rm -rf "$LAB_DIR"
mkdir -p "$LAB_DIR/data"
cp -R "$PACK/app/grid_kit" "$LAB_DIR/"
cp "$PACK/app/check_local.py" "$LAB_DIR/"
cp "$SOLUTION" "$LAB_DIR/solution.py"
find "$LAB_DIR" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
# Guard: omitting SOLUTION grades the reference while appearing to grade the
# candidate, which turns every sheet into a row of perfect scores.
if ! cmp -s "$SOLUTION" "$LAB_DIR/solution.py"; then
    echo "ERROR: WRONG-FILE-GRADED - $LAB_DIR/solution.py is not $SOLUTION"
    exit 1
fi
echo "solution under test: $SOLUTION"

"$PY" "$SEED_BIN" "$ASHFORD_DB" >/dev/null || {
    echo "ERROR: could not seed $ASHFORD_DB"; exit 1; }
echo "database seeded: $ASHFORD_DB"

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

echo "=== starting model endpoint ==="
if curl -sf -m 3 "${SVC_URL}/health" >/dev/null 2>&1; then
    echo "already running (reusing)"
else
    ASHFORD_PORT="$SVC_PORT" ASHFORD_DB="$ASHFORD_DB" \
        "$PY" "$SVC_BIN" >"/tmp/ashford_svc_runall_${SVC_PORT}.log" 2>&1 &
    SVC_PID=$!
    # Off the job table, so the shell does not print a Terminated notice over the
    # score when cleanup kills it.
    disown "$SVC_PID" 2>/dev/null || true
    for i in $(seq 1 30); do
        curl -sf -m 2 "${SVC_URL}/health" >/dev/null 2>&1 && break
        sleep 1
    done
    curl -sf -m 2 "${SVC_URL}/health" >/dev/null 2>&1 || {
        echo "ERROR: model endpoint never became healthy"
        cat "/tmp/ashford_svc_runall_${SVC_PORT}.log"
        exit 1
    }
fi
echo "endpoint healthy"

# P0f: a check must write EXACTLY ONE line to stdout, on the pass path and on the
# fail path alike. The judge grades the last line, so a second line voids the
# verdict and a zeroth line reports no test cases. Counted per check below.
STDOUT_LINES=""

# The platform's main.sh BREAKS at the first failing case, so the score a learner
# actually receives is a PREFIX, not a per-theme sum: a submission that fails
# check 1 never runs checks 2-5 and scores 0/50, not 40/50. This harness runs all
# five (which is what makes a defect probe diagnosable), so it reports both: the
# per-theme total and the prefix total the portal would award.
PREFIX_PASS=0
PREFIX_OPEN=1

PASS=0
FAIL=0
FAILED_LIST=""
WORST=0
for s in "$DIR"/script_*.sh; do
    name="$(basename "$s")"
    # Per-script wall clock: the portal kills a test case that runs much beyond two
    # minutes, so the slowest script is a number this harness has to report.
    t0=$SECONDS
    # One run, streams kept apart. The judge captures stdout+stderr together and
    # grades the last line, so the pair of facts that matter are (a) stdout is
    # exactly one line and (b) stderr is empty. Splitting them here lets both be
    # asserted from a single execution: running the check twice would double every
    # side effect and every second of wall clock.
    so="$(mktemp /tmp/ashford_so_XXXXXX)"
    se="$(mktemp /tmp/ashford_se_XXXXXX)"
    bash "$s" >"$so" 2>"$se"
    out="$(cat "$so" "$se")"
    # grep -c prints its count and THEN exits 1 when the count is zero, so an
    # "|| echo 0" fallback appends a second line and the arithmetic below breaks
    # on "0\n0". Swallow the status instead of substituting for it.
    n_out="$(grep -c . "$so" 2>/dev/null || true)"; n_out="${n_out:-0}"
    n_err="$(grep -c . "$se" 2>/dev/null || true)"; n_err="${n_err:-0}"
    took=$((SECONDS - t0))
    if [ "${n_out:-0}" -ne 1 ]; then
        STDOUT_LINES="${STDOUT_LINES} ${name}:stdout=${n_out:-0}lines"
    fi
    if [ "${n_err:-0}" -ne 0 ]; then
        STDOUT_LINES="${STDOUT_LINES} ${name}:stderr=${n_err:-0}lines"
    fi
    rm -f "$so" "$se"
    [ "$took" -gt "$WORST" ] && WORST=$took
    # Grade exactly what the platform's main.sh grades: the LAST line of the
    # captured stdout+stderr, parsed as JSON, read at .status. Matching the first
    # RESULT: line anywhere hid the whole class of bug this harness exists to
    # catch: a check that prints its verdict and then emits one more line (an ERR
    # trap firing, a job-control notice on stderr) scored full marks here and
    # reported NO TEST CASES AT ALL on the portal.
    line="$(printf '%s\n' "$out" | tail -n 1)"
    vstatus="$(printf '%s' "$line" | jq -r '.status // "UNPARSEABLE"' 2>/dev/null || echo UNPARSEABLE)"
    msg="$(printf '%s' "$line" | jq -r '.message // empty' 2>/dev/null)"
    if [ "$vstatus" = "UNPARSEABLE" ]; then
        # Legacy RESULT: shape, still accepted but still LAST-LINE-BASED, so the
        # harness can never be laxer than the judge.
        case "$line" in
            RESULT:success\ \|\ *) vstatus=success; msg="${line#RESULT:success | }" ;;
            RESULT:failed\ \|\ *)  vstatus=failed;  msg="${line#RESULT:failed | }" ;;
        esac
    fi
    if [ "$vstatus" = "UNPARSEABLE" ]; then
        FAIL=$((FAIL + 1))
        PREFIX_OPEN=0
        FAILED_LIST="$FAILED_LIST $name"
        printf '  [!!!!] UNPARSEABLE %-8s %3ds\n' "$name" "$took"
        printf '         The LAST line of this check is not a verdict, so the portal would\n'
        printf '         discard the verdict entirely and report this submission as having NO\n'
        printf '         TEST CASE RESULTS AT ALL - an empty panel, not a failed row.\n'
        printf '         Last line was: %s\n' "$line"
        printf '%s\n' "$out" | sed 's/^/         /'
        continue
    fi
    [ -n "$msg" ] || msg="(verdict carried no message)"
    if [ "$vstatus" = "success" ]; then
        PASS=$((PASS + 1))
        [ "$PREFIX_OPEN" -eq 1 ] && PREFIX_PASS=$((PREFIX_PASS + 1))
        printf '  [PASS] %-16s %3ds  %s\n' "$name" "$took" "$msg"
    else
        FAIL=$((FAIL + 1))
        PREFIX_OPEN=0
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
PREFIX=$(( PREFIX_PASS * POINTS_PER_TEST ))
echo "SCORE: ${SCORE}/${TOTAL}   (passed ${PASS}, failed ${FAIL})"
echo "PORTAL: ${PREFIX}/${TOTAL}  (main.sh breaks at the first failure, so the learner's"
echo "                            score is the leading run of passes, not the sum)"
echo "slowest test case: ${WORST}s   (portal limit is ~120s)"
echo "logs:  ${LOG_DIR}"
[ -n "$FAILED_LIST" ] && echo "failed:${FAILED_LIST}"
if [ -n "$STDOUT_LINES" ]; then
    echo "[!!!!] VERDICT-STREAM INVARIANT BROKEN:${STDOUT_LINES}"
    echo "       Each check must print exactly 1 line to stdout and nothing to stderr."
    echo "       The judge grades the last line of the two streams combined: a second"
    echo "       line on either one discards the verdict and the portal then reports"
    echo "       no test case results at all, while zero lines score a silent 0."
else
    echo "verdict stream: every check printed exactly 1 stdout line and 0 stderr lines"
fi
echo "----------------------------------------------------------------"
[ "$FAIL" -eq 0 ] || exit 1
