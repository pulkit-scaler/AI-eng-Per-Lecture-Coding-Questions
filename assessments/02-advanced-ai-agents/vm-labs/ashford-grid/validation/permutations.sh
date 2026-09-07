#!/bin/bash
# Permutation matrix for the Ashford grid lab.
#
# The happy path passing tells you almost nothing: the failures that reach learners
# come from orderings nobody tried - submitting before running anything, a grading
# run killed before the last check, a second submission, a learner who works after
# a grading run. Every row asserts three things:
#
#   1. the score the design intends,
#   2. no file under the project is owned by anyone but the learner,
#   3. the learner can still run their own program afterwards.
#
# Assertion 2 is meaningful only where the checks actually run as root, which is
# the VM and not this host; off-VM it is vacuous and is reported as such, and the
# chown-from-the-EXIT-trap that satisfies it is asserted by grep instead.
#
# Usage:  PY=<venv>/bin/python ./validation/permutations.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$(cd "$DIR/.." && pwd)"

PY="${PY:-python3}"
LAB_DIR="${LAB_DIR:-/tmp/ashford-perm}"
PORT="${PORT:-9310}"
SVC_URL="http://127.0.0.1:${PORT}"
POINTS=10
N_CHECKS=5
LAST_PARTIAL=3
FAILURES=0

export PY LAB_DIR SVC_URL
export ASHFORD_PORT="$PORT"
export ASHFORD_BASE_URL="${SVC_URL}/v1"
export ASHFORD_AUDIT_URL="${SVC_URL}/v1/audit/query"
export ASHFORD_DB="${LAB_DIR}/data/grid_ops.db"
export SVC_BIN="${PACK}/service/gridd.py"

PARTIAL_SOLUTION="/tmp/ashford-perm-partial.py"
BROKEN_SOLUTION="/tmp/ashford-perm-broken.py"

# A learner who finished Tasks 1 and 2 and has not started 3, 4 and 5.
"$PY" - "$PACK" "$PARTIAL_SOLUTION" <<'PY'
import pathlib
import re
import sys

pack, out = sys.argv[1], sys.argv[2]
text = pathlib.Path(pack, "reference-solution", "solution.py").read_text()
for name, args in (("execute_with_feedback", "question: str, max_attempts: int"),
                   ("route_request", "request: str"),
                   ("parallel_guards", "candidate_sql: str")):
    pattern = re.compile(r"\ndef %s\(%s\)[^\n]*\n(?:.*?)(?=\n\n\n|\Z)"
                         % (name, re.escape(args)), re.S)
    replacement = ('\ndef %s(%s):\n'
                   '    raise NotImplementedError("not started yet")\n'
                   % (name, args))
    text, count = pattern.subn(replacement, text)
    assert count == 1, name
pathlib.Path(out).write_text(text)
PY
# A learner whose first attempt does not even import.
printf 'import nonexistent_module_xyz\n' > "$BROKEN_SOLUTION"

reset_lab() {   # put the project back exactly as provisioning hands it over
    rm -rf "$LAB_DIR" "${LAB_DIR}-logs"
    mkdir -p "$LAB_DIR/data"
    cp -R "$PACK/app/grid_kit" "$LAB_DIR/"
    cp "$PACK/app/check_local.py" "$LAB_DIR/"
    cp "$PACK/app/solution_stub.py" "$LAB_DIR/solution.py"
    "$PY" "$PACK/service/seed_db.py" "$ASHFORD_DB" >/dev/null 2>&1
}

write_solution() {   # reference | partial | stub | none | broken
    case "$1" in
    reference) cp "$PACK/reference-solution/solution.py" "$LAB_DIR/solution.py" ;;
    partial)   cp "$PARTIAL_SOLUTION" "$LAB_DIR/solution.py" ;;
    broken)    cp "$BROKEN_SOLUTION" "$LAB_DIR/solution.py" ;;
    stub)      : ;;
    none)      rm -f "$LAB_DIR/solution.py" ;;
    esac
}

learner_ran() {   # yes | no
    [ "$1" = yes ] || return 0
    ( cd "$LAB_DIR" && PYTHONPATH="$LAB_DIR" "$PY" check_local.py ) >/dev/null 2>&1
    return 0
}

# VOIDED counts checks whose LAST line was not a parseable verdict. On the portal
# such a check reports no test case results at all, so it has to be visible here
# rather than folded into a score.
VOIDED=0

grade() {   # full | partial -> echoes the score
    local hi="$N_CHECKS"
    [ "$1" = partial ] && hi="$LAST_PARTIAL"
    local voidfile="/tmp/ashford_perm_voided.$$"
    : > "$voidfile"
    # cd / on purpose: the judge working directory is NOT the project.
    ( cd / && p=0
      for i in $(seq 1 "$hi"); do
          s="$(printf '%s/test-cases/scripts/script_%02d.sh' "$PACK" "$i")"
          [ -f "$s" ] || { echo "MISSING $s" >&2; continue; }
          # Grade exactly what the platform grades: the LAST line of stdout plus
          # stderr, parsed as JSON. Capture first, then match: grep -q on a live
          # pipe exits early, SIGPIPEs the producer, and pipefail then turns a
          # correct run into a failed one.
          out="$(bash "$s" 2>&1)"
          last="$(printf '%s\n' "$out" | tail -n 1)"
          st="$(printf '%s' "$last" | jq -r '.status // "UNPARSEABLE"' 2>/dev/null || echo UNPARSEABLE)"
          case "$st" in
              UNPARSEABLE)
                  case "$last" in
                      RESULT:success*) st=success ;;
                      RESULT:failed*)  st=failed ;;
                      *) printf 'script_%02d\n' "$i" >> "$voidfile" ;;
                  esac ;;
          esac
          [ "$st" = success ] && p=$((p + 1))
      done
      echo $((p * POINTS)) )
    VOIDED=$(grep -c . "$voidfile" 2>/dev/null || true); VOIDED="${VOIDED:-0}"
    rm -f "$voidfile"
}

