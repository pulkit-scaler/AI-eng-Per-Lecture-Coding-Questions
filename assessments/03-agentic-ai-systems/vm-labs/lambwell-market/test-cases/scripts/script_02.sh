#!/bin/bash
# TC02 (10 pts): the feed is harvested to exhaustion, in order and without repeats
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

Test02() {
    preflight || return
    require_artifact feed 02_feed || return

    local got token count total first last dups mono reason past_end pages
    got="$(artifact feed)"
    token="$(printf '%s' "$got" | jq -r '.token // empty')"
    require_issued_token "$token" "lot feed" || return

    total="$(expect_field '.feed_total')"
    if [ -z "$total" ] || [ "$total" = "null" ]; then
        report "failed" "Grader could not read the feed size from the site"
        return
    fi
    count="$(printf '%s' "$got" | jq -r '.lots | length')"
    if [ "$count" != "$total" ]; then
        report "failed" "the harvest recorded ${count} lots where the feed holds ${total} - it stopped before the feed ran out, or it stopped counting"
        return
    fi

    first="$(printf '%s' "$got" | jq -r '[.lots[].id] | min')"
    last="$(printf '%s' "$got" | jq -r '[.lots[].id] | max')"
    if [ "$first" != "1" ] || [ "$last" != "$total" ]; then
        report "failed" "the harvested lots run from ${first} to ${last} where the feed runs from 1 to ${total}"
        return
    fi
    dups="$(printf '%s' "$got" | jq -r '([.lots[].id] | length) - ([.lots[].id] | unique | length)')"
    if [ "${dups:-1}" != "0" ]; then
        report "failed" "${dups} lots were harvested more than once - a scroll that re-reads what it already has counts the same lot twice"
        return
    fi
    mono="$(printf '%s' "$got" | jq -r '[.lots[].id] as $i | ($i == ($i | sort))')"
    if [ "$mono" != "true" ]; then
        report "failed" "the harvested lots are not in the order the feed served them"
        return
    fi

    reason="$(printf '%s' "$got" | jq -r '.stop_reason // ""')"
    if [ ${#reason} -lt 6 ]; then
        report "failed" "the harvest does not say why it stopped scrolling - a scroll loop that ends without a reason cannot be told from one that gave up"
        return
    fi
    if printf '%s' "$reason" | grep -qi 'limit'; then
        report "failed" "the harvest stopped because it hit its own scroll limit, not because the feed ran out: ${reason}"
        return
    fi

    # The harvest has to have asked past the end of the feed: that empty answer
    # is what tells it there is nothing left.
    past_end="$(log_field '[.requests[] | select(.path | test("/feed/page.*after=" + $t))] | length' --arg t "$total" 2>/dev/null)"
    if [ -z "$past_end" ] || [ "$past_end" = "null" ]; then
        past_end="$(log_field '[.requests[] | select(.path | startswith("/feed/page"))] | length')"
        if [ "${past_end:-0}" -lt 2 ]; then
            report "failed" "the site served ${past_end} feed pages - the harvest has to keep asking until the feed answers with nothing"
            return
        fi
    fi
    pages="$(log_field '[.requests[] | select(.path | startswith("/feed/page"))] | length')"

    report "success" "all ${total} lots harvested in order with no duplicates over ${pages} feed pages, stopping because ${reason}"
}

Test02
