#!/bin/bash
# Ordering matrix. The happy path passing tells you almost nothing: the failures
# that reach learners come from orderings nobody tried - submitting before
# running anything, a grading run killed half way, a second submission.
#
# Every row asserts the score AND that the learner is not locked out of their
# own project afterwards. Two things to watch here: a run writes into out/ as
# root, and the mill database must come out of grading byte for byte unchanged.
#
# Run as root on the target VM once before the first cohort. On an authoring
# host with no `user` account the ownership rows self-report as vacuous.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$(cd "$DIR/.." && pwd)"
SCRIPTS="$PACK/test-cases/scripts"
LAB_DIR="${LAB_DIR:-/tmp/thistledown-perm}"
MODEL_URL="${MODEL_URL:-http://127.0.0.1:8479}"
PY="${PY:-python3}"
export LAB_DIR MODEL_URL PY
export WESTMERE_MODEL_URL="$MODEL_URL"
export DEPS_READY_FILE="${DEPS_READY_FILE:-/tmp/thistledown-deps.ready}"
export TIMING_LOG="/tmp/thistledown_perm_timing.log"
export MODEL_BIN="$PACK/service/millsvc.py"
touch "$DEPS_READY_FILE"

HAVE_USER=0
id -u user >/dev/null 2>&1 && HAVE_USER=1
ROWS=0; BAD=0
note() { printf '  %s\n' "$*"; }
fail() { BAD=$((BAD + 1)); printf '  FAIL %s\n' "$*"; }
pass() { printf '  ok   %s\n' "$*"; }

MODEL_PID=""
start_model() {
    curl -sf -m 2 "${MODEL_URL}/health" >/dev/null 2>&1 && return 0
    local port; port="$(printf '%s' "$MODEL_URL" | sed 's|.*:||; s|/.*||')"
    THISTLEDOWN_PORT="$port"  \
        "$PY" "$MODEL_BIN" >/tmp/thistledown_perm_model.log 2>&1 &
    MODEL_PID=$!
    disown "$MODEL_PID" 2>/dev/null || true
    local i
    for i in $(seq 1 20); do
        curl -sf -m 2 "${MODEL_URL}/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}
cleanup() { [ -n "$MODEL_PID" ] && kill "$MODEL_PID" 2>/dev/null; return 0; }
trap cleanup EXIT

assemble() {  # assemble <written:0|1>
    rm -rf "$LAB_DIR"
    mkdir -p "$LAB_DIR/data" "$LAB_DIR/out" "$LAB_DIR/config"
    cp -R "$PACK/app/mill" "$LAB_DIR/"
    rm -f "$LAB_DIR/mill/tools_stub.py" "$LAB_DIR/mill/crew_stub.py"
    cp "$PACK/app/check_local.py" "$LAB_DIR/"
    cp "$PACK/app/data/orders.json" "$LAB_DIR/data/"
    "$PY" "$PACK/app/build_db.py" "$LAB_DIR/data/mill.db" >/dev/null
    if [ "$1" = "1" ]; then
        cp "$PACK/reference-solution/tools.py" "$LAB_DIR/mill/tools.py"
        cp "$PACK/reference-solution/crew.py" "$LAB_DIR/mill/crew.py"
        cp "$PACK/reference-solution/config/agents.yaml" "$LAB_DIR/config/"
        cp "$PACK/reference-solution/config/tasks.yaml" "$LAB_DIR/config/"
    elif [ "$1" = "partial" ]; then
        # Reported from a real submission (2026-08-26): crew.py and agents.yaml
        # written, tools.py and tasks.yaml still the starters. This has to score
        # 0 AND say which two files were never written - before the fix it
        # reached the tool probe and answered "stock_lookup and run_query and
        # run_query and run_query and run_query and run_query is not written yet".
        cp "$PACK/app/mill/tools_stub.py" "$LAB_DIR/mill/tools.py"
        cp "$PACK/reference-solution/crew.py" "$LAB_DIR/mill/crew.py"
        cp "$PACK/reference-solution/config/agents.yaml" "$LAB_DIR/config/"
        cp "$PACK/app/config/tasks.yaml" "$LAB_DIR/config/"
    else
        cp "$PACK/app/mill/tools_stub.py" "$LAB_DIR/mill/tools.py"
        cp "$PACK/app/mill/crew_stub.py" "$LAB_DIR/mill/crew.py"
        cp "$PACK/app/config/agents.yaml" "$LAB_DIR/config/"
        cp "$PACK/app/config/tasks.yaml" "$LAB_DIR/config/"
    fi
    # Provisioning marks the crewai first-run question answered, as the learner.
    # Reproduce that here or every run stalls for twenty seconds.
    for base in "$HOME/.local/share" "$HOME/Library/Application Support"; do
        [ -d "$base" ] || continue
        mkdir -p "$base/$(basename "$LAB_DIR")"
        printf '{"first_execution_done": true}' \
            > "$base/$(basename "$LAB_DIR")/.crewai_user.json"
    done
    [ "$HAVE_USER" -eq 1 ] && chown -R user:user "$LAB_DIR" 2>/dev/null
    return 0
}

# Grade exactly what the platform grades: the LAST line of stdout+stderr, as
# JSON. Greping for '^RESULT:success' was wrong - that is the fallback stub's
# format, which only fires when the judge helper is absent. With common.sh in
# place (the faithful replica) the checks emit {"status": ...} and the grep
# matched nothing, so every row scored 0 and only the row that expects 0 was
# ever satisfied. Same parser as run-all.sh, so the two cannot disagree.
verdict_of() {  # verdict_of <script> -> "<status>|<message>"
    local out line st msg
    out="$(bash "$1" 2>&1)"
    line="$(printf '%s\n' "$out" | tail -n 1)"
    st="$(printf '%s' "$line" | jq -r '.status // empty' 2>/dev/null)"
    msg="$(printf '%s' "$line" | jq -r '.message // empty' 2>/dev/null)"
    if [ -z "$st" ]; then
        # The RESULT: fallback, for a host with no judge helper at all.
        case "$line" in
            RESULT:*) st="${line#RESULT:}"; st="${st%% *}"; msg="${line#*| }" ;;
            *)        st="UNPARSEABLE"; msg="last line is not a verdict: ${line}" ;;
        esac
    fi
    printf '%s|%s\n' "$st" "$msg"
}

