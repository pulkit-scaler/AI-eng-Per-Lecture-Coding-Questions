#!/bin/bash
# LOCAL validation harness. NEVER shipped in TestCase.zip.
#
# Assembles a scratch lab dir from app/ plus a candidate server.py and
# solution.py, seeds the operations database, starts the operations service, runs
# script_01..05 in order and tallies the score.
#
#   ./run-all.sh                                            # grade the reference
#   SOLUTION=reference-solution/alt1_solution.py \
#   SERVER=reference-solution/alt1_server.py ./run-all.sh
#   LAB_DIR=/tmp/lab-alt SVC_URL=http://127.0.0.1:9401 ... ./run-all.sh
#
# PY may point at a venv interpreter holding the pinned mcp/openai.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$(cd "$DIR/../.." && pwd)"

LAB_DIR="${LAB_DIR:-/tmp/larkspur-lab-ref}"
SOLUTION="${SOLUTION:-$PACK/reference-solution/solution.py}"
SERVER="${SERVER:-$PACK/reference-solution/server.py}"
SVC_URL="${SVC_URL:-http://127.0.0.1:8757}"
SVC_BIN="${SVC_BIN:-$PACK/service/opsd.py}"
PY="${PY:-python3}"
POINTS_PER_TEST="${POINTS_PER_TEST:-10}"

# Keep the service on whatever port SVC_URL names, so parallel runs stay isolated.
# LARKSPUR_SERVICE_URL must move with it: that is what the provided kit dials, and
# it defaults to 8757 (the port used on the real VM).
SVC_PORT="$(printf '%s' "$SVC_URL" | sed 's|.*:||; s|/.*||')"
export LAB_DIR SVC_URL SVC_BIN PY
export LARKSPUR_PORT="$SVC_PORT" LARKSPUR_SERVICE_URL="$SVC_URL"
export LARKSPUR_DB="$LAB_DIR/data/transit.db"
LOG_DIR="${LOG_DIR:-${LAB_DIR%/}-logs}"
rm -rf "$LOG_DIR"; mkdir -p "$LOG_DIR"
export LOG_DIR

echo "=== assembling $LAB_DIR ==="
rm -rf "$LAB_DIR"
mkdir -p "$LAB_DIR/data"
cp -R "$PACK/app/transit_kit" "$LAB_DIR/"
cp "$PACK/app/check_local.py" "$LAB_DIR/"
cp "$SERVER" "$LAB_DIR/server.py"
cp "$SOLUTION" "$LAB_DIR/solution.py"
printf '%s' "$SVC_URL" > "$LAB_DIR/transit_kit/service.url"
"$PY" "$PACK/app/seed_db.py" "$LAB_DIR/data/transit.db" >/dev/null || {
    echo "ERROR: could not seed the operations database"; exit 1; }
find "$LAB_DIR" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
# Guard: omitting SOLUTION or SERVER grades the reference while appearing to grade
# the candidate, which turns every sheet into a row of perfect scores.
if ! cmp -s "$SOLUTION" "$LAB_DIR/solution.py"; then
    echo "ERROR: WRONG-FILE-GRADED - $LAB_DIR/solution.py is not $SOLUTION"; exit 1
fi
if ! cmp -s "$SERVER" "$LAB_DIR/server.py"; then
    echo "ERROR: WRONG-FILE-GRADED - $LAB_DIR/server.py is not $SERVER"; exit 1
fi
echo "under test: server=$(basename "$SERVER")  solution=$(basename "$SOLUTION")"

SVC_PID=""
cleanup() {
    [ -n "$SVC_PID" ] || return 0
    kill "$SVC_PID" 2>/dev/null
    # Wait for the port to go quiet, so a run started right after this one cannot
    # health-check a dying service and then lose it mid-test.
    local i
    for i in $(seq 1 20); do
        curl -sf -m 1 "${SVC_URL}/health" >/dev/null 2>&1 || return 0
        sleep 0.5
    done
    return 0
}
trap cleanup EXIT

echo "=== starting operations service ==="
if curl -sf -m 3 "${SVC_URL}/health" >/dev/null 2>&1; then
    echo "already running (reusing)"
