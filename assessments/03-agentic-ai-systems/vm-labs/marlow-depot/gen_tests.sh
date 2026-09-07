#!/bin/bash
# Regenerate test-cases/scripts/script_01..05.sh.
#
# The five checks share one preamble. It is duplicated into every file because
# the platform runs every file in the test scripts folder as a test, so there
# is nowhere to put a shared helper - and duplication that is generated cannot
# drift, while duplication that is hand-edited always does.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$DIR/test-cases/scripts"
mkdir -p "$OUT"

preamble() {
cat <<'PRE'
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
PRE
}

emit() {
    local n="$1" title="$2" body="$3"
    {
        echo '#!/bin/bash'
        echo "# TC${n} (10 pts): ${title}"
        preamble
        echo ""
        cat "$body"
    } > "$OUT/script_${n}.sh"
    chmod +x "$OUT/script_${n}.sh"
    bash -n "$OUT/script_${n}.sh"
    echo "  wrote script_${n}.sh"
}

BODY="$(mktemp -d)"
trap 'rm -rf "$BODY"' EXIT

# ---------------------------------------------------------------- TC01 ------
cat > "$BODY/01" <<'B01'
Test01() {
    preflight || return
    if ! cold_start; then
        report "failed" "after clearing the index volume and running docker compose up -d, nothing answered ${API_URL}/health within ${SVC_WAIT}s - on a cold volume the API exits immediately unless the one-shot index build is made to finish first: $(cd "$LAB_DIR" 2>/dev/null && docker compose logs --tail 3 depot-api 2>&1 | tr "\n" " " | tail -c 300)"
        return
    fi

    local health parts tokens fp idxid exitcode status want_no want_note
    local got_no got_note before after need

    health="$(api_get /health)"
    if [ -z "$health" ]; then
        report "failed" "${API_URL}/health did not answer"
        return
    fi
    status="$(printf '%s' "$health" | jq -r '.status')"
    parts="$(printf '%s' "$health" | jq -r '.indexed_parts')"
    tokens="$(printf '%s' "$health" | jq -r '.indexed_tokens')"
    fp="$(printf '%s' "$health" | jq -r '.catalog_fp')"

    if [ "$status" != "ok" ]; then
        report "failed" "${API_URL}/health reported status ${status}"
        return
    fi
    if [ "$parts" != "$EXPECT_PARTS" ] || [ "$tokens" != "$EXPECT_TOKENS" ]; then
        report "failed" "the API is serving ${parts} parts and ${tokens} tokens where the catalogue has ${EXPECT_PARTS} and ${EXPECT_TOKENS} - it is not reading the index the one-shot build wrote"
        return
    fi
    if [ "$fp" != "$CATALOG_FP" ]; then
        report "failed" "the index fingerprint is ${fp} and should be ${CATALOG_FP} - the vendored fingerprint extension did not build, or the index was not written by indexer.py"
        return
    fi

    # The one-shot build has to have run to completion, not merely started.
    idxid="$(svc_cid indexer)"
    if [ -z "$idxid" ]; then
        report "failed" "there is no container for a compose service named indexer - the index build has to be its own one-shot service"
        return
    fi
    exitcode="$(docker inspect -f '{{.State.ExitCode}}' "$idxid" 2>/dev/null)"
    status="$(docker inspect -f '{{.State.Status}}' "$idxid" 2>/dev/null)"
    if [ "$status" != "exited" ] || [ "${exitcode:-1}" != "0" ]; then
        report "failed" "the indexer container is ${status} with exit code ${exitcode} - it must run once, finish successfully and leave the index behind"
        return
    fi

    # The ordering itself, read out of the daemon rather than inferred from a
    # race. Both stamps are RFC3339 UTC from the same daemon, so comparing them
    # as strings is exact and needs no date parsing. Even a stack whose API
    # happens to win the race is caught here.
    local apiid idx_end api_start
    apiid="$(svc_cid depot-api)"
    if [ -z "$apiid" ]; then
        report "failed" "there is no container for a compose service named depot-api"
        return
    fi
    idx_end="$(docker inspect -f '{{.State.FinishedAt}}' "$idxid" 2>/dev/null)"
    api_start="$(docker inspect -f '{{.State.StartedAt}}' "$apiid" 2>/dev/null)"
    if [ -z "$idx_end" ] || [ -z "$api_start" ]; then
        report "failed" "could not read the start and finish times of the two containers from the daemon"
        return
    fi
    if [ "$api_start" \< "$idx_end" ]; then
        report "failed" "depot-api started at ${api_start} while the index build did not finish until ${idx_end} - the two were started together, so the API only found an index by luck; it has to wait for the one-shot build to complete successfully"
        return
    fi

    need="gearbox oil filter clogged with swarf"
    want_no="$(oracle_at "$OPS_URL" "$need" | jq -r '.part_no')"
    require_expected "$want_no" || return
    want_note="$(oracle_at "$OPS_URL" "$need" | jq -r '.note')"

    before="$(ops_get /stats | jq -r '.chat')"
    got_no="$(api_match "$need" | jq -r '.part_no')"
    got_note="$(api_match "$need" | jq -r '.note')"
    after="$(ops_get /stats | jq -r '.chat')"

    if [ "$got_no" != "$want_no" ]; then
        report "failed" "POST /match returned ${got_no} for a need the catalogue answers with ${want_no}"
        return
    fi
    if [ "$got_note" != "$want_note" ]; then
        report "failed" "the note on the match is not the one the adviser backend produces for that part"
        return
    fi
    if [ "${before:-0}" = "${after:-0}" ]; then
        report "failed" "the adviser backend saw no new request while /match was answered twice - the API is not reaching it over the compose network"
        return
    fi

    report "success" "from a cleared volume the API started at ${api_start}, after the one-shot build finished at ${idx_end} with exit 0, then served ${parts} parts and ${tokens} tokens (fingerprint ${fp}) and answered ${got_no} through the adviser backend"
}

