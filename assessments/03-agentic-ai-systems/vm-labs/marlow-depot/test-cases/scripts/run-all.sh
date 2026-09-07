#!/bin/bash
# LOCAL validation harness. NEVER shipped in TestCase.zip.
#
# Assembles a scratch project from app/ plus one candidate answer, plays the
# part of a learner who brought their own stack up, then runs script_01..05 in
# order and tallies the score.
#
#   ./run-all.sh                                     # grade the reference
#   CAND=reference-solution/alt1-purge ./run-all.sh   # grade an alternative
#   CAND=reference-solution/_defect1-no-ordering ./run-all.sh
#
# A candidate directory may contain any subset of Dockerfile, dockerignore,
# docker-compose.yml and ship.sh; whatever it omits comes from the reference,
# so a defect probe is one file long.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$(cd "$DIR/../.." && pwd)"

CAND="${CAND:-reference-solution}"
CAND_DIR="$PACK/$CAND"
LAB_DIR="${LAB_DIR:-/tmp/marlow-lab-ref}"
POINTS_PER_TEST="${POINTS_PER_TEST:-10}"
LLM_IMAGE="${LLM_IMAGE:-ai-lab/depot-llm:1.0}"
BUILD_BASE="${BUILD_BASE:-python:3.11}"
RUN_BASE="${RUN_BASE:-python:3.11-slim}"
SKIP_UP="${SKIP_UP:-0}"

export DOCKER_BUILDKIT=0 COMPOSE_DOCKER_CLI_BUILD=0
export LAB_DIR
export IMAGES_READY="${IMAGES_READY:-/tmp/marlow-images.ready}"
export TIMING_LOG="${TIMING_LOG:-/tmp/marlow_timing.log}"

[ -d "$CAND_DIR" ] || { echo "no candidate directory $CAND_DIR"; exit 1; }
: > "$TIMING_LOG"

echo "=== candidate: $CAND ==="

echo "=== provided images ==="
if ! docker image inspect "$LLM_IMAGE" >/dev/null 2>&1; then
    T="$(mktemp -d)"
    cp "$PACK/service/depot_llm.py" "$PACK/app/depot-api/matching.py" "$T/"
    cp "$PACK/app/depot-api/catalog/parts.json" "$T/parts.json"
    cp "$PACK/service/Dockerfile.llm" "$T/Dockerfile"
    ( cd "$T" && docker build -q -t "$LLM_IMAGE" . >/dev/null ) || {
        echo "ERROR: could not build $LLM_IMAGE"; exit 1; }
    rm -rf "$T"
    echo "built $LLM_IMAGE"
else
    echo "$LLM_IMAGE present"
fi
for base in "$RUN_BASE" "$BUILD_BASE"; do
    docker image inspect "$base" >/dev/null 2>&1 || docker pull -q "$base" >/dev/null
    echo "$base present"
done
touch "$IMAGES_READY"

echo "=== assembling $LAB_DIR ==="
if [ -d "$LAB_DIR" ]; then
    ( cd "$LAB_DIR" && docker compose down -v --remove-orphans >/dev/null 2>&1 )
fi
rm -rf "$LAB_DIR"
mkdir -p "$LAB_DIR/depot-api"
cp -R "$PACK/app/depot-api/." "$LAB_DIR/depot-api/"
mv "$LAB_DIR/depot-api/env.provided" "$LAB_DIR/depot-api/.env"
cp "$PACK/app/README.md" "$LAB_DIR/README.md"
mkdir -p "$LAB_DIR/dist" "$LAB_DIR/depot-api/local_index" \
         "$LAB_DIR/depot-api/__pycache__" "$LAB_DIR/depot-api/.venv/lib"
awk 'BEGIN { print "token,part_no,token_weight";
             for (i = 0; i < 40000; i++)
                 printf "tok%05d,PN-1%03d,%d\n", i % 997, i % 800, (i % 17) + 1; }' \
    > "$LAB_DIR/depot-api/local_index/tokens_index.csv"
printf 'home = /usr/local/bin\nversion = 3.11.9\n' > "$LAB_DIR/depot-api/.venv/pyvenv.cfg"
printf 'stale bytecode from a local run\n' > "$LAB_DIR/depot-api/__pycache__/app.cpython-311.pyc"

pick() {  # pick <name-in-candidate> <destination>
    if [ -f "$CAND_DIR/$1" ]; then cp "$CAND_DIR/$1" "$2"; echo "  $1 <- $CAND";
    else cp "$PACK/reference-solution/$1" "$2"; echo "  $1 <- reference"; fi
}
pick Dockerfile          "$LAB_DIR/depot-api/Dockerfile"
pick dockerignore        "$LAB_DIR/depot-api/.dockerignore"
pick docker-compose.yml  "$LAB_DIR/docker-compose.yml"
pick ship.sh             "$LAB_DIR/ship.sh"
chmod +x "$LAB_DIR/ship.sh"

if [ "$SKIP_UP" != "1" ]; then
    echo "=== bringing the candidate stack up (playing the learner) ==="
    t0=$SECONDS
    ( cd "$LAB_DIR" && docker compose up -d --build ) >"/tmp/marlow_up_$$.log" 2>&1
    UPRC=$?
    echo "docker compose up -d --build finished in $((SECONDS - t0))s (exit $UPRC)"
    [ "$UPRC" -eq 0 ] || tail -12 "/tmp/marlow_up_$$.log" | sed 's/^/    up| /'
    for i in $(seq 1 25); do
        curl -sf -m 2 http://127.0.0.1:8000/health >/dev/null 2>&1 && break
        sleep 1
    done
    curl -sf -m 2 http://127.0.0.1:8000/health >/dev/null 2>&1 \
        && echo "health OK" \
        || echo "health NOT answering (the checks will report why)"
fi

PASS=0; FAIL=0; FAILED_LIST=""; WORST=0
for s in "$DIR"/script_*.sh; do
    name="$(basename "$s")"
    t0=$SECONDS
    out="$(bash "$s" 2>&1)"
    took=$((SECONDS - t0))
    [ "$took" -gt "$WORST" ] && WORST=$took
    # Grade exactly what the platform grades: the LAST line of stdout+stderr.
    # Taking the first matching line anywhere hid a real bug - a check that
    # printed its verdict and then emitted one more line scored full marks here
    # and reported no test cases at all on the portal.
    line="$(printf '%s\n' "$out" | tail -n 1)"
    msg="$(printf '%s' "$line" | jq -r '.message // empty' 2>/dev/null)"
    [ -n "$msg" ] || msg="$line"
    if printf '%s' "$line" | grep -q '"status": *"success"'; then
        PASS=$((PASS + 1))
        printf '  [PASS] %-16s %3ds  %s\n' "$name" "$took" "$msg"
    elif printf '%s' "$line" | grep -q '"status": *"failed"'; then
        FAIL=$((FAIL + 1))
        FAILED_LIST="$FAILED_LIST $name"
        printf '  [FAIL] %-16s %3ds  %s\n' "$name" "$took" "$msg"
        printf '%s\n' "$out" | sed '$d' | sed 's/^/         /' | head -8
    else
        FAIL=$((FAIL + 1))
        FAILED_LIST="$FAILED_LIST ${name}(UNPARSEABLE)"
        printf '  [!!!!] %-16s %3ds  last line is not a verdict - the portal would\n' "$name" "$took"
        printf '         report this submission as having no test cases at all:\n'
        printf '%s\n' "$out" | tail -4 | sed 's/^/         > /'
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
