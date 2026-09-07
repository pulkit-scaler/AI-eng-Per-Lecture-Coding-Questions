#!/bin/bash
# Regenerate test-cases/scripts/script_01..05.sh from one shared preamble.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT_DIR="$DIR/test-cases/scripts"
mkdir -p "$OUT_DIR"

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
PRE
}

write_01() {
cat <<'BODY01'
Test01() {
    preflight || return
    require_artifact listings 01_listings || return

    local got want token count wanted_count mismatched asked
    got="$(artifact listings)"
    token="$(printf '%s' "$got" | jq -r '.token // empty')"
    require_issued_token "$token" "stall register" || return

    wanted_count="$(expect_field '.stall_count')"
    if [ -z "$wanted_count" ] || [ "$wanted_count" = "null" ]; then
        report "failed" "Grader could not read the stall register from the site"
        return
    fi
    count="$(printf '%s' "$got" | jq -r '.stalls | length')"
    if [ "$count" != "$wanted_count" ]; then
        report "failed" "the harvest recorded ${count} stalls where the register holds ${wanted_count} - the table fills in a row at a time, so a harvest that reads it too early is short"
        return
    fi

    # Field for field against what the site holds, so a harvest that guessed at
    # the shape of the table does not pass on the count alone.
    want="$(curl -sf -m "$CURL_MAX" -H "$GKEY" "${SITE_URL}/${GPATH}/expect" 2>/dev/null)"
    mismatched="$(jq -nr --argjson a "$got" --argjson b "$want" '
        [ $b.stalls[] as $s
          | ($a.stalls[] | select(.stall == $s.stall)) as $h
          | select(($h.trader != $s.trader) or ($h.goods != $s.goods)
                   or (($h.since | tonumber) != $s.since))
          | $s.stall ] | join(",")' 2>/dev/null)"
    if [ -n "$mismatched" ]; then
        report "failed" "these stalls came back with the wrong details: ${mismatched}"
        return
    fi
    if [ "$(jq -nr --argjson a "$got" --argjson b "$want" '
            ([$a.stalls[].stall] | sort) == ([$b.stalls[].stall] | sort)' 2>/dev/null)" != "true" ]; then
        report "failed" "the stalls in the artefact are not the stalls in the register"
        return
    fi

    asked="$(log_field '[.requests[] | select(.path | startswith("/stalls"))] | length')"
    if [ "${asked:-0}" -lt 1 ]; then
        report "failed" "the site was never asked for the stall register - the artefact did not come from a page load"
        return
    fi

    report "success" "all ${count} stalls harvested field for field from a page that fills in a row at a time, quoting a token the site really issued"
}

Test01
BODY01
}

write_02() {
cat <<'BODY02'
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
BODY02
}

write_03() {
cat <<'BODY03'
Test03() {
    preflight || return
    require_artifact orders 03_session || return

    local got token count wanted ids cookie logins signed refused
    got="$(artifact orders)"
    token="$(printf '%s' "$got" | jq -r '.token // empty')"
    require_issued_token "$token" "standing orders" || return

    wanted="$(expect_field '.order_ids | join(",")')"
    if [ -z "$wanted" ] || [ "$wanted" = "null" ]; then
        report "failed" "Grader could not read the standing orders from the site"
        return
    fi
    ids="$(printf '%s' "$got" | jq -r '[.orders[].order] | sort | join(",")')"
    if [ "$ids" != "$wanted" ]; then
        report "failed" "the harvest recorded orders ${ids} where the signed-in page lists ${wanted}"
        return
    fi

    if [ ! -s "${OUT}/state.json" ]; then
        report "failed" "there is no saved session at ${OUT}/state.json - signing in once and saving what it left behind is the whole point of this step"
        return
    fi
    cookie="$(jq -r '[.cookies[]? | select(.name | test("session"; "i"))] | length' "${OUT}/state.json" 2>/dev/null)"
    if [ "${cookie:-0}" -lt 1 ]; then
        report "failed" "the saved session holds no session cookie - a state file without it will not open the orders page"
        return
    fi

    # Each sign-in has to be worth more than one signed-in page load. Counting
    # sign-ins alone would punish a learner who simply ran the harvest twice:
    # the site log outlives any one run, so what is asserted is the ratio, which
    # a second clean run leaves unchanged and signing in per page does not.
    logins="$(log_field '[.requests[] | select(.path | startswith("/login")) | select(.status == 302)] | length')"
    if [ "${logins:-0}" -lt 1 ]; then
        report "failed" "the site never accepted a sign-in - the orders page is behind one"
        return
    fi
    signed="$(log_field '[.requests[] | select(.path | startswith("/orders")) | select(.session)] | length')"
    if [ "${signed:-0}" -lt 1 ]; then
        report "failed" "the orders page was never fetched with a session on it"
        return
    fi
    if [ "$(( signed ))" -lt "$(( logins * 2 ))" ]; then
        report "failed" "the site saw ${logins} sign-ins for ${signed} signed-in page loads - saving the session and reusing it means one sign-in serves more than one page, and signing in again for each page is not reuse"
        return
    fi
    refused="$(log_field '[.requests[] | select(.path | startswith("/orders")) | select(.status == 401)] | length')"
    if [ "${refused:-0}" -ne 0 ]; then
        report "failed" "the orders page was refused ${refused} time(s) - a fresh context opened with the saved session should never be turned away"
        return
    fi

    report "success" "signed in once, saved the session, and read all four standing orders back in a fresh context without ever being turned away"
}

Test03
BODY03
}

write_04() {
cat <<'BODY04'
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
BODY04
}

write_05() {
cat <<'BODY05'
Test05() {
    preflight || return
    require_artifact audit 04_audit || return

    local got trace entries snapshots named
    got="$(artifact audit)"
    named="$(printf '%s' "$got" | jq -r '.trace_file // empty')"
    if [ -z "$named" ]; then
        report "failed" "the audit artefact does not say where it put its trace"
        return
    fi

    trace="${OUT}/trace.zip"
    if [ ! -s "$trace" ]; then
        report "failed" "there is no trace at ${trace} - the trace is the first thing to reach for when a harvest goes wrong, so the audit records one"
        return
    fi
    if ! bounded "$JQ_MAX" unzip -tq "$trace" >/dev/null 2>&1; then
        report "failed" "${trace} is not a readable archive - a trace that will not open is not a trace"
        return
    fi

    entries="$(bounded "$JQ_MAX" unzip -Z1 "$trace" 2>/dev/null | wc -l | tr -d ' ')"
    if [ "${entries:-0}" -lt 3 ]; then
        report "failed" "the trace holds only ${entries} entries - a trace of a real run carries its events and its snapshots"
        return
    fi
    if ! bounded "$JQ_MAX" unzip -Z1 "$trace" 2>/dev/null | grep -q 'trace.trace'; then
        report "failed" "the trace has no event log in it - it was not recorded from a browser context"
        return
    fi
    # The network log has to be a real one. An archive assembled by hand can
    # name a file trace.network; filling it with the traffic of four page loads
    # is another matter. Screenshot count is deliberately not asserted: a fast
    # run legitimately captures fewer of them.
    local netbytes
    netbytes="$(bounded "$JQ_MAX" unzip -p "$trace" trace.network 2>/dev/null | wc -c | tr -d ' ')"
    if [ "${netbytes:-0}" -lt 200 ]; then
        report "failed" "the network log in the trace is ${netbytes} bytes - nothing here recorded four page loads"
        return
    fi
    snapshots="$(bounded "$JQ_MAX" unzip -Z1 "$trace" 2>/dev/null | grep -c 'resources/')"
    if ! bounded "$JQ_MAX" unzip -p "$trace" trace.trace 2>/dev/null | grep -q 'audit='; then
        report "failed" "the trace does not mention the pages the audit visited - it is not a trace of this run"
        return
    fi

    report "success" "the audit left a readable trace of ${entries} entries with ${snapshots} snapshots, recording the very pages it visited"
}

Test05
BODY05
}

for n in 01 02 03 04 05; do
    case "$n" in
        01) t="the stall register is harvested complete, not early" ;;
        02) t="the feed is harvested to exhaustion, in order and without repeats" ;;
        03) t="one sign-in, saved and reused in a fresh context" ;;
        04) t="robots.txt is read and obeyed, and the pace is kept" ;;
        05) t="the run left a trace that really opens" ;;
    esac
    {
        echo '#!/bin/bash'
        echo "# TC${n} (10 pts): ${t}"
        preamble
        echo ""
        "write_${n}"
    } > "$OUT_DIR/script_${n}.sh"
    chmod +x "$OUT_DIR/script_${n}.sh"
    bash -n "$OUT_DIR/script_${n}.sh"
    echo "  wrote script_${n}.sh"
done

cat > "$OUT_DIR/common.sh" <<'CS'
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
