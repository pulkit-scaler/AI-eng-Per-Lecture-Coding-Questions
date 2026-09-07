#!/bin/bash
# Marlow Depot lab - VM provisioning script.
# Runs once, as root, before the learner starts.
# TEMPLATE: build.sh replaces every FILE marker below with that file's contents.
#
# Target image is the Alpine Docker-in-Docker one, so this script may use only
# what that image actually has: busybox coreutils, bash, curl, jq, sha256sum,
# and the docker CLI. There is no python3 on the host at all - every line of
# Python in this lab runs inside a container.
#
# No `set -e`: a failing step must be recorded and provisioning must continue,
# so a single hiccup cannot leave the learner with a half-built project or
# root-owned files.
set -uo pipefail

LOG_DIR="/var/log/marlow-lab"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp/marlow-lab"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp"
LOG="${LOG_DIR}/setup.log"
STATUS_FILE="${LOG_DIR}/setup-status"
: > "$STATUS_FILE" 2>/dev/null || true

exec > >(tee -a "$LOG") 2>&1

WARNINGS=0
stamp() { date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "-"; }
note()  { echo "[$(stamp)] $*"; }
ok()    { echo "[$(stamp)] OK   $*"; printf 'OK   %s\n'   "$*" >>"$STATUS_FILE" 2>/dev/null || true; }
warn()  { WARNINGS=$((WARNINGS + 1)); echo "[$(stamp)] WARN $*"; printf 'WARN %s\n' "$*" >>"$STATUS_FILE" 2>/dev/null || true; }
run()   { local label="$1"; shift; if "$@"; then ok "$label"; else warn "$label (exit $?)"; fi; return 0; }

# cap <seconds> <cmd...> : never let one command block provisioning
# indefinitely. Pure bash rather than busybox timeout(1), which on this image
# has no -k and dies on the option rather than applying it - a bound that
# errors out is worse than no bound, because it looks like the command failed.
# The command runs in the background and is waited for in one-second steps:
# bash dispatches a trap only between commands, so blocking in the foreground
# would defer the deadline watchdog below until the command returned.
cap() {
    local secs="$1"; shift
    "$@" &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -ge "$secs" ]; then
            kill -TERM "$pid" 2>/dev/null
            sleep 2
            kill -KILL "$pid" 2>/dev/null
            break
        fi
    done
    wait "$pid" 2>/dev/null
    return $?
}

# detach <logfile> <cmd...> : run something that must outlive this script.
detach() {
    local logfile="$1"; shift
    if command -v setsid >/dev/null 2>&1; then
        setsid nohup "$@" >"$logfile" 2>&1 </dev/null &
    else
        nohup "$@" >"$logfile" 2>&1 </dev/null &
    fi
    disown 2>/dev/null || true
    return 0
}

LAB_USER="user"
LAB_HOME="/home/${LAB_USER}"
PROJ="${LAB_HOME}/marlow-depot"
API_SRC="${PROJ}/depot-api"
IMAGES_READY="${LOG_DIR}/images.ready"
IMAGES_STATE="${LOG_DIR}/images.state"
IMAGES_JOB="${LOG_DIR}/prepare-images.sh"
IMAGES_LOG="${LOG_DIR}/images.log"
BUILD_BASE="python:3.11"
RUN_BASE="python:3.11-slim"
LLM_IMAGE="ai-lab/depot-llm:1.0"

note "Marlow Depot setup starting; full log at ${LOG}"