Test01
B01

# ---------------------------------------------------------------- TC02 ------
cat > "$BODY/02" <<'B02'
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
B02

# ---------------------------------------------------------------- TC03 ------
cat > "$BODY/03" <<'B03'
Test03() {
    preflight_running || return

    local fp raw who uid gotfp env hist leaks
    fp="$(key_fp)"
    raw="$(key_raw)"
    if [ -z "$fp" ] || [ -z "$raw" ]; then
        report "failed" "could not read DEPOT_API_KEY from ${API_SRC}/.env"
        return
    fi

    who="$(api_get /whoami)"
    if [ -z "$who" ]; then
        report "failed" "${API_URL}/whoami did not answer"
        return
    fi
    gotfp="$(printf '%s' "$who" | jq -r '.key_fp')"
    uid="$(printf '%s' "$who" | jq -r '.uid')"

    if [ "$gotfp" != "$fp" ]; then
        report "failed" "the running container reports credential fingerprint ${gotfp} where the one in .env is ${fp} - the key is not reaching the container at run time"
        return
    fi
    if [ "${uid:-0}" = "0" ]; then
        report "failed" "the API process is running as uid 0 - the container must run as an unprivileged user"
        return
    fi

    env="$(docker image inspect -f '{{json .Config.Env}}' "$IMAGE" 2>/dev/null)"
    if printf '%s' "$env" | grep -q "$raw"; then
        report "failed" "the credential value is baked into the image environment - once an image is pushed with a key in it, that key is compromised for good"
        return
    fi
    if printf '%s' "$env" | grep -q 'DEPOT_API_KEY'; then
        report "failed" "the image declares DEPOT_API_KEY as a build-time environment variable - the credential must arrive at run time only"
        return
    fi

    hist="$(bounded "$DOCK_MAX" docker history --no-trunc "$IMAGE" 2>/dev/null | grep -c "$raw")"
    if [ "${hist:-0}" -ne 0 ]; then
        report "failed" "the credential appears in the image build history - a build argument is no safer than an ENV line, both are readable by anyone who pulls the image"
        return
    fi

    leaks="$(bounded "$DOCK_MAX" docker run --rm --entrypoint sh "$IMAGE" -c 'find / -xdev \( -name ".env" -o -name "local_index" -o -name ".venv" -o -name ".git" \) 2>/dev/null | head -4' 2>/dev/null)"
    if [ -n "$leaks" ]; then
        report "failed" "the build context leaked into the image: ${leaks} - the credential file, the local virtualenv and the stale local index all have to be excluded"
        return
    fi

    report "success" "the credential reaches the container at run time only (fingerprint ${fp}), the process runs as uid ${uid}, and neither the image environment, its history nor its filesystem carries the key or the local build junk"
}

Test03
B03

