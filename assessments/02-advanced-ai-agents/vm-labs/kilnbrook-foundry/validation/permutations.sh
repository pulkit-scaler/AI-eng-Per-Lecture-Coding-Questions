#!/bin/bash
# Ordering matrix for the Kilnbrook Foundry lab.
#
# Every scenario asserts BOTH halves of the contract:
#   1. the score the design intends, and
#   2. the learner can still run their own program afterwards - grading never
#      bricks the VM, and nothing under the project is left owned by root.
#
# Runs the REAL generated setup script inside the image family the portal uses
# (Ubuntu 25.04, Python 3.13, no pip, PEP 668), so the ownership and dependency
# behaviour observed here is the behaviour a learner gets.
#
# Usage:  ./validation/permutations.sh
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$(cd "$DIR/.." && pwd)"

IMAGE="${IMAGE:-ubuntu:25.04}"
LAB_DIR_="/home/user/kilnbrook-foundry"
POINTS=10
N_CHECKS=5
LAST_PARTIAL=3

if [ "${LAB_INSIDE:-0}" != "1" ]; then
    exec docker run --rm -v "$PACK:/pack:ro" -e LAB_INSIDE=1 "$IMAGE" \
        bash /pack/validation/permutations.sh
fi

export DEBIAN_FRONTEND=noninteractive
FAILURES=0

echo "== image =="
head -2 /etc/os-release
python3 -V 2>&1 || echo "no python3 yet"

wait_for_deps() {
    local i
    for i in $(seq 1 180); do
        [ -f /var/log/kilnbrook-lab/deps.ready ] && return 0
        sleep 1
    done
    return 1
}

reset_vm() {
    pkill -f foundryd.py >/dev/null 2>&1
    rm -rf "$LAB_DIR_" /var/log/kilnbrook-lab /opt/kilnbrook-svc
    bash /pack/setup/scripts/setup_script.sh >/tmp/setup_run.log 2>&1
    wait_for_deps || echo "    (warning: dependency install never published its marker)"
}

write_solution() {   # ref | none
    case "$1" in
    ref)  install -o user -g user -m 644 \
              /pack/reference-solution/solution.py "$LAB_DIR_/solution.py" ;;
    none) : ;;
    esac
}

run_as_learner() {   # good | broken | none
    case "$1" in
    good)   su - user -c "cd $LAB_DIR_ && python3 check_local.py" >/dev/null 2>&1 ;;
    broken) su - user -c "cd $LAB_DIR_ && python3 -c 'import solution; solution.execute_sql()'" \
                >/dev/null 2>&1 ;;
    none)   : ;;
    esac
}

# Grade the way the platform does: the LAST line of stdout+stderr, parsed as JSON,
# and stop at the first check that does not report success. main.sh breaks out of
# its loop there, so partial credit on the portal is a PREFIX of the five checks,
# never a per-theme sum.
grade() {   # full | partial -> echoes the score
    local hi="$N_CHECKS"; [ "$1" = partial ] && hi="$LAST_PARTIAL"
    # cd / on purpose: the judge working directory is NOT the project.
    ( cd / && p=0
      for i in $(seq 1 "$hi"); do
          s="$(printf '/pack/test-cases/scripts/script_%02d.sh' "$i")"
          [ -f "$s" ] || { echo "MISSING $s" >&2; continue; }
          out="$(bash "$s" 2>&1)"
          last="$(printf '%s\n' "$out" | tail -n 1)"
          st="$(jq -r '.status' 2>/dev/null <<<"$last")"
          case "$st" in
              success) ;;
              *) case "$last" in
                     RESULT:success*) st=success ;;
                     *) st=failed ;;
                 esac ;;
          esac
          [ "$st" = success ] || break
          p=$((p + 1))
      done
      echo $((p * POINTS)) )
}

learner_can_work() {
    su - user -c "cd $LAB_DIR_ && python3 check_local.py" >/tmp/can_work.log 2>&1 \
        && echo yes \
        || echo "no ($(grep -oiE 'permission denied|readonly database|EACCES|not permitted|Errno 13' /tmp/can_work.log | head -1))"
}

check() {
    if [ "$2" = "$3" ]; then printf '    ok    %-38s %s\n' "$1" "$3"
    else printf '    FAIL  %-38s expected %s, got %s\n' "$1" "$2" "$3"
         FAILURES=$((FAILURES + 1)); fi
}

invariants() {
    check "no root-owned file in the project" "0" \
        "$(find "$LAB_DIR_" -user root 2>/dev/null | wc -l | tr -d ' ')"
    check "database owner" "user" \
        "$(stat -c '%U' "$LAB_DIR_/data/foundry.db" 2>/dev/null || echo MISSING)"
    check "data directory owner" "user" \
        "$(stat -c '%U' "$LAB_DIR_/data" 2>/dev/null || echo MISSING)"
}

scenario() {   # label written ran grading expected_score
    echo ""; echo "### $1"
    reset_vm; write_solution "$2"; run_as_learner "$3"
    check "score" "$5" "$(grade "$4")"
    invariants
    [ "$2" = ref ] && check "learner can still work" "yes" "$(learner_can_work)"
    return 0
}

echo "=================================================================="
echo " Permutations of (written) x (run) x (grading)"
echo "=================================================================="
# Expected scores are derived from this pack: every check runs the learner code
# itself, so no row depends on the learner having run anything first. What the
# "ran" dimension proves here is that a learner run before grading, and a broken
# earlier attempt, leave nothing behind that changes a verdict.
scenario "wrote solution, ran it, then graded"     ref  good   full    50
scenario "wrote solution, ran NOTHING, graded"     ref  none   full    50
scenario "wrote NOTHING, then graded"              none none   full     0
scenario "ran it, PARTIAL grading (killed early)"  ref  good   partial 30
scenario "broken attempt first, then a good run"   ref  broken full    50

echo ""
echo "### ran it, graded TWICE (repeat submission)"
reset_vm; write_solution ref; run_as_learner good
check "first submission"  "50" "$(grade full)"
check "second submission" "50" "$(grade full)"
invariants
check "learner can still work" "yes" "$(learner_can_work)"

echo ""
echo "### graded FIRST, learner then worked, graded again"
reset_vm; write_solution ref
check "score before running anything" "50" "$(grade full)"
check "learner can work after grading" "yes" "$(learner_can_work)"
run_as_learner good
check "score after running it" "50" "$(grade full)"
invariants

echo ""
echo "### the starter alone must refuse quickly, not hang"
reset_vm
# jq is what grade() parses the verdict with, and the setup foreground now installs
# it. If it is missing here the matrix would score every row 0 for the wrong reason.
command -v jq >/dev/null 2>&1 || echo "    FAIL  jq is not installed after setup"
T0=$SECONDS
S="$(grade full)"
check "starter score" "0" "$S"
printf '    info  five checks against the starter took %ss\n' "$((SECONDS - T0))"
invariants

echo ""
if [ "$FAILURES" -eq 0 ]; then
    echo " PERMUTATIONS PASSED - every ordering scores as intended and none locks the learner out."
else
    echo " PERMUTATIONS FAILED - ${FAILURES} assertion(s) broke."
fi
exit "$FAILURES"