# Hard internal deadline. Every individual step is capped above; this is the
# backstop against them accumulating. On expiry the script prints its summary
# and exits 0 rather than being killed, so the portal shows a provisioned lab
# with a warning instead of a blocking-process error.
SETUP_BUDGET="${SETUP_BUDGET:-95}"
DEADLINE_HIT=0
on_deadline() {
    DEADLINE_HIT=1
    warn "setup hit its internal ${SETUP_BUDGET}s deadline at t+${SECONDS}s and is finishing early so provisioning reports a result instead of being killed"
    if type finish_summary >/dev/null 2>&1; then finish_summary; fi
    exit 0
}
trap on_deadline USR1
( sleep "$SETUP_BUDGET"; kill -USR1 $$ 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG_PID=$!

echo "=== [1/6] Docker and the lab account ==="
if command -v docker >/dev/null 2>&1; then
    ok "docker CLI present: $(docker --version 2>/dev/null | head -1)"
else
    warn "no docker CLI on this image - the lab cannot work"
fi
if cap 20 docker info >/dev/null 2>&1; then
    ok "docker daemon reachable"
else
    warn "docker daemon not reachable during setup"
fi
if docker compose version >/dev/null 2>&1; then
    ok "compose plugin present: $(docker compose version --short 2>/dev/null)"
else
    warn "no 'docker compose' plugin - the learner needs it"
fi
# An editor. The learner has four files to write by hand, and the only editor
# this base image guarantees is busybox `vi` - a poor landing if the portal's
# terminal cannot render a full-screen application. Add the two editors people
# actually reach for. Capped and non-fatal: nothing here blocks the lab, and the
# summary tells the learner what they ended up with.
editors_present() {
    local found="" e
    for e in vim nano vi; do
        command -v "$e" >/dev/null 2>&1 && found="${found} ${e}"
    done
    printf '%s' "$found"
}
EDITORS_FOUND="$(editors_present)"
case "$EDITORS_FOUND" in
    *vim*nano*|*nano*vim*) ;;
    *) if command -v apk >/dev/null 2>&1; then
           cap 25 apk add --no-cache vim nano >/dev/null 2>&1 || true
           EDITORS_FOUND="$(editors_present)"
       fi ;;
esac
if [ -n "$EDITORS_FOUND" ]; then
    ok "editors available:${EDITORS_FOUND}"
else
    warn "no editor on this image - the learner can only write files with a shell heredoc"
fi

if id -u "$LAB_USER" >/dev/null 2>&1; then
    ok "lab account ${LAB_USER} exists"
else
    warn "no ${LAB_USER} account on this image"
fi
if id -nG "$LAB_USER" 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    ok "${LAB_USER} is in the docker group"
else
    note "adding ${LAB_USER} to the docker group"
    cap 10 addgroup "$LAB_USER" docker >/dev/null 2>&1 \
        || cap 10 usermod -aG docker "$LAB_USER" >/dev/null 2>&1 \
        || warn "could not add ${LAB_USER} to the docker group"
fi
note "docker checks done (t+${SECONDS}s)"

echo "=== [2/6] Base images and the adviser backend (detached) ==="
# Two base image pulls and one small build. None of it is needed to hand the
# learner their project, and all of it is network-bound, so it happens after
# provisioning has already returned. The job publishes a readiness file the
# checks and the learner-facing helper both wait on.
rm -f "$IMAGES_READY" "$IMAGES_STATE"
SVC_STAGE="/opt/marlow-llm-build"
rm -rf "$SVC_STAGE"; mkdir -p "$SVC_STAGE"

cat > "${SVC_STAGE}/depot_llm.py" <<'___MDFILE___'
@@FILE:service/depot_llm.py@@
___MDFILE___

cat > "${SVC_STAGE}/matching.py" <<'___MDFILE___'
@@FILE:app/depot-api/matching.py@@
___MDFILE___

cat > "${SVC_STAGE}/parts.json" <<'___MDFILE___'
@@FILE:app/depot-api/catalog/parts.json@@
___MDFILE___

cat > "${SVC_STAGE}/Dockerfile" <<'___MDFILE___'
@@FILE:service/Dockerfile.llm@@
___MDFILE___

chown -R root:root "$SVC_STAGE" 2>/dev/null || true
chmod -R 700 "$SVC_STAGE" 2>/dev/null || true

