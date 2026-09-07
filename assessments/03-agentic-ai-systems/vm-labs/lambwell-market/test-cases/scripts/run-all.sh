#!/bin/bash
# LOCAL validation harness. NEVER shipped in TestCase.zip.
#
# Assembles a scratch project from app/ plus one candidate harvest directory,
# starts the market site, RUNS THE FOUR HARVEST SCRIPTS the way a learner would,
# then runs script_01..05 against the artefacts they left behind.
#
#   ./run-all.sh
#   CAND=reference-solution/_defect1_early_read ./run-all.sh
#
# PY must point at an interpreter with playwright and a chromium install.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$(cd "$DIR/../.." && pwd)"

CAND="${CAND:-reference-solution}"
CAND_DIR="$PACK/$CAND"
LAB_DIR="${LAB_DIR:-/tmp/lambwell-lab-ref}"
SITE_PORT="${SITE_PORT:-8711}"
SITE_URL="${SITE_URL:-http://127.0.0.1:${SITE_PORT}}"
SITE_BIN="${SITE_BIN:-$PACK/service/marketsite.py}"
PY="${PY:-python3}"
POINTS_PER_TEST="${POINTS_PER_TEST:-10}"
SKIP_HARVEST="${SKIP_HARVEST:-0}"

export LAB_DIR SITE_URL SITE_BIN PY
export OUT="${LAB_DIR}/out"
export LAMBWELL_SITE_URL="$SITE_URL"
export DEPS_READY_FILE="${DEPS_READY_FILE:-/tmp/lambwell-deps.ready}"
export TIMING_LOG="${TIMING_LOG:-/tmp/lambwell_timing.log}"
touch "$DEPS_READY_FILE"
: > "$TIMING_LOG"

[ -d "$CAND_DIR" ] || { echo "no candidate directory $CAND_DIR"; exit 1; }

echo "=== assembling $LAB_DIR ==="
rm -rf "$LAB_DIR"
mkdir -p "$LAB_DIR/out" "$LAB_DIR/harvest"
cp -R "$PACK/app/market_kit" "$LAB_DIR/"
cp "$PACK/app/check_local.py" "$LAB_DIR/" 2>/dev/null || true
for name in 01_listings 02_feed 03_session 04_audit; do
    if [ -f "$CAND_DIR/harvest/${name}.py" ]; then
        cp "$CAND_DIR/harvest/${name}.py" "$LAB_DIR/harvest/"
        echo "  ${name}.py <- $CAND"
    else
        cp "$PACK/reference-solution/harvest/${name}.py" "$LAB_DIR/harvest/"
        echo "  ${name}.py <- reference"
    fi
done
find "$LAB_DIR" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null

SITE_PID=""
cleanup() { [ -n "$SITE_PID" ] && kill "$SITE_PID" 2>/dev/null; return 0; }
trap cleanup EXIT

echo "=== starting the market site ==="
if curl -sf -m 3 "${SITE_URL}/health" >/dev/null 2>&1; then
    if [ "${REUSE_SITE:-0}" != "1" ]; then
        echo "ERROR: something is already answering on ${SITE_URL} - pick another port or set REUSE_SITE=1"
        exit 1
    fi
    echo "reusing the site already on that port"
else
    LAMBWELL_PORT="$SITE_PORT" "$PY" "$SITE_BIN" \
        >"/tmp/lambwell_site_${SITE_PORT}.log" 2>&1 &
    SITE_PID=$!
    disown "$SITE_PID" 2>/dev/null || true
    for i in $(seq 1 20); do
        curl -sf -m 2 "${SITE_URL}/health" >/dev/null 2>&1 && break
        sleep 1
    done
    curl -sf -m 2 "${SITE_URL}/health" >/dev/null 2>&1 || {
        echo "ERROR: the market site never became healthy"
        cat "/tmp/lambwell_site_${SITE_PORT}.log"
        exit 1
    }
fi
echo "market site healthy"
curl -sf -m 3 -X POST -H 'X-Grader-Key: lambwell-grader-lw4t' \
    "${SITE_URL}/__lw4t/reset" >/dev/null 2>&1
echo "site log reset"

if [ "$SKIP_HARVEST" != "1" ]; then
    echo "=== running the harvest (playing the learner) ==="
    # PYTHONPATH here stands in for the .pth that setup_script.sh writes into
    # site-packages on the VM; this harness assembles a scratch project and
    # never runs setup, so it has to supply the equivalent itself. It is NOT
    # evidence that `python3 harvest/01_listings.py` works unaided - that is
    # asserted on a provisioned VM by validation/permutations.sh row 1.
    for name in 01_listings 02_feed 03_session 04_audit; do
        t0=$SECONDS
        ( cd "$LAB_DIR" && PYTHONPATH="$LAB_DIR" LAMBWELL_SITE_URL="$SITE_URL" \
            "$PY" "harvest/${name}.py" ) >"/tmp/lambwell_${name}.log" 2>&1
        rc=$?
        printf '  %-14s %3ds  exit %d\n' "$name" "$((SECONDS - t0))" "$rc"
        [ "$rc" -eq 0 ] || tail -4 "/tmp/lambwell_${name}.log" | sed 's/^/       /'
    done
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
echo "CANDIDATE: $CAND"
echo "SCORE: ${SCORE}/${TOTAL}   (passed ${PASS}, failed ${FAIL})"
echo "slowest test case: ${WORST}s   (portal limit is about 120s)"
[ -n "$FAILED_LIST" ] && echo "failed:${FAILED_LIST}"
echo "----------------------------------------------------------------"
[ "$FAIL" -eq 0 ] || exit 1
