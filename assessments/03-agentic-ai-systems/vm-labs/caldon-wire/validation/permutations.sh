#!/bin/bash
# Ordering matrix for the Caldon wire lab. Run AS ROOT on a provisioned VM (or
# in the Linux container built by validation/run-in-docker.sh).
#
# The happy path passing tells you almost nothing: the failures that reach
# learners come from orderings nobody tried. Every row asserts three things -
# the intended score, that nothing under the project ended up owned by root,
# and that the learner can still run their own work afterwards.
#
#   PACK=/pack bash /pack/validation/permutations.sh
set -uo pipefail

PACK="${PACK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LAB_USER="user"
LAB_DIR="/home/${LAB_USER}/caldon-wire"
LOG_DIR="/var/log/caldon-lab"
SCRIPTS="${PACK}/test-cases/scripts"
PY="${PY:-python3}"

ROWS=0
BAD=0

say()  { printf '\n=== %s\n' "$*"; }
check() {
    # check <label> <want> <got>
    if [ "$2" = "$3" ]; then
        printf '    ok    %-34s %s\n' "$1" "$3"
    else
        printf '    FAIL  %-34s want=%s got=%s\n' "$1" "$2" "$3"
        BAD=$((BAD + 1))
    fi
}

wait_for_deps() {
    local i
    for i in $(seq 1 180); do
        [ -f "${LOG_DIR}/deps.ready" ] && return 0
        sleep 1
    done
    return 1
}

reset_vm() {
    # Put the VM back the way the platform hands it over.
    rm -rf "$LAB_DIR"
    bash "${PACK}/setup/scripts/setup_script.sh" >/tmp/perm_setup.log 2>&1
    wait_for_deps || { echo "    (dependency install never finished)"; return 1; }
    return 0
}

write_solution() {
    # write_solution <none|stub|reference>
    case "$1" in
        none)      rm -f "${LAB_DIR}/solution.py" ;;
        stub)      cp "${PACK}/app/solution_stub.py" "${LAB_DIR}/solution.py" ;;
        reference) cp "${PACK}/reference-solution/solution.py" "${LAB_DIR}/solution.py" ;;
    esac
    [ -f "${LAB_DIR}/solution.py" ] && chown "${LAB_USER}:${LAB_USER}" "${LAB_DIR}/solution.py"
    return 0
}

run_as_learner() {
    # The learner exercising their own work before submitting.
    su - "$LAB_USER" -c "cd ${LAB_DIR} && ${PY} check_local.py" \
        >/tmp/perm_learner.log 2>&1
    return $?
}

grade() {
    # grade <full|partial> -> echoes the score
    local glob='script_0[1-5].sh'
    [ "$1" = "partial" ] && glob='script_0[1-3].sh'
    # The judge runs from an unspecified directory with none of the learner
    # environment, so neither is inherited here either.
    ( cd / && unset CALDON_RUN_ID CALDON_BASE_URL PYTHONPATH
      points=0
      for s in ${SCRIPTS}/${glob}; do
          if bash "$s" 2>/dev/null | grep -q '^RESULT:success'; then
              points=$((points + 10))
          fi
      done
      echo "$points" )
}

root_owned() {
    # Scoped to the project: this image ships some root-owned dotfiles in the
    # home directory out of the box, and an unscoped count trains you to ignore
    # a real failure.
    find "$LAB_DIR" -user root 2>/dev/null | wc -l | tr -d ' '
}

learner_can_work() {
    if su - "$LAB_USER" -c "cd ${LAB_DIR} && ${PY} -c 'import solution'" \
        >/tmp/perm_can_work.log 2>&1; then echo yes; else echo no; fi
}

scenario() {
    # scenario <label> <solution> <ran:yes|no> <grading> <expected-score>
    ROWS=$((ROWS + 1))
    say "row ${ROWS}: $1"
    reset_vm || { BAD=$((BAD + 1)); return; }
    write_solution "$2"
    [ "$3" = "yes" ] && run_as_learner
    check "score" "$5" "$(grade "$4")"
    check "root-owned files under project" 0 "$(root_owned)"
    if [ "$2" = "none" ]; then
        check "project still intact" yes \
            "$( [ -d "${LAB_DIR}/wire_kit" ] && echo yes || echo no )"
    else
        check "learner can still run their work" yes "$(learner_can_work)"
    fi
}

say "pack under test: ${PACK}"

scenario "wrote the solution, ran it, full grading" reference yes full 50
scenario "wrote the solution, never ran it, full grading" reference no full 50
scenario "untouched starter, full grading" stub no full 0
scenario "no solution.py at all" none no full 0
scenario "wrote the solution, partial grading (killed after 3)" reference no partial 30

# Repeat grading: same score twice, and the learner is not locked out between
# the two runs. This is the row that catches an ownership bug a single clean
# run hides.
ROWS=$((ROWS + 1))
say "row ${ROWS}: graded twice in a row"
if reset_vm; then
    write_solution reference
    first="$(grade full)"
    mid_root="$(root_owned)"
    mid_work="$(learner_can_work)"
    second="$(grade full)"
    check "first score" 50 "$first"
    check "second score" 50 "$second"
    check "root-owned between runs" 0 "$mid_root"
    check "learner could work between runs" yes "$mid_work"
    check "root-owned after both" 0 "$(root_owned)"
    check "learner can work after both" yes "$(learner_can_work)"
else
    BAD=$((BAD + 1))
fi

# Graded before the learner has done anything, then the learner works and is
# graded again. A check that took ownership on the first pass blocks them here.
ROWS=$((ROWS + 1))
say "row ${ROWS}: graded first, learner works, graded again"
if reset_vm; then
    before="$(grade full)"
    check "score on the untouched starter" 0 "$before"
    write_solution reference
    su - "$LAB_USER" -c "cd ${LAB_DIR} && ${PY} check_local.py" \
        >/tmp/perm_after.log 2>&1
    check "learner could work after being graded" yes \
        "$( grep -q 'pieces in' /tmp/perm_after.log && echo yes || echo no )"
    check "score after they did the work" 50 "$(grade full)"
    check "root-owned at the end" 0 "$(root_owned)"
else
    BAD=$((BAD + 1))
fi

printf '\n----------------------------------------------------------------\n'
if [ "$BAD" -eq 0 ]; then
    echo "permutation matrix clean: ${ROWS} rows, every assertion held"
else
    echo "permutation matrix FAILED: ${BAD} assertion(s) across ${ROWS} rows"
fi
printf -- '----------------------------------------------------------------\n'
exit "$BAD"