# ---------------------------------------------------------------- TC04 ------
cat > "$BODY/04" <<'B04'
Test04() {
    # Deliberately not preflight_running: the rebuild plus the restart plus the
    # health wait already fill the budget, so a stack that is down is brought up
    # by the up below rather than twice.
    preflight || return

    local vfile orig marker t0 elapsed rc served
    vfile="${API_SRC}/version.txt"
    if [ ! -f "$vfile" ]; then
        report "failed" "${vfile} is gone - the API reads its version string from it"
        return
    fi
    orig="$(cat "$vfile" 2>/dev/null)"
    marker="9.4.$$"

    printf '%s\n' "$marker" > "$vfile" 2>/dev/null || {
        report "failed" "could not write ${vfile}"
        return
    }

    t0=$SECONDS
    dc_bounded "$BUILD_BUDGET" build depot-api >/dev/null 2>&1
    rc=$?
    elapsed=$((SECONDS - t0))

    if [ "$rc" -ne 0 ]; then
        printf '%s\n' "$orig" > "$vfile" 2>/dev/null
        report "failed" "rebuilding after a one-line source change did not finish inside ${BUILD_BUDGET}s (exit ${rc}) - the dependency install is being repeated because the code is copied in before the requirements are installed"
        return
    fi
    if [ "$elapsed" -gt "$REBUILD_MAX" ]; then
        printf '%s\n' "$orig" > "$vfile" 2>/dev/null
        report "failed" "rebuilding after a one-line source change took ${elapsed}s against a ${REBUILD_MAX}s ceiling - install the pinned requirements in their own layer, before the application code is copied"
        return
    fi

    dc_bounded "$UP_BUDGET" up -d >/dev/null 2>&1
    served=""
    local i
    for i in $(seq 1 "$SVC_WAIT"); do
        served="$(api_get /health | jq -r '.version')"
        [ "$served" = "$marker" ] && break
        sleep 1
    done

    printf '%s\n' "$orig" > "$vfile" 2>/dev/null
    chown user:user "$vfile" >/dev/null 2>&1

    if [ "$served" != "$marker" ]; then
        report "failed" "after the rebuild the service still reports version ${served} instead of ${marker} - the rebuilt image is not the one the stack is running"
        return
    fi

    report "success" "a one-line source change rebuilt in ${elapsed}s (ceiling ${REBUILD_MAX}s) and the new version ${marker} is what the running service reports, so the pinned dependency layer was reused"
}

Test04
B04

