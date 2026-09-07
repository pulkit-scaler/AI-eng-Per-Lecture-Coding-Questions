#!/bin/bash
# Ordering matrix. The happy path passing tells you almost nothing: the failures
# that reach learners come from orderings nobody tried - submitting before
# running anything, a grading run killed half way, a second submission.
#
# Every row asserts the score AND that the learner is not locked out of their
# own project afterwards. The thing to watch here is reports/scorecard.json:
# a check runs the gate, and the gate WRITES that file. If a check creates it
# first, it is root-owned and every later run of the learner own gate fails.
#
# Run as root on the target VM once before the first cohort. On an authoring
# host with no `user` account the ownership rows self-report as vacuous.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$(cd "$DIR/.." && pwd)"
SCRIPTS="$PACK/test-cases/scripts"
LAB_DIR="${LAB_DIR:-/tmp/caverly-perm}"
DESK_URL="${DESK_URL:-http://127.0.0.1:8779}"
PY="${PY:-python3}"
export LAB_DIR DESK_URL PY
export CAVERLY_DESK_URL="$DESK_URL"
export DEPS_READY_FILE="${DEPS_READY_FILE:-/tmp/caverly-deps.ready}"
export TIMING_LOG="/tmp/caverly_perm_timing.log"
export DESK_BIN="$PACK/service/trustsvc.py"
touch "$DEPS_READY_FILE"

HAVE_USER=0
id -u user >/dev/null 2>&1 && HAVE_USER=1
ROWS=0; BAD=0
note() { printf '  %s\n' "$*"; }
fail() { BAD=$((BAD + 1)); printf '  FAIL %s\n' "$*"; }
pass() { printf '  ok   %s\n' "$*"; }

