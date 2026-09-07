#!/bin/bash
# TC02 (10 pts): the shipping image is lean and carries no build stage
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "/usr/local/bin/judge/test/common.sh" 2>/dev/null || source "$DIR/common.sh" 2>/dev/null || true
type print_status >/dev/null 2>&1 || print_status() { echo "RESULT:$1 | $2"; }

# The platform helper installs `trap ... ERR`, which fires on ANY non-zero
# command regardless of set -e - including a deliberate `return 1` from a guard.
# Its handler posts an internal error and exits, landing a second line after our
# verdict; the judge grades the LAST line, so the verdict is discarded and the
# submission reports no test cases at all. Drop the inherited trap.
trap - ERR
set +eE

# --- one verdict per script -------------------------------------------------
# Nothing below may abort the script: a check must always end in exactly one
# verdict, so there is no set -e and no set -u anywhere in this file.
TC="$(basename "${BASH_SOURCE[0]}" .sh | sed 's/[^0-9]//g')"

# The judge captures stdout+stderr together and grades the LAST line, so a
# single stray line on stderr - a bash job-control notice, a tool warning -
# would void the verdict the same way the ERR trap did. Send this check's
# stderr to a file on the VM: diagnostics stay available, and stdout can only
# ever end in the verdict.
exec 2>>"/tmp/marlow_tc${TC}.err"
STATUS_SENT=0
report() {
    if [ "$STATUS_SENT" -eq 1 ]; then return 0; fi
    STATUS_SENT=1
    print_status "$1" "$2"
}

LAB_DIR="${LAB_DIR:-/home/user/marlow-depot}"
API_SRC="${API_SRC:-${LAB_DIR}/depot-api}"
API_URL="${API_URL:-http://127.0.0.1:8000}"
OPS_URL="${OPS_URL:-http://127.0.0.1:9000}"
OPS_HDR="X-Depot-Ops: depot-ops-9v3q"
OPS_PATH="__dep7f2"
IMAGE="${IMAGE:-marlow-depot/depot-api:latest}"
RELEASE="${RELEASE:-marlow-depot/depot-api:1.0}"
TARBALL="${TARBALL:-dist/depot-api-1.0.tar}"
LLM_IMAGE="${LLM_IMAGE:-ai-lab/depot-llm:1.0}"
BUILD_BASE="${BUILD_BASE:-python:3.11}"
RUN_BASE="${RUN_BASE:-python:3.11-slim}"
IMAGES_READY="${IMAGES_READY:-/var/log/marlow-lab/images.ready}"
TIMING_LOG="${TIMING_LOG:-/tmp/marlow_timing.log}"
PROBE_NET="${PROBE_NET:-mdp_probe_net}"
PROBE_VOL="${PROBE_VOL:-mdp_probe_vol}"
PROBE_PORT="${PROBE_PORT:-8109}"
PROBE_OPS="${PROBE_OPS:-9012}"
CATALOG_FP="12f0f145b74d574a"
HASH_PROBE_IN="marlow"
HASH_PROBE_OUT="e867e47617a728d5"
EXPECT_PARTS=24
EXPECT_TOKENS=118

# The classic builder is the only one this Docker has, and compose must not try
# to hand the build to a BuildKit that is not there.
export DOCKER_BUILDKIT=0
export COMPOSE_DOCKER_CLI_BUILD=0

# --- time budget -----------------------------------------------------------
# The portal kills a test case that runs much beyond two minutes and reports a
# blocking process instead of a score, so every wait here is bounded. Worst
# case is the cold-start check: 15 waiting for images + 25 taking the stack
# down + 25 bringing it back up + 12 waiting for health + six 4s calls, which is
# about 101s. The rebuild check is 15 + 35 + 25 + 12 = 87s, and it deliberately
# does not wait for a healthy stack first, because doing so would put it over
# the cap. On a VM where the learner has already built their image - which they
# are told to do - every check costs seconds, because each wait below returns
# immediately when what it waits for is already there.
CURL_MAX=${CURL_MAX:-4}
SVC_WAIT=${SVC_WAIT:-12}
UP_BUDGET=${UP_BUDGET:-25}
DOWN_BUDGET=${DOWN_BUDGET:-25}
BUILD_BUDGET=${BUILD_BUDGET:-35}
REBUILD_MAX=${REBUILD_MAX:-30}
SHIP_BUDGET=${SHIP_BUDGET:-30}
LOAD_BUDGET=${LOAD_BUDGET:-25}
DOCK_MAX=${DOCK_MAX:-15}
IMG_WAIT=${IMG_WAIT:-15}