# ---------------------------------------------------------------- TC05 ------
cat > "$BODY/05" <<'B05'
Test05() {
    preflight || return

    local tar t0 rc before_id after_id need want_no want_note got probe_url
    tar="${LAB_DIR}/${TARBALL}"
    before_id="$(docker image inspect -f '{{.Id}}' "$RELEASE" 2>/dev/null)"
    rm -f "$tar" 2>/dev/null

    t0=$SECONDS
    ( cd "$LAB_DIR" && bounded "$SHIP_BUDGET" bash ./ship.sh ) >/tmp/mdp_ship.log 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        report "failed" "ship.sh exited ${rc}: $(tail -2 /tmp/mdp_ship.log 2>/dev/null | tr '\n' ' ')"
        return
    fi
    if [ ! -s "$tar" ]; then
        report "failed" "ship.sh did not leave a saved image at ${TARBALL} - the release has to be written there so it can be handed to somebody without a registry"
        return
    fi
    if ! tar -tf "$tar" >/dev/null 2>&1; then
        report "failed" "${TARBALL} is not a readable archive"
        return
    fi
    if ! docker image inspect "$RELEASE" >/dev/null 2>&1; then
        report "failed" "ship.sh did not leave a ${RELEASE} tag behind - the release needs a version tag, not just latest"
        return
    fi

    # Drop the release tag and put it back from the tarball alone. The latest
    # tag is a separate name for the same image, so nothing the learner built
    # is destroyed by this.
    docker rmi -f "$RELEASE" >/dev/null 2>&1
    if docker image inspect "$RELEASE" >/dev/null 2>&1; then
        report "failed" "could not clear the ${RELEASE} tag to test the handoff"
        return
    fi
    bounded "$LOAD_BUDGET" docker load -i "$tar" >/dev/null 2>&1
    after_id="$(docker image inspect -f '{{.Id}}' "$RELEASE" 2>/dev/null)"
    if [ -z "$after_id" ]; then
        report "failed" "loading ${TARBALL} did not restore ${RELEASE} - what was saved is not a usable image archive"
        return
    fi

    # Bring the loaded image up on its own network, with a fresh index volume
    # and its own copy of the adviser backend, exactly the way somebody who
    # only has the tarball would.
    probe_cleanup
    docker network create "$PROBE_NET" >/dev/null 2>&1
    docker volume create "$PROBE_VOL" >/dev/null 2>&1
    docker run -d --name mdp_probe_llm --network "$PROBE_NET" --network-alias llm \
        -p "127.0.0.1:${PROBE_OPS}:9000" "$LLM_IMAGE" >/dev/null 2>&1
    bounded "$DOCK_MAX" docker run --rm --name mdp_probe_idx --network "$PROBE_NET" \
        -v "${PROBE_VOL}:/index" -e DEPOT_INDEX_DIR=/index \
        "$RELEASE" python indexer.py >/tmp/mdp_probe_idx.log 2>&1
    rc=$?
    if [ "$rc" -ne 0 ]; then
        report "failed" "the loaded image could not build an index on a fresh volume (exit ${rc}): $(tail -2 /tmp/mdp_probe_idx.log 2>/dev/null | tr '\n' ' ') - the index directory has to be writable by the user the container runs as"
        return
    fi
    docker run -d --name mdp_probe_api --network "$PROBE_NET" \
        -v "${PROBE_VOL}:/index" -e DEPOT_INDEX_DIR=/index \
        -e DEPOT_LLM_URL=http://llm:9000/v1 -e DEPOT_API_KEY=handoff-check \
        -p "127.0.0.1:${PROBE_PORT}:8000" "$RELEASE" >/dev/null 2>&1

    probe_url="http://127.0.0.1:${PROBE_PORT}"
    got=""
    local i
    for i in $(seq 1 "$SVC_WAIT"); do
        got="$(curl -sf -m 3 "${probe_url}/health" 2>/dev/null)"
        [ -n "$got" ] && break
        sleep 1
    done
    if [ -z "$got" ]; then
        report "failed" "the image loaded from ${TARBALL} did not serve health on a clean machine setup: $(docker logs mdp_probe_api 2>&1 | tail -2 | tr '\n' ' ')"
        return
    fi
    if [ "$(printf '%s' "$got" | jq -r '.indexed_parts')" != "$EXPECT_PARTS" ]; then
        report "failed" "the loaded image served $(printf '%s' "$got" | jq -r '.indexed_parts') parts instead of ${EXPECT_PARTS}"
        return
    fi

    need="label printer output is streaky and faded"
    want_no="$(oracle_at "http://127.0.0.1:${PROBE_OPS}" "$need" | jq -r '.part_no')"
    if [ -z "$want_no" ] || [ "$want_no" = "null" ]; then
        report "failed" "Grader could not read the expected answer from its own copy of the adviser backend"
        return
    fi
    want_note="$(oracle_at "http://127.0.0.1:${PROBE_OPS}" "$need" | jq -r '.note')"
    got="$(jq -nc --arg n "$need" '{need:$n}' | curl -sf -m 12 \
        -H 'Content-Type: application/json' --data-binary @- \
        -X POST "${probe_url}/match" 2>/dev/null)"
    if [ "$(printf '%s' "$got" | jq -r '.part_no')" != "$want_no" ]; then
        report "failed" "the loaded image answered $(printf '%s' "$got" | jq -r '.part_no') where the catalogue answers ${want_no}"
        return
    fi
    if [ "$(printf '%s' "$got" | jq -r '.note')" != "$want_note" ]; then
        report "failed" "the loaded image did not reach its adviser backend - the note it returned is not the one the backend produces"
        return
    fi

    report "success" "ship.sh wrote ${TARBALL} and tagged ${RELEASE}; after clearing the tag and loading the archive alone, that image indexed a fresh volume and answered ${want_no} on a clean network in $((SECONDS - t0))s"
}

Test05
B05

for n in 01 02 03 04 05; do
    case "$n" in
        01) t="a cold start serves the index the one-shot build wrote" ;;
        02) t="the shipping image is lean and carries no build stage" ;;
        03) t="the credential arrives at run time and is nowhere in the image" ;;
        04) t="a source change rebuilds without reinstalling dependencies" ;;
        05) t="the image travels to another machine as a file" ;;
    esac
    emit "$n" "$t" "$BODY/$n"
done

cat > "$OUT/common.sh" <<'CS'
#!/bin/bash
# FAITHFUL REPLICA of the platform-provided /usr/local/bin/judge/test/common.sh,
# copied from a real lab VM. Used only by run-all.sh during authoring; NEVER
# shipped in TestCase.zip.
#
# It is a replica and not a convenience stub on purpose. The real helper emits
# one line of JSON and installs an ERR trap that exits the check - and a stub
# without those two behaviours let a bug through that scored a correct solution
# as "no test cases at all" on the portal. If this file is easier to pass than
# the real one, local validation is worthless.
print_status() {
    local status="$1"
    local message="$2"
    echo $(jq -n --arg status "$status" --arg message "$message" '{status: $status, message: $message}')
}

handle_internal_error() {
    echo "INTERNAL_ERROR: $1"
    exit 1
}

handle_script_error() {
    handle_internal_error "An error occurred at line $1: '$3' exited with status '$2'"
}

trap 'handle_script_error $LINENO $? "$BASH_COMMAND"' ERR
CS
echo "done"