else
    LARKSPUR_PORT="$SVC_PORT" "$PY" "$SVC_BIN" \
        >"/tmp/larkspur_svc_runall_${SVC_PORT}.log" 2>&1 &
    SVC_PID=$!
    # Detach it from job control, or killing it at exit makes bash print a
    # "Terminated" notice on stderr after the score block. Harmless here, but this
    # harness output is read as evidence and a stray line in it invites the wrong
    # conclusion.
    disown "$SVC_PID" 2>/dev/null || true
    for i in $(seq 1 30); do
        curl -sf -m 2 "${SVC_URL}/health" >/dev/null 2>&1 && break
        sleep 1
    done
    curl -sf -m 2 "${SVC_URL}/health" >/dev/null 2>&1 || {
        echo "ERROR: operations service never became healthy"
        cat "/tmp/larkspur_svc_runall_${SVC_PORT}.log"
        exit 1
    }
fi
echo "service healthy"

PASS=0
FAIL=0
FAILED_LIST=""
WORST=0
STREAMBAD=0
# The judge's main.sh breaks at the first failing case, so the score a learner
# actually receives is the leading run of passes, not the per-theme sum. Report
# both: the sum makes a defect probe diagnosable, the prefix is what they see.
PREFIX_PASS=0
PREFIX_OPEN=1
# Snapshot of matching processes that already existed, so the stray count below is
# what THIS run leaked and nothing else.
server_pids_snapshot() {
    pgrep -f 'server\.py' 2>/dev/null | while read -r p; do
        ps -o args= -p "$p" 2>/dev/null | grep -q 'run-all\.sh' && continue
        echo "$p"
    done | LC_ALL=C sort -u
}
PIDS_BEFORE="$(server_pids_snapshot)"
: > /tmp/larkspur_timing.log
for s in "$DIR"/script_*.sh; do
    name="$(basename "$s")"
    # Per-script wall clock: the portal kills a test case that runs much beyond two
    # minutes, so the slowest script is a number this harness has to report.
    t0=$SECONDS
    # One run only. Keep the two streams apart so the stdout-line count below is
    # exact, then grade the interleaving the judge sees (stdout+stderr, last line).
    bash "$s" >"$LOG_DIR/${name}.stdout" 2>"$LOG_DIR/${name}.stderr"
    out="$(cat "$LOG_DIR/${name}.stdout" "$LOG_DIR/${name}.stderr" 2>/dev/null)"
    took=$((SECONDS - t0))
    [ "$took" -gt "$WORST" ] && WORST=$took
    # Grade exactly what the platform grades: the LAST line of stdout+stderr,
    # parsed as the JSON object the real common.sh emits. Matching the FIRST
    # RESULT: line anywhere is what let the ERR-trap bug through - a check that
    # printed its verdict and then emitted one more line scored full marks here
    # while the portal reported no test cases at all.
    line="$(printf '%s\n' "$out" | tail -n 1)"
    vstatus="$(printf '%s' "$line" | jq -r '.status // "UNPARSEABLE"' 2>/dev/null || echo UNPARSEABLE)"
    msg="$(printf '%s' "$line" | jq -r '.message // empty' 2>/dev/null)"
    if [ -z "$msg" ]; then
        # Keep the legacy RESULT: shape gradeable, but only from the last line,
        # so this harness is never laxer than the judge.
        case "$line" in
            RESULT:success\ \|\ *) vstatus="success"; msg="${line#RESULT:success | }" ;;
            RESULT:failed\ \|\ *)  vstatus="failed";  msg="${line#RESULT:failed | }" ;;
            *) vstatus="UNPARSEABLE" ;;
        esac
    fi
    if [ "$vstatus" = "UNPARSEABLE" ]; then
        FAIL=$((FAIL + 1))
        PREFIX_OPEN=0
        FAILED_LIST="$FAILED_LIST $name"
        printf '  [!!!!] UNPARSEABLE %-8s %3ds\n' "$name" "$took"
        printf '         the last line of this check output is not a verdict, so the portal\n'
        printf '         would report this submission as having NO TEST CASES AT ALL - not a\n'
        printf '         zero, an empty results panel. Last line was: %s\n' "$line"
        printf '%s\n' "$out" | sed 's/^/         /'
    elif [ "$vstatus" = "success" ]; then
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
        for extra in "$LOG_DIR/tc${tc}.log" "/tmp/larkspur_tc${tc}.err" \
                     "/tmp/larkspur_probe_${tc}.err"; do
            [ -s "$extra" ] && tail -n 8 "$extra" | sed "s|^|         $(basename "$extra")\| |"
        done
    fi
    # Each check must write exactly ONE line to stdout, on the pass path and on
    # the fail path alike, and nothing at all to stderr. A second line either way
    # is what the judge would grade instead of the verdict.
    stdout_lines="$(grep -c . "$LOG_DIR/${name}.stdout" 2>/dev/null | tr -d ' ')"
    stderr_lines="$(grep -c . "$LOG_DIR/${name}.stderr" 2>/dev/null | tr -d ' ')"
    if [ "${stdout_lines:-0}" -ne 1 ] || [ "${stderr_lines:-0}" -ne 0 ]; then
        printf '  [!!!!] %s wrote %s line(s) to stdout (want 1) and %s to stderr (want 0);\n' \
            "$name" "${stdout_lines:-0}" "${stderr_lines:-0}"
        printf '         the judge grades the last line of the two combined\n'
        STREAMBAD=$((STREAMBAD + 1))
    fi