# busybox timeout has no -k and exits with an option error rather than
# ignoring it, which would turn every bounded call into an immediate failure.
# Probe the capability instead of assuming it.
TO="$(command -v timeout || command -v gtimeout || true)"
TOK=""
if [ -n "$TO" ] && "$TO" -k 1 1 true >/dev/null 2>&1; then TOK="-k 5"; fi

bounded() {
    local secs="$1"; shift
    if [ -n "$TO" ]; then
        # shellcheck disable=SC2086
        "$TO" $TOK "$secs" "$@"
        return $?
    fi
    # No timeout binary at all - authoring hosts are like this. A silently
    # missing bound is how a stalled command passes for a slow one.
    "$@" &
    local pid=$! rc=0 wd
    ( sleep "$secs"; kill -9 "$pid" ) >/dev/null 2>&1 &
    wd=$!
    wait "$pid"; rc=$?
    kill "$wd" >/dev/null 2>&1
    return $rc
}

probe_cleanup() {
    docker rm -f mdp_probe_llm mdp_probe_api mdp_probe_idx >/dev/null 2>&1
    docker network rm "$PROBE_NET" >/dev/null 2>&1
    docker volume rm "$PROBE_VOL" >/dev/null 2>&1
    return 0
}

# Grading runs as root while the learner is user. Ownership is handed back from
# the EXIT trap rather than from a success path, so a run killed at the time cap
# still leaves a VM the learner can work in. The case statement bounds the
# chown: an empty or mis-set variable must never reach the filesystem root.
on_exit() {
    local rc=$?
    case "$LAB_DIR" in
        /home/user/*) chown -R user:user "$LAB_DIR" >/dev/null 2>&1 ;;
    esac
    probe_cleanup
    printf 'script_%s %ss\n' "$TC" "$SECONDS" >>"$TIMING_LOG" 2>/dev/null || true
    report "failed" "TC${TC} ended without reaching a verdict (rc=${rc})"
}
trap on_exit EXIT

dc_bounded() {
    local secs="$1"; shift
    ( cd "$LAB_DIR" 2>/dev/null && bounded "$secs" docker compose "$@" )
}

svc_cid() {
    docker ps -a --filter "label=com.docker.compose.service=$1" \
        --format '{{.ID}}' 2>/dev/null | head -1
}

img_size() {
    docker image inspect -f '{{.Size}}' "$1" 2>/dev/null
}

api_get() {
    curl -sf -m "$CURL_MAX" "${API_URL}$1" 2>/dev/null
}

api_match() {
    jq -nc --arg n "$1" '{need:$n}' 2>/dev/null | curl -sf -m 12 \
        -H 'Content-Type: application/json' --data-binary @- \
        -X POST "${API_URL}/match" 2>/dev/null
}

ops_get() {
    curl -sf -m "$CURL_MAX" -H "$OPS_HDR" "${OPS_URL}/${OPS_PATH}$1" 2>/dev/null
}

oracle_at() {
    curl -sf -m "$CURL_MAX" -H "$OPS_HDR" --get \
        --data-urlencode "need=$2" "$1/${OPS_PATH}/oracle" 2>/dev/null
}

# Every wait below returns at once when what it waits for is already there, so
# the normal cost of this function is one docker inspect.
ensure_images() {
    docker image inspect "$RUN_BASE" >/dev/null 2>&1 \
        && docker image inspect "$LLM_IMAGE" >/dev/null 2>&1 && return 0
    [ -f "$IMAGES_READY" ] && return 1
    local i
    for i in $(seq 1 "$IMG_WAIT"); do
        sleep 1
        [ -f "$IMAGES_READY" ] && break
    done
    docker image inspect "$RUN_BASE" >/dev/null 2>&1 \
        && docker image inspect "$LLM_IMAGE" >/dev/null 2>&1
}

# Refuse an untouched project in about a second, naming every plausible cause,
# rather than spending the whole budget bootstrapping work the learner has not
# started. Nothing here builds anything on their behalf.
require_started() {
    local missing=""
    [ -s "${API_SRC}/Dockerfile" ]        || missing="${missing} depot-api/Dockerfile"
    [ -s "${API_SRC}/.dockerignore" ]     || missing="${missing} depot-api/.dockerignore"
    [ -s "${LAB_DIR}/docker-compose.yml" ] || missing="${missing} docker-compose.yml"
    [ -s "${LAB_DIR}/ship.sh" ]           || missing="${missing} ship.sh"
    if [ -n "$missing" ]; then
        report "failed" "these files are missing or empty in ${LAB_DIR}:${missing}"
        return 1
    fi
    if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        report "failed" "no ${IMAGE} image on this machine - build and start your stack with: cd ${LAB_DIR} && docker compose up -d --build, confirm ${API_URL}/health answers, then submit"
        return 1
    fi
    return 0
}

ensure_stack_up() {
    api_get /health >/dev/null 2>&1 && return 0
    dc_bounded "$UP_BUDGET" up -d >/dev/null 2>&1
    local i
    for i in $(seq 1 "$SVC_WAIT"); do
        api_get /health >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

# Clear the index volume and bring the stack back up, which is the only way to
# observe the order the services actually start in. A stack that has already
# run once has an index on its volume, so an API that starts too early finds one
# anyway and the ordering mistake stays invisible.
cold_start() {
    dc_bounded "$DOWN_BUDGET" down --remove-orphans -v >/dev/null 2>&1
    dc_bounded "$UP_BUDGET" up -d >/dev/null 2>&1
    local i
    for i in $(seq 1 "$SVC_WAIT"); do
        api_get /health >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

require_expected() {
    if [ -z "$1" ] || [ "$1" = "null" ]; then
        report "failed" "Grader could not read the expected answer from the adviser backend on ${OPS_URL} - the interface contract requires the llm service to publish container port 9000 on host port 9000"
        return 1
    fi
    return 0
}

key_fp() {
    local raw
    raw="$(sed -n 's/^DEPOT_API_KEY=//p' "${API_SRC}/.env" 2>/dev/null | head -1 | tr -d '\r\n')"
    [ -n "$raw" ] || return 1
    printf '%s' "$raw" | sha256sum 2>/dev/null | cut -c1-12
}

key_raw() {
    sed -n 's/^DEPOT_API_KEY=//p' "${API_SRC}/.env" 2>/dev/null | head -1 | tr -d '\r\n'
}

preflight() {
    ensure_images || { report "failed" "the base images this lab needs are not on this machine yet - see /var/log/marlow-lab/images.log"; return 1; }
    require_started || return 1
    return 0
}

preflight_running() {
    preflight || return 1
    ensure_stack_up || { report "failed" "nothing is answering on ${API_URL}/health - bring your stack up with docker compose up -d --build from ${LAB_DIR} and confirm health before submitting"; return 1; }
    return 0
}

Test02() {
    preflight || return

    local api full slim gate basis toolchain imports fpout
    api="$(img_size "$IMAGE")"
    if [ -z "$api" ]; then
        report "failed" "could not measure the size of ${IMAGE}"
        return
    fi

    # Both numbers come from the same daemon and the same command, so the
    # comparison is a ratio and never a hardcoded megabyte figure - image sizes
    # are not comparable across Docker versions.
    full="$(img_size "$BUILD_BASE")"
    if [ -n "$full" ] && [ "${full:-0}" -gt 0 ]; then
        gate=$(( full / 2 ))
        basis="half of ${BUILD_BASE}"
    else
        slim="$(img_size "$RUN_BASE")"
        if [ -z "$slim" ] || [ "${slim:-0}" -le 0 ]; then
            report "failed" "neither ${BUILD_BASE} nor ${RUN_BASE} is on this machine, so the runtime image cannot be sized against anything"
            return
        fi
        gate=$(( slim * 3 ))
        basis="three times ${RUN_BASE}"
    fi
    if [ "$api" -ge "$gate" ]; then
        report "failed" "${IMAGE} measures ${api} bytes against a ceiling of ${gate} (${basis}) - the shipping image is still carrying its build stage"
        return
    fi

    toolchain="$(bounded "$DOCK_MAX" docker run --rm --entrypoint sh "$IMAGE" -c 'command -v gcc cc g++ 2>/dev/null | head -3' 2>/dev/null)"
    if [ -n "$toolchain" ]; then
        report "failed" "the shipping image still has a C toolchain in it (${toolchain}) - build tools belong in the build stage only"
        return
    fi

    imports="$(bounded "$DOCK_MAX" docker run --rm --entrypoint python "$IMAGE" -c 'import fastapi, uvicorn, pandas, httpx, depot_hash; print("imports-ok")' 2>&1 | tail -1)"
    if [ "$imports" != "imports-ok" ]; then
        report "failed" "the shipping image cannot import its own dependencies (${imports}) - whatever the build stage installed did not come across"
        return
    fi

    fpout="$(bounded "$DOCK_MAX" docker run --rm --entrypoint python "$IMAGE" -c "import depot_hash; print(depot_hash.fingerprint(\"${HASH_PROBE_IN}\"))" 2>&1 | tail -1)"
    if [ "$fpout" != "$HASH_PROBE_OUT" ]; then
        report "failed" "the fingerprint extension in the shipping image returned ${fpout} instead of ${HASH_PROBE_OUT} - the compiled module is missing or was not built from the vendored source"
        return
    fi

    report "success" "${IMAGE} is ${api} bytes against a ${gate} ceiling (${basis}), carries no C toolchain, and still imports fastapi, pandas and the compiled fingerprint module"
}

Test02