foreign_files() {
    # Anything under the project not owned by the account that will run the
    # learner code. On the VM the checks run as root and this is the assertion
    # that catches an ownership bug; here it can only ever be 0.
    find "$LAB_DIR" ! -user "$(id -un)" 2>/dev/null | wc -l | tr -d ' '
}

learner_can_work() {
    ( cd "$LAB_DIR" && PYTHONPATH="$LAB_DIR" "$PY" check_local.py ) >/tmp/ashford_can_work.log 2>&1 \
        && echo yes \
        || echo "no ($(grep -oiE 'permission denied|readonly|EACCES|not permitted' /tmp/ashford_can_work.log | head -1))"
}

check() {
    if [ "$2" = "$3" ]; then
        printf '    ok    %-38s %s\n' "$1" "$3"
    else
        printf '    FAIL  %-38s expected %s, got %s\n' "$1" "$2" "$3"
        FAILURES=$((FAILURES + 1))
    fi
}

svc_pid=""
start_endpoint() {
    curl -sf -m 2 "${SVC_URL}/health" >/dev/null 2>&1 && return 0
    ASHFORD_PORT="$PORT" ASHFORD_DB="$ASHFORD_DB" "$PY" "$SVC_BIN" \
        >"/tmp/ashford_perm_svc.log" 2>&1 &
    svc_pid=$!
    local i
    for i in $(seq 1 30); do
        curl -sf -m 2 "${SVC_URL}/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}
cleanup() { [ -n "$svc_pid" ] && kill "$svc_pid" 2>/dev/null; return 0; }
trap cleanup EXIT

scenario() {   # label written ran grading expected_score
    echo ""
    echo "### $1"
    reset_lab
    write_solution "$2"
    learner_ran "$3"
    check "score" "$5" "$(grade "$4")"
    check "checks with a voided verdict" "0" "$VOIDED"
    check "files not owned by the learner" "0" "$(foreign_files)"
    case "$2" in
    reference|partial) check "learner can still work" "yes" "$(learner_can_work)" ;;
    esac
}

echo "=================================================================="
echo " Ashford grid lab - permutations of (written) x (ran) x (grading)"
echo "=================================================================="
reset_lab
start_endpoint || { echo "ERROR: the model endpoint never came up"; exit 1; }
echo "endpoint healthy on ${SVC_URL}"

echo ""
echo "### the ownership guard is present in every check (this is what row 2 rides on)"
missing=0
judge_missing=0
for s in "$PACK"/test-cases/scripts/script_0[1-5].sh; do
    grep -q 'trap on_exit EXIT' "$s" || missing=$((missing + 1))
    grep -q 'chown -R user:user' "$s" || missing=$((missing + 1))
    grep -q 'PYTHONDONTWRITEBYTECODE=1' "$s" || missing=$((missing + 1))
    # The ownership repair has to fire wherever a lab user exists, not only where
    # LAB_DIR happens to point under /home/user - which is why this row was
    # meaningless before: every local harness runs with LAB_DIR=/tmp/...
    grep -q 'id -u user' "$s" || missing=$((missing + 1))
    grep -q '^trap - ERR$' "$s" || judge_missing=$((judge_missing + 1))
    grep -q '^set +eE$' "$s"    || judge_missing=$((judge_missing + 1))
    grep -q 'exec 2>>' "$s"     || judge_missing=$((judge_missing + 1))
done
check "checks missing an ownership guard" "0" "$missing"
check "checks missing a judge-fidelity guard" "0" "$judge_missing"

# The checks execute the learner program themselves, so a learner who never ran it
# is not penalised - that is the intended design and row 2 pins it down.
scenario "wrote the solution, ran it first, graded"   reference yes full    50
scenario "wrote the solution, ran NOTHING, graded"    reference no  full    50
scenario "wrote NOTHING (untouched starter), graded"  stub      no  full     0
scenario "no solution.py at all, graded"              none      no  full     0
scenario "finished Tasks 1 and 2 only, graded"        partial   no  full    20
scenario "a solution that does not import, graded"    broken    no  full     0
scenario "PARTIAL grading (killed after check 3)"     reference yes partial 30

echo ""
echo "### graded TWICE (a repeat submission)"
reset_lab; write_solution reference
first="$(grade full)"; v1="$VOIDED"; second="$(grade full)"
check "first submission" "50" "$first"
check "voided verdicts on the first submission" "0" "$v1"
check "second submission" "50" "$second"
check "voided verdicts on the second submission" "0" "$VOIDED"
check "files not owned by the learner" "0" "$(foreign_files)"
check "learner can still work" "yes" "$(learner_can_work)"

echo ""
echo "### graded FIRST, learner then worked, graded again"
reset_lab; write_solution reference
check "score before the learner ran anything" "50" "$(grade full)"
check "learner can work after grading" "yes" "$(learner_can_work)"
check "score after the learner ran it" "50" "$(grade full)"

echo ""
echo "### a broken first attempt replaced by a good one"
reset_lab; write_solution broken
learner_ran yes
write_solution reference
check "score with the broken attempt behind it" "50" "$(grade full)"

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo " PERMUTATIONS PASSED - every ordering scores as intended and none locks the learner out."
else
    echo " PERMUTATIONS FAILED - ${FAILURES} assertion(s) broke."
fi
rm -f "$PARTIAL_SOLUTION" "$BROKEN_SOLUTION"
exit "$FAILURES"