verdicts() {  # echoes every check's verdict, one per line
    local s
    for s in "$SCRIPTS"/script_*.sh; do verdict_of "$s"; done
}

grade() {  # grade [n-scripts] -> echoes score
    local limit="${1:-5}" n=0 good=0
    for s in "$SCRIPTS"/script_*.sh; do
        n=$((n + 1))
        [ "$n" -gt "$limit" ] && break
        case "$(verdict_of "$s")" in
            success\|*) good=$((good + 1)) ;;
        esac
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
        find "$LAB_DIR" -user root 2>/dev/null | head -5 | sed 's/^/       /'
    else
        pass "$1: nothing under the project is root-owned"
    fi
}

check_learner_can_work() {
    local rc
    if [ "$HAVE_USER" -eq 1 ]; then
        su - user -c "cd $LAB_DIR && THISTLEDOWN_MODEL_URL=${MODEL_URL}/v1 $PY -m mill.main --order TM-4390 >/dev/null"
        rc=$?
    else
        ( cd "$LAB_DIR" && THISTLEDOWN_MODEL_URL="${MODEL_URL}/v1" \
            "$PY" -m mill.main --order TM-4390 >/dev/null 2>&1 )
        rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        pass "$1: the learner can still run their own crew afterwards"
    else
        fail "$1: the learner cannot run their own crew afterwards (exit $rc)"
    fi
}

row() { ROWS=$((ROWS + 1)); echo; echo "--- row ${ROWS}: $* ---"; }

start_model || { echo "the planning model would not start"; exit 1; }

row "starters untouched"
assemble 0
S="$(grade)"
[ "$S" = "0" ] && pass "score ${S}/50 as expected" || fail "score ${S}/50, expected 0/50"
check_ownership "row ${ROWS}"

row "partially written: crew.py and agents.yaml only, then submitted"
assemble partial
V="$(verdicts)"
S="$(printf '%s\n' "$V" | grep -c '^success|')"
[ "$S" = "0" ] && pass "score 0/50 as expected" || fail "${S} check(s) passed, expected 0"
if printf '%s' "$V" | grep -q 'mill/tools.py' && printf '%s' "$V" | grep -q 'config/tasks.yaml'; then
    pass "the verdict names both files the learner never wrote"
else
    fail "the verdict does not name mill/tools.py and config/tasks.yaml: $(printf '%s' "$V" | head -1)"
fi
if printf '%s' "$V" | grep -qE 'run_query and run_query|stock_lookup and run_query and run_query'; then
    fail "a verdict still repeats a tool name: $(printf '%s' "$V" | head -1)"
else
    pass "no verdict repeats a tool name"
fi
check_ownership "row ${ROWS}"

row "written, never run by the learner"
assemble 1
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 - the checks run the crew themselves" \
                || fail "score ${S}/50, expected 50/50"
check_ownership "row ${ROWS}"
check_learner_can_work "row ${ROWS}"

row "learner ran it first, then graded"
assemble 1
( cd "$LAB_DIR" && THISTLEDOWN_MODEL_URL="${MODEL_URL}/v1" "$PY" -m mill.main \
    --order TM-4390 >/dev/null 2>&1 )
[ "$HAVE_USER" -eq 1 ] && chown -R user:user "$LAB_DIR" 2>/dev/null
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 as expected" || fail "score ${S}/50, expected 50/50"
check_ownership "row ${ROWS}"
check_learner_can_work "row ${ROWS}"

row "grading killed after three checks (partial run)"
S="$(grade 3)"
[ "$S" = "30" ] && pass "partial score ${S}/50 as expected" || fail "partial score ${S}/50, expected 30/50"
check_ownership "row ${ROWS}"
check_learner_can_work "row ${ROWS}"

row "graded a second time on the same VM"
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 on the repeat" || fail "score ${S}/50 on the repeat, expected 50/50"
check_ownership "row ${ROWS}"

row "the database is untouched by grading"
BEFORE="$(sha256sum "$LAB_DIR/data/mill.db" | cut -d" " -f1)"
S="$(grade)"
AFTER="$(sha256sum "$LAB_DIR/data/mill.db" | cut -d" " -f1)"
[ "$S" = "50" ] && pass "score ${S}/50 on the third pass" || fail "score ${S}/50, expected 50/50"
[ "$BEFORE" = "$AFTER" ] && pass "the mill database is byte for byte unchanged" \
                        || fail "grading changed the mill database"
check_ownership "row ${ROWS}"
check_learner_can_work "row ${ROWS}"

echo
echo "================================================================"
echo "rows: ${ROWS}   failures: ${BAD}"
[ "$HAVE_USER" -eq 0 ] && echo "NOTE: ownership rows were vacuous - no user account on this host"
echo "================================================================"
[ "$BAD" -eq 0 ]
