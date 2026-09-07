#!/bin/bash
# Ordering matrix. The happy path passing tells you almost nothing: the failures
# that reach learners come from orderings nobody tried - submitting before
# running the harvest, running only some of it, a grading run killed half way, a
# second submission.
#
# Every row asserts the score AND that the learner is not locked out of their own
# project afterwards. Run as root on the target VM once before the first cohort;
# on an authoring host with no `user` account the ownership rows self-report as
# vacuous.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$(cd "$DIR/.." && pwd)"
SCRIPTS="$PACK/test-cases/scripts"
LAB_DIR="${LAB_DIR:-/tmp/lambwell-perm}"
SITE_PORT="${SITE_PORT:-8779}"
SITE_URL="${SITE_URL:-http://127.0.0.1:${SITE_PORT}}"
PY="${PY:-python3}"
export LAB_DIR SITE_URL PY
export OUT="${LAB_DIR}/out"
export SITE_BIN="$PACK/service/marketsite.py"
export LAMBWELL_SITE_URL="$SITE_URL"
export DEPS_READY_FILE="${DEPS_READY_FILE:-/tmp/lambwell-deps.ready}"
export TIMING_LOG="/tmp/lambwell_perm_timing.log"
touch "$DEPS_READY_FILE"

HAVE_USER=0
id -u user >/dev/null 2>&1 && HAVE_USER=1
ROWS=0; BAD=0
note() { printf '  %s\n' "$*"; }
fail() { BAD=$((BAD + 1)); printf '  FAIL %s\n' "$*"; }
pass() { printf '  ok   %s\n' "$*"; }

SITE_PID=""
start_site() {
    curl -sf -m 2 "${SITE_URL}/health" >/dev/null 2>&1 && return 0
    LAMBWELL_PORT="$SITE_PORT" "$PY" "$SITE_BIN" \
        >/tmp/lambwell_perm_site.log 2>&1 &
    SITE_PID=$!
    disown "$SITE_PID" 2>/dev/null || true
    local i
    for i in $(seq 1 20); do
        curl -sf -m 2 "${SITE_URL}/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}
cleanup() { [ -n "$SITE_PID" ] && kill "$SITE_PID" 2>/dev/null; return 0; }
trap cleanup EXIT

reset_site() {
    curl -sf -m 3 -X POST -H 'X-Grader-Key: lambwell-grader-lw4t' \
        "${SITE_URL}/__lw4t/reset" >/dev/null 2>&1
    return 0
}

assemble() {  # assemble <written:0|1>
    rm -rf "$LAB_DIR"
    mkdir -p "$LAB_DIR/out" "$LAB_DIR/harvest"
    cp -R "$PACK/app/market_kit" "$LAB_DIR/"
    cp "$PACK/app/check_local.py" "$LAB_DIR/"
    for name in 01_listings 02_feed 03_session 04_audit; do
        if [ "$1" = "1" ]; then
            cp "$PACK/reference-solution/harvest/${name}.py" "$LAB_DIR/harvest/"
        else
            cp "$PACK/app/harvest/${name}_stub.py" "$LAB_DIR/harvest/${name}.py"
        fi
    done
    [ "$HAVE_USER" -eq 1 ] && chown -R user:user "$LAB_DIR" 2>/dev/null
    return 0
}

run_harvest() {  # run_harvest [n-steps]
    local limit="${1:-4}" n=0 name
    for name in 01_listings 02_feed 03_session 04_audit; do
        n=$((n + 1))
        [ "$n" -gt "$limit" ] && break
        ( cd "$LAB_DIR" && PYTHONPATH="$LAB_DIR" LAMBWELL_SITE_URL="$SITE_URL" \
            "$PY" "harvest/${name}.py" ) >/tmp/lambwell_perm_${name}.log 2>&1
    done
    [ "$HAVE_USER" -eq 1 ] && chown -R user:user "$LAB_DIR" 2>/dev/null
    return 0
}

grade() {  # grade [n-scripts] -> echoes score
    local limit="${1:-5}" n=0 good=0
    for s in "$SCRIPTS"/script_*.sh; do
        n=$((n + 1))
        [ "$n" -gt "$limit" ] && break
        if bash "$s" 2>&1 | grep -q '^RESULT:success'; then
            good=$((good + 1))
        fi
    done
    echo $((good * 10))
}

check_ownership() {
    if [ "$HAVE_USER" -eq 0 ]; then
        note "ownership assertion VACUOUS on this host (no user account) - run this on the VM"
        return 0
    fi
    local rooted
    rooted="$(find "$LAB_DIR" -user root 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${rooted:-0}" -ne 0 ]; then
        fail "$1: ${rooted} root-owned paths under the project"
    else
        pass "$1: nothing under the project is root-owned"
    fi
}

