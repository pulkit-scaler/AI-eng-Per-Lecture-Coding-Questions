#!/bin/bash
# TC04 (10 pts): robots.txt is read and obeyed, and the pace is kept
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
exec 2>>"/tmp/lambwell_tc${TC}.err"
STATUS_SENT=0
report() {
    if [ "$STATUS_SENT" -eq 1 ]; then return 0; fi
    STATUS_SENT=1
    print_status "$1" "$2"
}

LAB_DIR="${LAB_DIR:-/home/user/lambwell-market}"
SITE_URL="${SITE_URL:-http://127.0.0.1:8711}"
SITE_BIN="${SITE_BIN:-/opt/lambwell-svc/marketsite.py}"
GKEY="X-Grader-Key: lambwell-grader-lw4t"
GPATH="__lw4t"
OUT="${OUT:-${LAB_DIR}/out}"
PY="${PY:-python3}"
DEPS_READY_FILE="${DEPS_READY_FILE:-/var/log/lambwell-lab/deps.ready}"
DEPS_STATE_FILE="${DEPS_STATE_FILE:-/var/log/lambwell-lab/deps.state}"
BROWSER_CACHE="${BROWSER_CACHE:-/home/user/.cache/ms-playwright}"
TIMING_LOG="${TIMING_LOG:-/tmp/lambwell_timing.log}"
export PYTHONDONTWRITEBYTECODE=1

# --- time budget -----------------------------------------------------------
# Nothing here drives a browser. The checks read the artefacts the harvest
# already wrote and the log of what the site was actually asked for, so a check
# is a handful of local HTTP calls and some jq. The browser is the learner's
# concern, and it is the one dependency on this image that cannot be pre-baked.
CURL_MAX=${CURL_MAX:-5}
SVC_WAIT=${SVC_WAIT:-12}
JQ_MAX=${JQ_MAX:-20}
HARD_DEADLINE=${HARD_DEADLINE:-90}

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
    "$@" &
    local pid=$! rc=0 wd
    ( sleep "$secs"; kill -9 "$pid" ) >/dev/null 2>&1 &
    wd=$!
    wait "$pid"; rc=$?
    kill "$wd" >/dev/null 2>&1
    return $rc
}

spawn_detached() {
    local log="$1"; shift
    if command -v setsid >/dev/null 2>&1; then
        setsid nohup "$@" >"$log" 2>&1 </dev/null &
    else
        nohup "$@" >"$log" 2>&1 </dev/null &
    fi
    return 0
}