DESK_PID=""
start_desk() {
    curl -sf -m 2 "${DESK_URL}/health" >/dev/null 2>&1 && return 0
    local port; port="$(printf '%s' "$DESK_URL" | sed 's|.*:||; s|/.*||')"
    CAVERLY_PORT="$port" "$PY" "$DESK_BIN" >/tmp/caverly_perm_desk.log 2>&1 &
    DESK_PID=$!
    disown "$DESK_PID" 2>/dev/null || true
    local i
    for i in $(seq 1 20); do
        curl -sf -m 2 "${DESK_URL}/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}
cleanup() { [ -n "$DESK_PID" ] && kill "$DESK_PID" 2>/dev/null; return 0; }
trap cleanup EXIT

assemble() {  # assemble <written:0|1>
    rm -rf "$LAB_DIR"
    mkdir -p "$LAB_DIR/guards" "$LAB_DIR/reports" "$LAB_DIR/campaigns"
    cp -R "$PACK/app/trust_kit" "$LAB_DIR/"
    cp "$PACK/app/check_local.py" "$LAB_DIR/"
    cp "$PACK/app/campaigns/sample.json" "$LAB_DIR/campaigns/"
    cp "$PACK/app/guards/__init__.py" "$LAB_DIR/guards/"
    if [ "$1" = "1" ]; then
        cp "$PACK/reference-solution/guards"/*.py "$LAB_DIR/guards/"
        cp "$PACK/reference-solution/harden.py" "$LAB_DIR/"
    else
        for name in input_rail retrieval_rail tool_rail output_rail; do
            cp "$PACK/app/guards/${name}_stub.py" "$LAB_DIR/guards/${name}.py"
        done
        cp "$PACK/app/harden_stub.py" "$LAB_DIR/harden.py"
    fi
    # Provisioning pre-creates the scorecard as the learner. Reproduce that
    # here, because it is the defence being tested.
    printf '{}\n' > "$LAB_DIR/reports/scorecard.json"
    [ "$HAVE_USER" -eq 1 ] && chown -R user:user "$LAB_DIR" 2>/dev/null
    return 0
}

grade() {  # grade [n-scripts] -> echoes score
    local limit="${1:-5}" n=0 good=0 bad=0 line
    for s in "$SCRIPTS"/script_*.sh; do
        n=$((n + 1))
        [ "$n" -gt "$limit" ] && break
        # The judge grades the LAST line of stdout+stderr. A matrix that greps
        # for a verdict anywhere in the output scores every row green even when
        # a trailing line has voided every one of them on the portal - and a row
        # that only counts successes cannot see it at all, because a voided
        # verdict and an honest failure both score zero. So the shape of the
        # last line is asserted separately from the score.
        line="$(bash "$s" 2>&1 | tail -n 1)"
        case "$line" in
            *'"status"'*'"success"'*) good=$((good + 1)) ;;
            *'"status"'*'"failed"'*)  ;;
            *) bad=$((bad + 1))
               printf '  FAIL %s ended on a non-verdict, so the portal would post\n' "$(basename "$s")" >&2
               printf '       no results at all: %s\n' "$line" >&2 ;;
        esac
    done
    echo "$bad" > /tmp/caverly_perm_unparseable
    echo $((good * 10))
}

check_verdicts() {
    local bad; bad="$(cat /tmp/caverly_perm_unparseable 2>/dev/null || echo 0)"
    [ "${bad:-0}" -eq 0 ] \
        && pass "$1: every check ended on a parseable verdict" \
        || fail "$1: ${bad} check(s) ended on a non-verdict - empty panel on the portal"
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
        find "$LAB_DIR" -user root 2>/dev/null | head -5 | sed 's/^/       /'
    else
        pass "$1: nothing under the project is root-owned"
    fi
}

check_learner_can_work() {
    local rc
    if [ "$HAVE_USER" -eq 1 ]; then
        su - user -c "cd $LAB_DIR && CAVERLY_DESK_URL=$DESK_URL $PY harden.py --attacks campaigns/sample.json --out reports/scorecard.json >/dev/null"
        rc=$?
    else
        ( cd "$LAB_DIR" && CAVERLY_DESK_URL="$DESK_URL" "$PY" harden.py \
            --attacks campaigns/sample.json --out reports/scorecard.json >/dev/null )
        rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        pass "$1: the learner can still run their own gate afterwards"
    else
        fail "$1: the learner cannot rewrite their own scorecard afterwards (exit $rc)"
    fi
}

row() { ROWS=$((ROWS + 1)); echo; echo "--- row ${ROWS}: $* ---"; }

start_desk || { echo "the support desk would not start"; exit 1; }

row "starters untouched"
assemble 0
S="$(grade)"
[ "$S" = "0" ] && pass "score ${S}/50 as expected" || fail "score ${S}/50, expected 0/50"
check_verdicts "row ${ROWS}"
check_ownership "row ${ROWS}"

row "written, never run by the learner"
assemble 1
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 - the checks run the gate themselves" \
                || fail "score ${S}/50, expected 50/50"
check_verdicts "row ${ROWS}"
check_ownership "row ${ROWS}"
check_learner_can_work "row ${ROWS}"

row "learner ran the gate first, then graded"
assemble 1
( cd "$LAB_DIR" && CAVERLY_DESK_URL="$DESK_URL" "$PY" harden.py \
    --attacks campaigns/sample.json --out reports/scorecard.json >/dev/null 2>&1 )
[ "$HAVE_USER" -eq 1 ] && chown -R user:user "$LAB_DIR" 2>/dev/null
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 as expected" || fail "score ${S}/50, expected 50/50"
check_verdicts "row ${ROWS}"
check_ownership "row ${ROWS}"
check_learner_can_work "row ${ROWS}"

row "grading killed after three checks (partial run)"
S="$(grade 3)"
[ "$S" = "30" ] && pass "partial score ${S}/50 as expected" || fail "partial score ${S}/50, expected 30/50"
check_verdicts "row ${ROWS}"
check_ownership "row ${ROWS}"
check_learner_can_work "row ${ROWS}"

row "graded a second time on the same VM"
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 on the repeat" || fail "score ${S}/50 on the repeat, expected 50/50"
check_verdicts "row ${ROWS}"
check_ownership "row ${ROWS}"

row "scorecard deleted between runs"
rm -f "$LAB_DIR/reports/scorecard.json"
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 with the scorecard written from scratch" \
                || fail "score ${S}/50, expected 50/50"
check_verdicts "row ${ROWS}"
check_ownership "row ${ROWS}"
check_learner_can_work "row ${ROWS}"

row "reports directory removed entirely"
rm -rf "$LAB_DIR/reports"
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 with the directory recreated by the gate" \
                || fail "score ${S}/50, expected 50/50"
check_verdicts "row ${ROWS}"
check_ownership "row ${ROWS}"

echo
echo "================================================================"
echo "rows: ${ROWS}   failures: ${BAD}"
[ "$HAVE_USER" -eq 0 ] && echo "NOTE: ownership rows were vacuous - no user account on this host"
echo "================================================================"
[ "$BAD" -eq 0 ]