{
    echo '#!/bin/bash'
    echo '# GENERATED by the setup script. Pulls the bases, builds the adviser'
    echo '# backend image, removes its build directory and publishes readiness.'
    echo "IMAGES_STATE=\"${IMAGES_STATE}\""
    echo "IMAGES_READY=\"${IMAGES_READY}\""
    echo "SVC_STAGE=\"${SVC_STAGE}\""
    echo "BUILD_BASE=\"${BUILD_BASE}\""
    echo "RUN_BASE=\"${RUN_BASE}\""
    echo "LLM_IMAGE=\"${LLM_IMAGE}\""
    cat <<'___IMAGEJOB___'
export DOCKER_BUILDKIT=0
state=""

# The runtime base first: it is the smaller pull and the adviser backend build
# needs it, so getting it early shortens the critical path to a usable lab.
if docker pull -q "$RUN_BASE" >/dev/null 2>&1; then
    state="run"
else
    state="run-failed"
fi

if [ "$state" = "run" ]; then
    if (cd "$SVC_STAGE" && docker build -q -t "$LLM_IMAGE" . >/dev/null 2>&1); then
        state="backend"
    else
        state="backend-failed"
    fi
fi

# Build base last. It is a large pull and only the learner's builder stage
# needs it, so nothing else waits on it.
if docker pull -q "$BUILD_BASE" >/dev/null 2>&1; then
    [ "$state" = "backend" ] && state="all"
else
    [ "$state" = "backend" ] && state="backend-only"
fi

# The backend source never stays on disk: the image is all the learner gets.
rm -rf "$SVC_STAGE"

echo "$state" > "$IMAGES_STATE"
docker images 2>/dev/null | head -20
touch "$IMAGES_READY"
___IMAGEJOB___
} > "$IMAGES_JOB"
chmod 700 "$IMAGES_JOB"
detach "$IMAGES_LOG" "$IMAGES_JOB"
note "image preparation detached (job ${IMAGES_JOB}, log ${IMAGES_LOG})"

echo "=== [3/6] Project skeleton ==="
mkdir -p "${API_SRC}/catalog" "${API_SRC}/vendor/depot_hash/src" \
         "${API_SRC}/local_index" "${PROJ}/dist"

cat > "${API_SRC}/app.py" <<'___MDFILE___'
@@FILE:app/depot-api/app.py@@
___MDFILE___

cat > "${API_SRC}/indexer.py" <<'___MDFILE___'
@@FILE:app/depot-api/indexer.py@@
___MDFILE___

cat > "${API_SRC}/matching.py" <<'___MDFILE___'
@@FILE:app/depot-api/matching.py@@
___MDFILE___

cat > "${API_SRC}/requirements.txt" <<'___MDFILE___'
@@FILE:app/depot-api/requirements.txt@@
___MDFILE___

cat > "${API_SRC}/version.txt" <<'___MDFILE___'
@@FILE:app/depot-api/version.txt@@
___MDFILE___

cat > "${API_SRC}/catalog/parts.json" <<'___MDFILE___'
@@FILE:app/depot-api/catalog/parts.json@@
___MDFILE___

cat > "${API_SRC}/vendor/depot_hash/setup.py" <<'___MDFILE___'
@@FILE:app/depot-api/vendor/depot_hash/setup.py@@
___MDFILE___

cat > "${API_SRC}/vendor/depot_hash/pyproject.toml" <<'___MDFILE___'
@@FILE:app/depot-api/vendor/depot_hash/pyproject.toml@@
___MDFILE___

cat > "${API_SRC}/vendor/depot_hash/src/depot_hashmodule.c" <<'___MDFILE___'
@@FILE:app/depot-api/vendor/depot_hash/src/depot_hashmodule.c@@
___MDFILE___

cat > "${API_SRC}/.env" <<'___MDFILE___'
@@FILE:app/depot-api/env.provided@@
___MDFILE___

cat > "${PROJ}/README.md" <<'___MDFILE___'
@@FILE:app/README.md@@
___MDFILE___

# What a working checkout looks like after somebody has run things locally: a
# stale index, a virtualenv and compiled bytecode. All three belong in the
# repository and none of them belongs in an image.
awk 'BEGIN {
    print "token,part_no,token_weight";
    for (i = 0; i < 40000; i++)
        printf "tok%05d,PN-1%03d,%d\n", i % 997, i % 800, (i % 17) + 1;
}' > "${API_SRC}/local_index/tokens_index.csv" 2>/dev/null
mkdir -p "${API_SRC}/.venv/lib" "${API_SRC}/__pycache__"
printf 'home = /usr/local/bin\nversion = 3.11.9\n' > "${API_SRC}/.venv/pyvenv.cfg"
printf 'include-system-site-packages = false\n' > "${API_SRC}/.venv/lib/marker"
printf '\x00\x00stale bytecode from a local run\n' > "${API_SRC}/__pycache__/app.cpython-311.pyc"

