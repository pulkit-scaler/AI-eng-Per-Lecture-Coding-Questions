#!/bin/bash
# Ordering matrix. The happy path passing tells you almost nothing: the failures
# that reach learners come from orderings nobody tried - submitting before
# running anything, a grading run killed half way, a second submission.
#
# Every row asserts the score AND that the learner is not locked out of their
# own project afterwards. The thing to watch here is reports/eval.json:
# a check runs the gate, and the gate WRITES that file. If a check creates it
# first, it is root-owned and every later run of the learner own gate fails.
#
# Run as root on the target VM once before the first cohort. On an authoring
# host with no `user` account the ownership rows self-report as vacuous.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$(cd "$DIR/.." && pwd)"
SCRIPTS="$PACK/test-cases/scripts"
LAB_DIR="${LAB_DIR:-/tmp/norbury-perm}"
DESK_URL="${DESK_URL:-http://127.0.0.1:8879}"
PY="${PY:-python3}"
export LAB_DIR DESK_URL PY
export NORBURY_BASE_URL="$DESK_URL"
export NORBURY_API_KEY="${NORBURY_API_KEY:-nb-dev-perm}"
export DEPS_READY_FILE="${DEPS_READY_FILE:-/tmp/norbury-deps.ready}"
export TIMING_LOG="/tmp/norbury_perm_timing.log"
export DESK_BIN="$PACK/service/flowsvc.py"
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
    NORBURY_PORT="$port" "$PY" "$DESK_BIN" >/tmp/norbury_perm_desk.log 2>&1 &
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
    mkdir -p "$LAB_DIR/flow" "$LAB_DIR/runs"
    cp -R "$PACK/app/flow_kit" "$PACK/app/flows" "$LAB_DIR/"
    cp "$PACK/app/check_local.py" "$LAB_DIR/"
    cp "$PACK/app/flow/__init__.py" "$LAB_DIR/flow/"
    if [ "$1" = "1" ]; then
        cp "$PACK/reference-solution/flow"/*.py "$LAB_DIR/flow/"
        cp "$PACK/reference-solution/flowctl.py" "$LAB_DIR/"
    else
        cp "$PACK/app/flow/spec_stub.py" "$LAB_DIR/flow/spec.py"
        cp "$PACK/app/flow/runtime_stub.py" "$LAB_DIR/flow/runtime.py"
        cp "$PACK/app/flowctl_stub.py" "$LAB_DIR/flowctl.py"
    fi
    # Provisioning pre-creates the run log directory as the learner. Reproduce
    # that here, because it is the thing being tested.
    mkdir -p "$LAB_DIR/runs"
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
    echo "$bad" > /tmp/norbury_perm_unparseable
    echo $((good * 10))
}

check_verdicts() {
    local bad; bad="$(cat /tmp/norbury_perm_unparseable 2>/dev/null || echo 0)"
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

# A check runs the learner command line from inside the project, and that
# command writes a run log. If a check got there first the directory is
# root-owned and the learner cannot write there again.
check_learner_can_work() {
    local rc
    if [ "$HAVE_USER" -eq 1 ]; then
        su - user -c "cd $LAB_DIR && NORBURY_BASE_URL=$DESK_URL NORBURY_API_KEY=$NORBURY_API_KEY PYTHONPATH=$LAB_DIR $PY flowctl.py run flows/research-briefing.json --message 'Research retrieval routing' --session learner-after >/dev/null"
        rc=$?
    else
        ( cd "$LAB_DIR" && NORBURY_BASE_URL="$DESK_URL" PYTHONPATH="$LAB_DIR" \
            "$PY" flowctl.py run flows/research-briefing.json \
            --message "Research retrieval routing" --session learner-after \
            >/dev/null )
        rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        fail "$1: the learner cannot run their own flow afterwards (exit $rc)"
        return
    fi
    if [ ! -s "$LAB_DIR/runs/learner-after.json" ]; then
        fail "$1: the learner run wrote no log"
        return
    fi
    pass "$1: the learner can still run their own flow afterwards"
}

row() { ROWS=$((ROWS + 1)); echo; echo "--- row ${ROWS}: $* ---"; }

start_desk || { echo "the model endpoint would not start"; exit 1; }

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

row "learner ran their own flow first, then graded"
assemble 1
# This row used to invoke `gate.py --pool data/pool_sample.json`, a command line
# from another pack: neither the script nor the pool exists here, output went to
# /dev/null and the exit status was never read, so the row silently degraded into
# a second copy of row 2 and never tested the ordering it names. Run the flow the
# learner actually runs, and refuse to continue if it did not.
if ! ( cd "$LAB_DIR" && NORBURY_BASE_URL="$DESK_URL" \
       NORBURY_API_KEY="$NORBURY_API_KEY" PYTHONPATH="$LAB_DIR" \
       "$PY" flowctl.py run flows/research-briefing.json \
       --message "Research retrieval routing" --session learner-before \
       >/tmp/norbury_perm_learner_first.log 2>&1 ); then
    fail "row ${ROWS}: the learner could not run their own flow before grading; see /tmp/norbury_perm_learner_first.log"
fi
[ -s "$LAB_DIR/runs/learner-before.json" ] \
    || fail "row ${ROWS}: the learner run before grading wrote no log, so this row is not testing the ordering it names"
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

row "run logs deleted between runs"
rm -f "$LAB_DIR/runs"/*.json
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 with the logs written from scratch" \
                || fail "score ${S}/50, expected 50/50"
check_verdicts "row ${ROWS}"
check_ownership "row ${ROWS}"
check_learner_can_work "row ${ROWS}"

row "runs directory removed entirely"
rm -rf "$LAB_DIR/runs"
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 with the directory recreated" \
                || fail "score ${S}/50, expected 50/50"
check_verdicts "row ${ROWS}"
check_ownership "row ${ROWS}"
check_learner_can_work "row ${ROWS}"

echo
echo "================================================================"
echo "rows: ${ROWS}   failures: ${BAD}"
[ "$HAVE_USER" -eq 0 ] && echo "NOTE: ownership rows were vacuous - no user account on this host"
echo "================================================================"
[ "$BAD" -eq 0 ]