done

# The MCP server is a child process every check starts. A leaked one would keep a
# file handle on the learner project and slowly fill the VM, so say so plainly.
#
# Matched on the check work-directory prefix, not on `server.py`. A bare
# `pgrep -f 'server\.py'` counts any unrelated python process on the box with those
# characters in its command line - including another lab, another sweep, or an
# authoring probe running in a second terminal - which made this column
# non-deterministic between two passes of the same sweep and looked exactly like a
# flaky grader. Every server the checks start is launched with an absolute path
# inside a larkspur_work_* directory, so that prefix identifies ours precisely.
# Reported as a DELTA against a snapshot taken before the run, not as an absolute
# count. A bare `pgrep -f 'server\.py'` counts any unrelated python process on the
# box with those characters in its command line: another lab, another sweep, an
# authoring probe in a second terminal. That made this column disagree between two
# passes of the same sweep and looked exactly like a flaky grader. TC01 to TC04
# launch the server by absolute path inside larkspur_work_*, but TC05 launches it
# through the learner own client with a relative "server.py", so no single pattern
# identifies ours. The delta does.
server_pids() {
    pgrep -f 'server\.py' 2>/dev/null | while read -r p; do
        ps -o args= -p "$p" 2>/dev/null | grep -q 'run-all\.sh' && continue
        echo "$p"
    done | LC_ALL=C sort -u
}
strays() { comm -13 <(printf '%s\n' "$PIDS_BEFORE") <(server_pids); }
LEAKED="$(strays | wc -l | tr -d ' ')"
# On the VM each check reaps its own strays from its EXIT trap, keyed on /proc.
# There is no /proc off-VM, so this authoring-only harness does the sweep itself
# after counting - otherwise a probe that deliberately hangs leaves a process
# behind for the rest of the sweep.
if [ "${LEAKED:-0}" -gt 0 ]; then
    strays | while read -r p; do kill -9 "$p" 2>/dev/null; done
fi

TOTAL=$(( (PASS + FAIL) * POINTS_PER_TEST ))
SCORE=$(( PASS * POINTS_PER_TEST ))
echo "----------------------------------------------------------------"
echo "SCORE: ${SCORE}/${TOTAL}   (passed ${PASS}, failed ${FAIL})"
echo "PORTAL: $(( PREFIX_PASS * POINTS_PER_TEST ))/${TOTAL}  (main.sh breaks at the first failure, so the learner's"
echo "                            score is the leading run of passes, not the sum)"
echo "slowest test case: ${WORST}s   (portal limit is ~120s)"
echo "stray server.py processes after the run: ${LEAKED}"
echo "checks whose streams were not one clean stdout line: ${STREAMBAD}"
echo "per-check wall time:"; sed 's/^/    /' /tmp/larkspur_timing.log 2>/dev/null
echo "logs:  ${LOG_DIR}"
[ -n "$FAILED_LIST" ] && echo "failed:${FAILED_LIST}"
echo "----------------------------------------------------------------"
[ "$FAIL" -eq 0 ] || exit 1