# Hand the project over immediately, before any step that could fail and leave
# these files root-owned - and therefore read-only for the learner.
run "early chown of ${PROJ}" chown -R "${LAB_USER}:${LAB_USER}" "$PROJ"
chmod -R u+rw "$PROJ" 2>/dev/null || warn "early chmod failed"
find "$PROJ" -type d -exec chmod u+x {} + 2>/dev/null || true
chmod 600 "${API_SRC}/.env" 2>/dev/null || true
[ -s "${API_SRC}/app.py" ] && ok "application source in place" || warn "application source missing"
[ -s "${API_SRC}/.env" ] && ok "credential file in place" || warn "credential file missing"
note "project skeleton done (t+${SECONDS}s)"

echo "=== [4/6] Learner state the checks touch ==="
# Grading runs as root. Everything a check writes into is pre-created here as
# the learner, so the first writer afterwards writes into something they
# already own. The checks also hand ownership back from an EXIT trap.
for d in "${PROJ}/dist" "${LAB_HOME}/.docker"; do
    mkdir -p "$d" 2>/dev/null || true
    chown -R "${LAB_USER}:${LAB_USER}" "$d" 2>/dev/null || true
done
touch "${PROJ}/dist/.keep" 2>/dev/null || true
chown "${LAB_USER}:${LAB_USER}" "${PROJ}/dist/.keep" 2>/dev/null || true
ok "dist/ pre-created and owned by ${LAB_USER}"

# The portal opens a non-login interactive bash. That reads ~/.bashrc and never
# /etc/profile, and this image ships no ~/.bashrc - so bash falls back to its
# built-in prompt, which reports the shell version and never the directory. This
# lab says "run every compose command from the project root" a dozen times, so a
# prompt that cannot show where you are is a genuine trap. Give them one.
cat > "${LAB_HOME}/.bashrc" <<'___RCFILE___'
# Interactive shell settings.
case $- in
    *i*) ;;
      *) return ;;
esac

# Replace only bash's built-in prompt; a prompt the learner set is left alone.
if [ -z "$PS1" ] || [ "$PS1" = '\s-\v\$ ' ]; then
    case "${TERM:-dumb}" in
        *color*|xterm*|screen*|tmux*|rxvt*|linux|vt100)
            PS1='\[\033[1;32m\]\u\[\033[0m\]:\[\033[1;34m\]\w\[\033[0m\]\$ ' ;;
        *)
            PS1='\u:\w\$ ' ;;
    esac
fi

HISTSIZE=2000
HISTFILESIZE=2000
command -v shopt >/dev/null 2>&1 && shopt -s checkwinsize 2>/dev/null
alias ll='ls -alF'
___RCFILE___

# A login shell reads a profile, not .bashrc. Point it at the same file so the
# prompt is identical however the terminal is opened - but only under bash: the
# colour escapes above are bash syntax, and busybox ash would print them raw.
for f in "${LAB_HOME}/.profile" "${LAB_HOME}/.bash_profile"; do
    cat > "$f" <<'___PROFILE___'
if [ -n "${BASH_VERSION:-}" ] && [ -f "$HOME/.bashrc" ]; then
    . "$HOME/.bashrc"
fi
___PROFILE___
done

# Belt and braces for a non-bash login shell: Alpine's /etc/profile sources this
# directory. Plain escapes only (busybox ash understands \u \w \$ but not \[ \]),
# and it prints nothing, so it cannot disturb a grading run.
mkdir -p /etc/profile.d 2>/dev/null || true
cat > /etc/profile.d/marlow-prompt.sh <<'___PROFILED___'
if [ -z "${PS1:-}" ] || [ "$PS1" = '\s-\v\$ ' ]; then
    PS1='\u:\w\$ '
fi
___PROFILED___
chmod 644 /etc/profile.d/marlow-prompt.sh 2>/dev/null || true
chown "${LAB_USER}:${LAB_USER}" \
    "${LAB_HOME}/.bashrc" "${LAB_HOME}/.profile" "${LAB_HOME}/.bash_profile" 2>/dev/null || true
ok "interactive prompt shows the working directory"
note "learner state done (t+${SECONDS}s)"