# Grading runs as root while the learner is user. Nothing here writes into the
# project, but ownership goes back from the EXIT trap anyway, so a future check
# that does cannot lock them out.
on_exit() {
    local rc=$?
    case "$LAB_DIR" in
        /home/user/*) chown -R user:user "$LAB_DIR" >/dev/null 2>&1 ;;
    esac
    printf 'script_%s %ss\n' "$TC" "$SECONDS" >>"$TIMING_LOG" 2>/dev/null || true
    report "failed" "TC${TC} ended without reaching a verdict (rc=${rc})"
}
trap on_exit EXIT

ensure_site() {
    curl -sf -m "$CURL_MAX" "${SITE_URL}/health" >/dev/null 2>&1 && return 0
    [ -f "$SITE_BIN" ] || return 1
    spawn_detached /tmp/lambwell_site.log "$PY" "$SITE_BIN"
    local i
    for i in $(seq 1 "$SVC_WAIT"); do
        curl -sf -m 2 "${SITE_URL}/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

expect_field() {
    curl -sf -m "$CURL_MAX" -H "$GKEY" "${SITE_URL}/${GPATH}/expect" \
        2>/dev/null | jq -r "$1"
}

# log_field <jq-filter> [jq-args...] - the site log, through one filter.
log_field() {
    local filter="$1"; shift
    curl -sf -m "$CURL_MAX" -H "$GKEY" "${SITE_URL}/${GPATH}/log" \
        2>/dev/null | jq -r "$@" "$filter"
}

tokens_issued() {
    curl -sf -m "$CURL_MAX" -H "$GKEY" "${SITE_URL}/${GPATH}/tokens" \
        2>/dev/null | jq -r '.tokens | join(" ")'
}

artifact() {
    [ -s "${OUT}/$1.json" ] || return 1
    cat "${OUT}/$1.json"
}

# Every artefact carries the token the page it came from was serving. The site
# records which tokens it has issued, so an artefact quoting one it never issued
# did not come from this site.
require_issued_token() {
    local token="$1" kind="$2" issued
    if [ -z "$token" ] || [ "$token" = "null" ]; then
        report "failed" "the ${kind} artefact carries no page token - it has to record the token of the page it read"
        return 1
    fi
    issued="$(tokens_issued)"
    case " $issued " in
        *" $token "*) return 0 ;;
    esac
    report "failed" "the ${kind} artefact quotes a page token the site never issued: ${token}"
    return 1
}

require_started() {
    local missing="" f
    for f in 01_listings 02_feed 03_session 04_audit; do
        [ -s "${LAB_DIR}/harvest/${f}.py" ] || missing="${missing} harvest/${f}.py"
    done
    if [ -n "$missing" ]; then
        report "failed" "these files are missing or empty in ${LAB_DIR}:${missing}"
        return 1
    fi
    local untouched
    untouched="$(grep -l 'is not written yet' "${LAB_DIR}/harvest"/*.py 2>/dev/null \
        | xargs -n1 basename 2>/dev/null | tr '\n' ' ')"
    if [ -n "$untouched" ]; then
        report "failed" "these still hold the untouched starter: ${untouched}- write the four scripts and run all four before submitting"
        return 1
    fi
    return 0
}

# When an artefact is missing, the useful question is WHY. DEPS_READY_FILE was
# declared here and never read, so a learner on a half-provisioned box - no
# browser, or the dependency install still running - was told to run the very
# command that could not work, and read it as their solution being wrong. Local
# and cheap: nothing here starts a browser or touches the network.
environment_hint() {
    local state
    if [ ! -f "$DEPS_READY_FILE" ]; then
        printf '%s' " (NOTE: this VM has not finished installing the lab dependencies - there is no ${DEPS_READY_FILE} yet - so no harvest could have run. Wait for it to finish, then run the four scripts.)"
        return 0
    fi
    state="$(tr '\n' ' ' < "$DEPS_STATE_FILE" 2>/dev/null)"
    case " $state " in
        *"browser install failed"*|*"install-deps did not finish"*|*"browser-unverified"*)
            printf '%s' " (NOTE: provisioning could not give this VM a working browser - ${DEPS_STATE_FILE} says: ${state}- so no harvest could have run. Try: python3 -m playwright install chromium)"
            return 0 ;;
    esac
    if ! "$PY" -c "import playwright" >/dev/null 2>&1; then
        printf '%s' " (NOTE: playwright does not import on this VM, so no harvest could have run.)"
        return 0
    fi
    if [ ! -d "$BROWSER_CACHE" ] || [ -z "$(ls -A "$BROWSER_CACHE" 2>/dev/null)" ]; then
        printf '%s' " (NOTE: there is no browser in ${BROWSER_CACHE}, so no harvest could have run. Try: python3 -m playwright install chromium)"
        return 0
    fi
    return 0
}

# The checks read artefacts the harvest wrote. They do not drive a browser and
# they do not run the harvest: a harvest that was never run has nothing to
# grade, and saying so in a second is better than starting a browser as root.
require_artifact() {
    if [ ! -s "${OUT}/$1.json" ]; then
        report "failed" "there is no ${OUT}/$1.json - run python3 harvest/$2.py from ${LAB_DIR} before submitting$(environment_hint)"
        return 1
    fi
    return 0
}

preflight() {
    ensure_site || { report "failed" "the market site is not answering on ${SITE_URL}"; return 1; }
    require_started || return 1
    return 0
}

Test04() {
    preflight || return
    require_artifact audit 04_audit || return

    local got private tagged worst delay wanted_delay wanted_disallow
    local disallowed skipped
    got="$(artifact audit)"

    # Nothing may ever have asked for the disallowed path. Not once, not to see
    # what is there.
    private="$(log_field '[.requests[] | select(.path | startswith("/private/"))] | length')"
    if [ "${private:-1}" -ne 0 ]; then
        report "failed" "the site was asked for a path robots.txt disallows ${private} time(s) - a harvest reads robots.txt and then does what it says"
        return
    fi

    disallowed="$(printf '%s' "$got" | jq -r '.robots_disallow | join(",")')"
    wanted_disallow="$(expect_field '.disallowed | join(",")')"
    if [ "$disallowed" != "$wanted_disallow" ]; then
        report "failed" "the audit recorded the disallowed paths as ${disallowed} where robots.txt says ${wanted_disallow} - it has to read the file, not assume it"
        return
    fi
    skipped="$(printf '%s' "$got" | jq -r '.skipped | length')"
    if [ "${skipped:-0}" -lt 1 ]; then
        report "failed" "the audit records nothing as skipped - what was not visited, and why, is part of the record"
        return
    fi

    # The pace, measured from the timestamps the site itself recorded.
    tagged="$(log_field '[.requests[] | select(.path | test("audit="))] | length')"
    if [ "${tagged:-0}" -lt 3 ]; then
        report "failed" "only ${tagged} audit requests reached the site - each page the audit visits has to carry its own audit tag so the pace can be measured"
        return
    fi
    wanted_delay="$(expect_field '.crawl_delay')"
    worst="$(log_field '
        [.requests[] | select(.path | test("audit=")) | .at] as $t
        | [range(1; ($t | length)) | ($t[.] - $t[. - 1])]
        | if length == 0 then 999 else min end' 2>/dev/null)"
    if [ -z "$worst" ] || [ "$worst" = "null" ]; then
        report "failed" "Grader could not measure the gaps between the audit requests"
        return
    fi
    # A tenth of a second of slack: the gap is measured at the site, which is
    # not the same clock the harvest waited on.
    delay="$(jq -n --argjson w "$worst" --argjson d "$wanted_delay" '$w >= ($d - 0.1)')"
    if [ "$delay" != "true" ]; then
        report "failed" "the closest two audit requests were ${worst}s apart where robots.txt asks for ${wanted_delay}s - the wait goes before the request, not after it"
        return
    fi

    report "success" "the audit read robots.txt, never once asked for the path it disallows, and kept every request at least ${wanted_delay}s apart as measured at the site"
}

Test04
