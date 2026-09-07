#!/bin/bash
# Ordering matrix. The happy path passing tells you almost nothing: the failures
# that reach learners come from orderings nobody tried - submitting before
# building anything, a grading run killed half way, a second submission.
#
# Every row asserts the score AND that the learner is not locked out of their
# own project afterwards.
#
# Run as root on the target VM once before the first cohort. On an authoring
# host with no `user` account the ownership assertions self-report as vacuous
# rather than passing silently.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$(cd "$DIR/.." && pwd)"
SCRIPTS="$PACK/test-cases/scripts"
# The same directory run-all.sh uses, on purpose: the checks find containers by
# their compose service label, and two projects up at once on one daemon would
# have them grading the wrong stack. A real VM only ever has one.
LAB_DIR="${LAB_DIR:-/tmp/marlow-lab-ref}"
export LAB_DIR
export DOCKER_BUILDKIT=0 COMPOSE_DOCKER_CLI_BUILD=0
export IMAGES_READY="${IMAGES_READY:-/tmp/marlow-images.ready}"
export TIMING_LOG="/tmp/marlow_perm_timing.log"

HAVE_USER=0
id -u user >/dev/null 2>&1 && HAVE_USER=1
ROWS=0; BAD=0
note() { printf '  %s\n' "$*"; }
fail() { BAD=$((BAD + 1)); printf '  FAIL %s\n' "$*"; }
pass() { printf '  ok   %s\n' "$*"; }

assemble() {  # assemble <written:0|1>
    ( cd "$LAB_DIR" 2>/dev/null && docker compose down -v --remove-orphans >/dev/null 2>&1 )
    rm -rf "$LAB_DIR"
    mkdir -p "$LAB_DIR/depot-api" "$LAB_DIR/dist"
    cp -R "$PACK/app/depot-api/." "$LAB_DIR/depot-api/"
    mv "$LAB_DIR/depot-api/env.provided" "$LAB_DIR/depot-api/.env"
    cp "$PACK/app/README.md" "$LAB_DIR/README.md"
    mkdir -p "$LAB_DIR/depot-api/local_index" "$LAB_DIR/depot-api/.venv"
    printf 'token,part_no\ntok,PN-1042\n' > "$LAB_DIR/depot-api/local_index/tokens_index.csv"
    printf 'home = /usr/local/bin\n' > "$LAB_DIR/depot-api/.venv/pyvenv.cfg"
    if [ "$1" = "1" ]; then
        cp "$PACK/reference-solution/Dockerfile" "$LAB_DIR/depot-api/Dockerfile"
        cp "$PACK/reference-solution/dockerignore" "$LAB_DIR/depot-api/.dockerignore"
        cp "$PACK/reference-solution/docker-compose.yml" "$LAB_DIR/docker-compose.yml"
        cp "$PACK/reference-solution/ship.sh" "$LAB_DIR/ship.sh"
        chmod +x "$LAB_DIR/ship.sh"
    fi
    [ "$HAVE_USER" -eq 1 ] && chown -R user:user "$LAB_DIR" 2>/dev/null
    return 0
}

build_and_up() {
    ( cd "$LAB_DIR" && docker compose up -d --build ) >/tmp/marlow_perm_up.log 2>&1
    local i
    for i in $(seq 1 25); do
        curl -sf -m 2 http://127.0.0.1:8000/health >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

grade() {  # grade [n-scripts]  -> echoes score
    local limit="${1:-5}" n=0 pass=0
    for s in "$SCRIPTS"/script_*.sh; do
        n=$((n + 1))
        [ "$n" -gt "$limit" ] && break
        if bash "$s" 2>&1 | grep -q '^RESULT:success'; then
            pass=$((pass + 1))
        fi
    done
    echo $((pass * 10))
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
        su - user -c "cd $LAB_DIR && docker compose ps >/dev/null 2>&1 && bash ship.sh >/dev/null 2>&1"
        rc=$?
    else
        ( cd "$LAB_DIR" && docker compose ps >/dev/null 2>&1 && bash ship.sh >/dev/null 2>&1 )
        rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
        pass "$1: the learner can still drive their own stack afterwards"
    else
        fail "$1: the learner cannot run their own workflow afterwards (exit $rc)"
    fi
}

row() { ROWS=$((ROWS + 1)); echo; echo "--- row ${ROWS}: $* ---"; }

row "nothing written yet"
assemble 0
# On a VM the image exists only if the learner built it. On an authoring host it
# may be left over from an earlier run, which would make this row vacuous.
docker rmi -f marlow-depot/depot-api:latest marlow-depot/depot-api:1.0 >/dev/null 2>&1
S="$(grade)"
[ "$S" = "0" ] && pass "score ${S}/50 as expected" || fail "score ${S}/50, expected 0/50"
check_ownership "row ${ROWS}"

row "files written, never built"
assemble 1
docker rmi -f marlow-depot/depot-api:latest marlow-depot/depot-api:1.0 >/dev/null 2>&1
S="$(grade)"
[ "$S" = "0" ] && pass "score ${S}/50 as expected" || fail "score ${S}/50, expected 0/50"
check_ownership "row ${ROWS}"

row "built and running (happy path)"
assemble 1
build_and_up || fail "the reference stack did not come up"
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 as expected" || fail "score ${S}/50, expected 50/50"
check_ownership "row ${ROWS}"
check_learner_can_work "row ${ROWS}"

row "grading killed after two checks (partial run)"
S="$(grade 2)"
[ "$S" = "20" ] && pass "partial score ${S}/50 as expected" || fail "partial score ${S}/50, expected 20/50"
check_ownership "row ${ROWS}"
check_learner_can_work "row ${ROWS}"

row "graded a second time, same VM"
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 on the repeat" || fail "score ${S}/50 on the repeat, expected 50/50"
check_ownership "row ${ROWS}"

row "stack stopped but image built"
( cd "$LAB_DIR" && docker compose down --remove-orphans >/dev/null 2>&1 )
S="$(grade)"
[ "$S" = "50" ] && pass "score ${S}/50 after the checks restarted it" || fail "score ${S}/50, expected 50/50"
check_ownership "row ${ROWS}"
check_learner_can_work "row ${ROWS}"

row "version file left as the learner had it"
V="$(cat "$LAB_DIR/depot-api/version.txt" 2>/dev/null)"
[ "$V" = "1.0.0" ] && pass "version.txt is back to ${V}" || fail "version.txt is ${V}, expected 1.0.0"
check_ownership "row ${ROWS}"

echo
echo "================================================================"
echo "rows: ${ROWS}   failures: ${BAD}"
[ "$HAVE_USER" -eq 0 ] && echo "NOTE: ownership rows were vacuous - no user account on this host"
echo "================================================================"
( cd "$LAB_DIR" 2>/dev/null && docker compose down -v --remove-orphans >/dev/null 2>&1 )
[ "$BAD" -eq 0 ]