echo "=== [5/6] Image preparation hand-off ==="
# A short, bounded grace period. On a fast machine the detached job has already
# finished, so setup exits with everything in place. What it must never do is
# wait for the slow case - that is what puts the total over the limit.
IMAGES_GRACE="${IMAGES_GRACE:-6}"
for _i in $(seq 1 "$IMAGES_GRACE"); do
    [ -f "$IMAGES_READY" ] && break
    sleep 1
done
case "$(cat "$IMAGES_STATE" 2>/dev/null)" in
    all)          ok "both base images pulled and the adviser backend image built" ;;
    backend-only) warn "the adviser backend image is built but ${BUILD_BASE} did not pull; a multi-stage builder stage will pull it on first build" ;;
    backend)      note "backend built; the ${BUILD_BASE} pull is still running" ;;
    run-failed)   warn "could not pull ${RUN_BASE} - check the network (see ${IMAGES_LOG})" ;;
    backend-failed) warn "the adviser backend image failed to build (see ${IMAGES_LOG})" ;;
    *)            note "images are still downloading in the background (log ${IMAGES_LOG}); the project is ready now, and ${IMAGES_READY} appears when the pulls and the build finish" ;;
esac
tail -n 6 "$IMAGES_LOG" 2>/dev/null | sed 's/^/    img| /'
note "image hand-off done (t+${SECONDS}s)"

finish_summary() {
    [ "${SUMMARY_DONE:-0}" -eq 1 ] && return 0
    SUMMARY_DONE=1
    local blockers=""
    command -v docker >/dev/null 2>&1 || blockers="${blockers} docker-missing"
    docker compose version >/dev/null 2>&1 || blockers="${blockers} compose-missing"
    [ -s "${API_SRC}/app.py" ] || blockers="${blockers} project-missing"
    [ -s "${API_SRC}/.env" ] || blockers="${blockers} credential-missing"
    if [ -n "$blockers" ]; then
        warn "LAB NOT READY -${blockers}"
        note "provisioning could not finish the essentials. Re-running setup on a fresh VM is"
        note "the fastest remedy; the phase timings above show which step ran out of time."
        note "total setup time: ${SECONDS}s"
        return 0
    fi
cat <<SUMMARY

--------------------------------------------------------------------
Marlow Depot lab is ready.

Project:   ${PROJ}
Provided:  depot-api/       the service, the index builder, the catalogue and
                            the vendored fingerprint extension
           depot-api/.env   DEPOT_API_KEY - it must never reach an image
           README.md        how the two processes fit together
You write: depot-api/Dockerfile
           depot-api/.dockerignore
           docker-compose.yml
           ship.sh

Images on this machine: ${RUN_BASE}, ${BUILD_BASE} and ${LLM_IMAGE}.
See them with:  docker images

Editors:  ${EDITORS_FOUND:- none found}
If a full-screen editor will not display in this terminal, write a file
straight from the shell instead:
    cat > docker-compose.yml <<'END'
    ...your file...
    END

Bring your stack up and check it before you submit:
    cd ${PROJ}
    docker compose up -d --build
    curl -s http://127.0.0.1:8000/health

Setup log:    ${LOG}
Setup status: ${STATUS_FILE}
Image log:    ${IMAGES_LOG}
--------------------------------------------------------------------
SUMMARY

if [ "$WARNINGS" -gt 0 ]; then
    note "setup finished with ${WARNINGS} warning(s):"
    grep '^WARN' "$STATUS_FILE" 2>/dev/null | sed 's/^/    /'
else
    note "setup finished with no warnings"
fi
note "total setup time: ${SECONDS}s"
    if [ "$DEADLINE_HIT" -eq 1 ]; then
        note "finished early on the internal deadline; the project is in place and the image preparation continues in the background"
    fi
}

echo "=== [6/6] Permissions and summary ==="
run "chown project to ${LAB_USER}" chown -R "${LAB_USER}:${LAB_USER}" "$PROJ"
run "make project writable" chmod -R u+rw "$PROJ"
find "$PROJ" -type d -exec chmod u+x {} + 2>/dev/null || warn "could not set directory execute bits"
[ -w "${API_SRC}/requirements.txt" ] || warn "requirements.txt is not writable - the learner will hit a read-only file"

finish_summary

kill "$WATCHDOG_PID" >/dev/null 2>&1 || true
sync 2>/dev/null || true
exit 0