check_learner_can_work() {
    local rc
    if [ "$HAVE_USER" -eq 1 ]; then
        su - user -c "cd $LAB_DIR && PYTHONPATH=$LAB_DIR LAMBWELL_SITE_URL=$SITE_URL $PY harvest/01_listings.py >/dev/null"
        rc=$?
    else
        ( cd "$LAB_DIR" && PYTHONPATH="$LAB_DIR" LAMBWELL_SITE_URL="$SITE_URL" \
            "$PY" harvest/01_listings.py >/dev/null 2>&1 )
        rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        pass "$1: the learner can still re-run their own harvest afterwards"
    else
        fail "$1: the learner cannot re-run their own harvest afterwards (exit $rc)"
    fi
}

row() { ROWS=$((ROWS + 1)); echo; echo "--- row ${ROWS}: $* --- (t+${SECONDS}s)"; }

start_site || { echo "the market site would not start"; exit 1; }

# Before any ordering matters: the command the statement tells the learner to
# type has to work on a provisioned VM with no PYTHONPATH set. Everything else
# in this pack - run-all.sh, check_local.py, the rows below - injects one, so
# nothing else here would ever catch a broken path bootstrap. This row is only
# meaningful against the real project, which is why it self-reports as vacuous
# on an authoring host.
REAL_PROJ="/home/user/lambwell-market"
row "the statement's own command can import market_kit"
if [ "$HAVE_USER" -eq 0 ] || [ ! -d "${REAL_PROJ}/market_kit" ]; then
    note "VACUOUS on this host (no provisioned ${REAL_PROJ}) - run this on the VM"
else
    printf 'import market_kit\n' > /tmp/lambwell_pathcheck.py
    chmod 644 /tmp/lambwell_pathcheck.py
    if su - user -c "cd '${REAL_PROJ}' && python3 /tmp/lambwell_pathcheck.py" >/dev/null 2>&1; then
        pass "row ${ROWS}: market_kit imports from ${REAL_PROJ} with no PYTHONPATH"
    else
        fail "row ${ROWS}: market_kit does NOT import from ${REAL_PROJ} - the learner cannot run harvest/01_listings.py at all"
    fi
    rm -f /tmp/lambwell_pathcheck.py
fi

# The browser is the one dependency that cannot be pre-baked, and provisioning
# now records whether the LEARNER (not root) could actually launch one. On a
# provisioned VM that verdict is the difference between "wrote a wrong harvest"
# and "was never given a browser".
row "provisioning gave the learner a working browser"
DEPS_STATE_FILE="/var/log/lambwell-lab/deps.state"
if [ ! -f "$DEPS_STATE_FILE" ]; then
    note "VACUOUS on this host (no ${DEPS_STATE_FILE}) - run this on the VM"
elif grep -q 'browser-verified' "$DEPS_STATE_FILE" 2>/dev/null; then
    pass "row ${ROWS}: a browser launched as the learner during provisioning"
else
    fail "row ${ROWS}: provisioning never verified a browser for the learner - $(tr '\n' ' ' < "$DEPS_STATE_FILE")"
fi

row "starters untouched, nothing run"
assemble 0; reset_site
S="$(grade)"
[ "$S" = "0" ] && pass "score ${S}/50 as expected" || fail "score ${S}/50, expected 0/50"
check_ownership "row ${ROWS}"

row "written but never run"
assemble 1; reset_site
S="$(grade)"
[ "$S" = "0" ] && pass "score ${S}/50 - no artefacts means nothing to grade" \
              || fail "score ${S}/50, expected 0/50"
check_ownership "row ${ROWS}"

row "only the first two steps run"
assemble 1; reset_site; run_harvest 2
S="$(grade)"
[ "$S" = "20" ] && pass "score ${S}/50 - the two steps that ran are the two that scored" \
               || fail "score ${S}/50, expected 20/50"
check_ownership "row ${ROWS}"
check_learner_can_work "row ${ROWS}"

row "the whole harvest run, then graded"
assemble 1; reset_site; run_harvest
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 as expected" || fail "score ${S}/50, expected 50/50"
check_ownership "row ${ROWS}"
check_learner_can_work "row ${ROWS}"

row "grading killed after three checks (partial run)"
S="$(grade 3)"
[ "$S" = "30" ] && pass "partial score ${S}/50 as expected" || fail "partial score ${S}/50, expected 30/50"
check_ownership "row ${ROWS}"

row "graded a second time on the same VM"
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 on the repeat" || fail "score ${S}/50 on the repeat, expected 50/50"
check_ownership "row ${ROWS}"
check_learner_can_work "row ${ROWS}"

row "the harvest re-run after grading, then graded again"
run_harvest
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 after a re-harvest" || fail "score ${S}/50, expected 50/50"
check_ownership "row ${ROWS}"

echo
echo "================================================================"
echo "rows: ${ROWS}   failures: ${BAD}"
[ "$HAVE_USER" -eq 0 ] && echo "NOTE: ownership rows were vacuous - no user account on this host"
echo "================================================================"
[ "$BAD" -eq 0 ]
