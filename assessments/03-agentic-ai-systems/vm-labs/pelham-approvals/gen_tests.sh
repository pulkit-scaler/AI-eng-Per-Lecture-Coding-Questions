#!/bin/bash
# Regenerate test-cases/scripts/script_01..05.sh from one shared preamble.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$DIR/test-cases/scripts"
mkdir -p "$OUT"

preamble() {
cat <<'PRE'
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "/usr/local/bin/judge/test/common.sh" 2>/dev/null || source "$DIR/common.sh" 2>/dev/null || true
type print_status >/dev/null 2>&1 || print_status() { echo "RESULT:$1 | $2"; }

# The platform helper ends with `trap ... ERR`, and sourcing it installs that
# trap inside THIS shell. An ERR trap fires on any non-zero simple command
# regardless of set -e - a deliberate `return 1` from a guard included - and its
# handler prints an internal error and exits. That lands a second line AFTER our
# verdict, and the judge grades the LAST line, so the verdict is thrown away and
# the submission is reported as having no test cases at all: an empty panel.
# Drop the inherited trap before anything can trip it.
trap - ERR
set +eE

# --- one verdict per script -------------------------------------------------
# Nothing below may abort the script: a check must always end in exactly one
# verdict, so there is no set -e and no set -u anywhere in this file.
TC="$(basename "${BASH_SOURCE[0]}" .sh | sed 's/[^0-9]//g')"

# The judge captures stdout and stderr together and grades the LAST line, so one
# stray line on stderr - a job-control notice, a tool warning - voids the verdict
# exactly as the ERR trap did. Park this check stderr in a file on the VM:
# the diagnostics stay readable, and stdout can only ever end in the verdict.
exec 2>>"/tmp/pelham_tc${TC}.err"
STATUS_SENT=0
report() {
    if [ "$STATUS_SENT" -eq 1 ]; then return 0; fi
    STATUS_SENT=1
    print_status "$1" "$2"
}

LAB_DIR="${LAB_DIR:-/home/user/pelham-approvals}"
DESK_URL="${DESK_URL:-http://127.0.0.1:8766}"
DESK_BIN="${DESK_BIN:-/opt/pelham-svc/expensesvc.py}"
GKEY_HEADER="X-Grader-Key: pelham-grader-pm3x"
GPATH="__pm3x"
PY="${PY:-python3}"
DEPS_READY_FILE="${DEPS_READY_FILE:-/var/log/pelham-lab/deps.ready}"
TIMING_LOG="${TIMING_LOG:-/tmp/pelham_timing.log}"
RUN_LOG="/tmp/pelham_tc${TC}.log"
export PYTHONDONTWRITEBYTECODE=1

# --- time budget -----------------------------------------------------------
# The one heavy import here is the symbolic algebra package, paid once per
# interpreter start. One deadline is shared across every start a check makes,
# because separate per-call bounds would add up past the portal cap.
CURL_MAX=${CURL_MAX:-5}
SVC_WAIT=${SVC_WAIT:-12}
DEPS_WAIT=${DEPS_WAIT:-90}
SVC_START_WAIT=${SVC_START_WAIT:-30}
RUN_BUDGET=${RUN_BUDGET:-40}
HARD_DEADLINE=${HARD_DEADLINE:-100}

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

# Graded inputs are written into a directory only root can read, and it goes
# away with the check.
WORK="$(mktemp -d 2>/dev/null || echo /tmp/pm_work_$$)"
mkdir -p "$WORK" 2>/dev/null
chmod 700 "$WORK" 2>/dev/null
PROBE="${WORK}/probe.py"
RC_FILE="${WORK}/rc"

# Grading runs as root while the learner is user. The gate WRITES its report
# into the project, so ownership goes back from the EXIT trap rather than from
# a success path.
on_exit() {
    local rc=$?
    stop_our_service
    # Hand the project back whenever a lab user exists, rather than only when
    # LAB_DIR happens to sit under /home/user. Gating on the path meant the
    # ordering matrix, which runs under /tmp, silently skipped the repair - so
    # the one harness written to catch a root-owned project could not.
    if id -u user >/dev/null 2>&1; then
        chown -R user:user "$LAB_DIR" >/dev/null 2>&1
    fi
    rm -rf "$WORK" >/dev/null 2>&1
    printf 'script_%s %ss\n' "$TC" "$SECONDS" >>"$TIMING_LOG" 2>/dev/null || true
    report "failed" "TC${TC} ended without reaching a verdict (rc=${rc})"
}
trap on_exit EXIT

# The readiness file is the ONLY thing that means the detached install has
# resolved. It is deliberately not proxied by "curl and jq are present": those
# two are installed in the foreground now, so a proxy on them is always true and
# a check would run before the rest of the environment exists.
ensure_deps() {
    [ -f "$DEPS_READY_FILE" ] && return 0
    local i
    for i in $(seq 1 "$DEPS_WAIT"); do
        [ -f "$DEPS_READY_FILE" ] && return 0
        sleep 1
    done
    # The wait ran out. Carry on if the tools a check itself needs are here, so
    # a stalled install still produces a real verdict rather than a timeout.
    command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 && return 0
    return 1
}

# A VM whose the LangGraph package never installed is a broken VM, not a wrong answer. Say so,
# instead of reporting that the learner's own module does not import.
require_lab_dep() {
    "$PY" -c "import langgraph" >/dev/null 2>&1 && return 0
    report "failed" "the LangGraph package, which this lab runs on, is not installed on this VM, so nothing here can be graded - this is an environment fault, not your code. The install log is at /var/log/pelham-lab/deps.log"
    return 1
}

ensure_desk() {
    curl -sf -m "$CURL_MAX" "${DESK_URL}/health" >/dev/null 2>&1 && return 0
    [ -f "$DESK_BIN" ] || return 1
    spawn_detached /tmp/pelham_desk.log "$PY" "$DESK_BIN"
    local i
    for i in $(seq 1 "$SVC_WAIT"); do
        curl -sf -m 2 "${DESK_URL}/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

SVC_URL="${SVC_URL:-http://127.0.0.1:8767}"
SVC_LOG="${SVC_LOG:-/tmp/pelham_service.log}"

# Thread ids have to be unique per grading run: the approval service keeps its
# threads for as long as it is up, and a thread that was decided on the previous
# run is not waiting for anybody.
NONCE="${NONCE:-$(date +%s 2>/dev/null || echo 0)$$}"

# If the learner left their service running, use it and leave it alone. If not,
# start one - and stop it again from the EXIT trap, because a root-owned process
# holding their port is a lab the learner cannot get back into.
SVC_PID_FILE="${WORK}/svc.pid"

ensure_service() {
    curl -sf -m "$CURL_MAX" "${SVC_URL}/health" >/dev/null 2>&1 && return 0
    [ -f "${LAB_DIR}/server.py" ] || return 1
    local port
    port="$(printf '%s' "$SVC_URL" | sed 's|.*:||; s|/.*||')"
    ( cd "$LAB_DIR" && export PYTHONPATH="$LAB_DIR" \
        PELHAM_SERVICE_PORT="$port" PELHAM_DESK_URL="$DESK_URL" \
        PYTHONDONTWRITEBYTECODE=1 \
      && spawn_detached "$SVC_LOG" "$PY" server.py \
      && echo $! >"$SVC_PID_FILE" )
    local i
    for i in $(seq 1 "$SVC_START_WAIT"); do
        curl -sf -m 2 "${SVC_URL}/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

stop_our_service() {
    [ -s "$SVC_PID_FILE" ] || return 0
    local pid
    pid="$(cat "$SVC_PID_FILE" 2>/dev/null)"
    [ -n "$pid" ] || return 0
    kill "$pid" >/dev/null 2>&1
    sleep 1
    kill -9 "$pid" >/dev/null 2>&1
    return 0
}

budget_left() {
    local left
    left=$(( HARD_DEADLINE - SECONDS ))
    if [ "$left" -lt 6 ]; then echo 0; return; fi
    if [ "$left" -lt "$RUN_BUDGET" ]; then echo "$left"; else echo "$RUN_BUDGET"; fi
}

LAST_RC=0
# run_probe : run $PROBE inside the learner project and echo its LABJSON line.
# The body is written to a file rather than piped, because a backgrounded
# watchdog leaves a heredoc on stdin empty.
run_probe() {
    local budget
    budget="$(budget_left)"
    if [ "$budget" -eq 0 ]; then LAST_RC=124; return 124; fi
    ( cd "$LAB_DIR" 2>/dev/null \
      && export PYTHONPATH="$LAB_DIR" \
                PELHAM_DESK_URL="$DESK_URL" \
                PM_GKEY="pelham-grader-pm3x" \
                PM_GPATH="$GPATH" \
                PM_SVC_URL="$SVC_URL" \
                PM_NONCE="$NONCE" \
      && bounded "$budget" "$PY" "$PROBE" </dev/null ) >"$RUN_LOG" 2>&1
    LAST_RC=$?
    echo "$LAST_RC" >"$RC_FILE" 2>/dev/null
    grep -o 'LABJSON:.*' "$RUN_LOG" 2>/dev/null | tail -1 | sed 's/^LABJSON://'
    return "$LAST_RC"
}

last_rc() { cat "$RC_FILE" 2>/dev/null || echo 0; }

fail_no_json() {
    report "failed" "${1} - no LABJSON line came back (exit $(last_rc)); the output is in ${RUN_LOG}"
}

field() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }

# Refuse an unstarted project in about a second, naming every plausible cause.
require_started() {
    local missing="" f
    for f in bdi/nodes.py bdi/graph.py server.py; do
        [ -s "${LAB_DIR}/${f}" ] || missing="${missing} ${f}"
    done
    if [ -n "$missing" ]; then
        report "failed" "these files are missing or empty in ${LAB_DIR}:${missing}"
        return 1
    fi
    local untouched
    untouched="$(grep -l 'is not written yet' "${LAB_DIR}/bdi"/*.py \
        "${LAB_DIR}/server.py" 2>/dev/null | xargs -n1 basename 2>/dev/null \
        | tr '\n' ' ')"
    if [ -n "$untouched" ]; then
        report "failed" "these still hold the untouched starter: ${untouched}- write the nodes, the graph and the service, then run python3 check_local.py from ${LAB_DIR} before submitting"
        return 1
    fi
    return 0
}

preflight() {
    ensure_deps || { report "failed" "curl and jq are not installed yet; the setup job that installs them has not finished"; return 1; }
    ensure_desk || { report "failed" "the finance desk is not reachable on ${DESK_URL}"; return 1; }
    require_lab_dep || return 1
    require_started || return 1
    ensure_service || { report "failed" "the approval service did not come up on ${SVC_URL}; start it with python3 server.py from ${LAB_DIR} and check ${SVC_LOG}"; return 1; }
    return 0
}
PRE
}

probe_header() {
cat <<'PH'
import json
import os
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.getcwd())

GK = os.environ.get("PM_GKEY", "")
GP = os.environ.get("PM_GPATH", "")
BASE = os.environ.get("PELHAM_DESK_URL", "http://127.0.0.1:8766")
OUT = {}


def emit():
    print("LABJSON:" + json.dumps(OUT))


def die(why):
    OUT["ok"] = False
    OUT["why"] = why
    emit()
    sys.exit(0)


def win(summary):
    OUT["ok"] = True
    OUT["summary"] = summary
    emit()
    sys.exit(0)


def _get(path):
    request = urllib.request.Request(BASE + path, headers={"X-Grader-Key": GK})
    return json.loads(urllib.request.urlopen(request, timeout=8).read())


def reset(run):
    request = urllib.request.Request(BASE + "/" + GP + "/reset?run=" + run,
                                     headers={"X-Grader-Key": GK}, method="POST")
    urllib.request.urlopen(request, timeout=8).read()


def trace(run):
    return _get("/" + GP + "/trace?run=" + run)


def expected():
    return _get("/" + GP + "/expected")


SVC = os.environ.get("PM_SVC_URL", "http://127.0.0.1:8767")
NONCE = os.environ.get("PM_NONCE", "0")


def thread(name):
    return "tc-%s-%s" % (name, NONCE)


def _request(method, url, payload=None, timeout=15):
    data = None if payload is None else json.dumps(payload).encode()
    headers = {} if data is None else {"Content-Type": "application/json"}
    request = urllib.request.Request(url, data=data, headers=headers,
                                     method=method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, json.loads(response.read().decode() or "{}")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode()
        try:
            return exc.code, json.loads(body or "{}")
        except Exception:
            return exc.code, {"raw": body[:200]}
    except Exception as exc:
        die("the approval service did not answer %s %s: %s: %s"
            % (method, url, type(exc).__name__, exc))


def submit(thread_id, claim):
    return _request("POST", SVC + "/claims",
                    {"thread_id": thread_id, "claim": claim})


def analysis_calls():
    """How much work the finance desk has been given so far."""
    return int(trace("default").get("analysis_calls", 0))


def snapshot(thread_id):
    return _request("GET", SVC + "/claims/" + thread_id)


def callback(value):
    return _request("POST", SVC + "/webhook/approval", {"value": value})


def load(module, name):
    try:
        loaded = __import__(module, fromlist=[name])
    except Exception as exc:
        die("%s does not import: %s: %s" % (module.replace(".", "/") + ".py",
                                            type(exc).__name__, exc))
    if not hasattr(loaded, name):
        die("%s defines no %s" % (module.replace(".", "/") + ".py", name))
    return getattr(loaded, name)
PH
}

verdict_body() {
cat <<'VB'
    local raw ok why summary
    raw="$(run_probe)"
    if [ -z "$raw" ]; then
        fail_no_json "TC${TC}"
        return
    fi
    ok="$(field "$raw" .ok)"
    why="$(field "$raw" .why)"
    summary="$(field "$raw" .summary)"
    if [ "$ok" = "true" ]; then
        report "success" "$summary"
    else
        if [ -z "$why" ] || [ "$why" = "null" ]; then
            why="TC${TC} did not report why it failed; see ${RUN_LOG}"
        fi
        report "failed" "$why"
    fi
VB
}


write_01() {
cat <<'BODY01'
Test01() {
    preflight || return
cat > "$PROBE" <<'PY'
BODY01
probe_header
cat <<'BODY01B'

calls_before = analysis_calls()

ORDINARY = {"employee": "Priya Sharma", "amount_usd": 45, "category": "meals",
            "description": "Team lunch during sprint planning"}
OTHER = {"employee": "Devin Cole", "amount_usd": 61, "category": "travel",
         "description": "Airport transfer for the Leeds site visit"}

first = thread("bdi-a")
status, opened = submit(first, ORDINARY)
if status != 200:
    die("posting a claim returned HTTP %d: %r" % (status, opened))
if opened.get("pending"):
    die("a claim of 45 in a valid category with an ordinary description was "
        "sent for human review; below the threshold it should clear on its own")

status, state = snapshot(first)
if status != 200:
    die("reading the claim back returned HTTP %d: %r" % (status, state))

beliefs = state.get("beliefs")
if not isinstance(beliefs, dict) or not beliefs:
    die("the state carries no beliefs. Beliefs are what the agent knew when it "
        "decided, and an auditor reads them six months later")
for key, want in (("employee", ORDINARY["employee"]),
                  ("amount_usd", ORDINARY["amount_usd"]),
                  ("category", ORDINARY["category"])):
    if str(beliefs.get(key)) != str(want):
        die("beliefs.%s is %r, expected %r" % (key, beliefs.get(key), want))
if int(beliefs.get("policy_threshold_usd") or 0) != 100:
    die("beliefs do not record the policy threshold of 100 that the decision "
        "was made against (found %r)" % beliefs.get("policy_threshold_usd"))
valid = beliefs.get("valid_categories") or []
for category in ("meals", "travel", "software", "office_supplies"):
    if category not in valid:
        die("beliefs do not record the approved category list; %s is missing"
            % category)

desires = state.get("desires")
if not isinstance(desires, list) or len(desires) < 2:
    die("the state carries no desires. Those are the business goals the "
        "process owner signed off, and they belong in the state where a "
        "reviewer can check them")

intentions = state.get("intentions") or []
if not intentions:
    die("the state carries no intentions, so nothing records what the agent "
        "committed to doing")
if not any(isinstance(i, dict) and i.get("action") for i in intentions):
    die("no intention names an action; an intention is a committed plan, not a "
        "sentiment")

log = state.get("audit_log") or []
if len(log) < 3:
    die("the audit log holds %d entries for a claim that was perceived, "
        "deliberated over and finalised" % len(log))
joined = " ".join(str(entry).lower() for entry in log)
for stage in ("perceive", "deliberate", "final"):
    if stage not in joined:
        die("the audit log never mentions the %s stage: %r" % (stage, log[:4]))

status_text = str(state.get("final_status") or "")
if "approv" not in status_text.lower():
    die("final_status is %r for a claim that cleared on its own" % status_text)

# The desires must be the same goals on a different claim: they are set by the
# people who own the process, not generated per claim.
second = thread("bdi-b")
submit(second, OTHER)
_, other_state = snapshot(second)
if (other_state.get("desires") or []) != desires:
    die("the desires changed between two claims. Business goals stay stable; "
        "only the intention formed in response to them changes")

given = analysis_calls() - calls_before
if given < 2:
    die("the finance desk was given %d analysis call(s) for two claims. "
        "Deliberation has to consult the analyst, not decide on the amount "
        "alone" % given)

win("beliefs, desires and intentions are first-class state, the audit log "
    "records all three stages in order, and the desires held steady across two "
    "different claims")
PY
BODY01B
verdict_body
cat <<'BODY01C'
}

Test01
BODY01C
}

write_02() {
cat <<'BODY02'
Test02() {
    preflight || return
cat > "$PROBE" <<'PY'
BODY02
probe_header
cat <<'BODY02B'

calls_before = analysis_calls()

# label, claim, should it pause, why
CASES = [
    ("under the threshold, valid category, ordinary description",
     {"employee": "Priya Sharma", "amount_usd": 45, "category": "meals",
      "description": "Team lunch during sprint planning"}, False),
    ("over the threshold",
     {"employee": "Neha Iyer", "amount_usd": 850, "category": "software",
      "description": "JetBrains team license renewal"}, True),
    ("exactly at the threshold",
     {"employee": "Tomas Reidy", "amount_usd": 100, "category": "meals",
      "description": "Client lunch after the quarterly review"}, True),
    ("a category that is not on the approved list",
     {"employee": "Anya Belov", "amount_usd": 40, "category": "consulting",
      "description": "Two hours of advice on the migration"}, True),
    ("small and valid, but the description is one a finance team reviews",
     {"employee": "Ravi Menon", "amount_usd": 40, "category": "meals",
      "description": "gift card for the team"}, True),
]

wrong = []
for index, (label, claim, should_pause) in enumerate(CASES):
    ident = thread("route-%d" % index)
    status, opened = submit(ident, claim)
    if status != 200:
        die("posting the claim for %s returned HTTP %d: %r"
            % (label, status, opened))
    paused = bool(opened.get("pending"))
    if paused != should_pause:
        wrong.append("%s: %s" % (label, "paused" if paused else "cleared"))

if wrong:
    die("%d of %d claims were routed the wrong way. %s"
        % (len(wrong), len(CASES), "; ".join(wrong)))

given = analysis_calls() - calls_before
if given < len(CASES):
    die("the finance desk was given %d analysis call(s) for %d claims; every "
        "claim has to be put to the analyst" % (given, len(CASES)))

win("all %d claims routed correctly, including the one that is small and in a "
    "valid category but carries wording the analyst flags" % len(CASES))
PY
BODY02B
verdict_body
cat <<'BODY02C'
}

Test02
BODY02C
}

write_03() {
cat <<'BODY03'
Test03() {
    preflight || return
cat > "$PROBE" <<'PY'
BODY03
probe_header
cat <<'BODY03B'

BIG = {"employee": "Neha Iyer", "amount_usd": 850, "category": "software",
       "description": "JetBrains team license renewal"}
SMALL = {"employee": "Priya Sharma", "amount_usd": 45, "category": "meals",
         "description": "Team lunch during sprint planning"}

waiting = thread("pause")
status, opened = submit(waiting, BIG)
if status != 200:
    die("posting the claim returned HTTP %d: %r" % (status, opened))
if not opened.get("pending"):
    die("a claim of 850 did not pause for a person")

payload = opened.get("interrupt")
if not isinstance(payload, dict):
    die("the response carries no surfaced payload for the reviewer; whoever "
        "has to decide needs to be shown something (got %r)" % (payload,))
claim = payload.get("claim") or {}
if str(claim.get("employee")) != BIG["employee"] \
        or str(claim.get("amount_usd")) != str(BIG["amount_usd"]):
    die("the surfaced payload does not carry the claim itself: %r" % (claim,))
options = [str(o).lower() for o in (payload.get("options") or [])]
if "approve" not in options or "reject" not in options:
    die("the surfaced payload does not offer approve and reject as the choices "
        "(got %r)" % (payload.get("options"),))
reasoning = str(payload.get("agent_reasoning") or "")
if len(reasoning.strip()) < 10:
    die("the surfaced payload carries no reasoning, so the reviewer is being "
        "asked to decide with nothing in front of them")

status, state = snapshot(waiting)
if status != 200:
    die("reading the paused claim returned HTTP %d: %r" % (status, state))
if not state.get("pending"):
    die("a separate request reports the claim as no longer waiting. The pause "
        "has to be held in the checkpoint, not in the request that started it")
if state.get("final_status"):
    die("final_status is already %r while the claim is still waiting for a "
        "person. Nothing downstream may be committed before the decision"
        % state.get("final_status"))
if state.get("human_decision"):
    die("human_decision is already %r before anybody decided"
        % state.get("human_decision"))

before = len(state.get("audit_log") or [])

# A second claim on its own thread must not disturb the first.
other = thread("parallel")
status, second = submit(other, SMALL)
if status != 200:
    die("posting a second claim returned HTTP %d: %r" % (status, second))
if second.get("pending"):
    die("the second claim paused when it should have cleared")

status, again = snapshot(waiting)
if not again.get("pending"):
    die("starting a second claim ended the first one. Each thread is its own "
        "conversation and they do not share state")
if (again.get("beliefs") or {}).get("employee") != BIG["employee"]:
    die("the paused claim beliefs now read %r; the second claim overwrote them"
        % ((again.get("beliefs") or {}).get("employee"),))
if len(again.get("audit_log") or []) != before:
    die("the paused claim audit log changed from %d to %d entries while it was "
        "waiting" % (before, len(again.get("audit_log") or [])))

# Reading the state is not re-running the agent.
calls_after_two_claims = analysis_calls()
snapshot(waiting)
snapshot(waiting)
if analysis_calls() != calls_after_two_claims:
    die("reading a claim back put more work through the analyst. Looking at a "
        "paused claim must not re-run the agent")

win("the graph pauses with the claim, the reasoning and the two options "
    "surfaced, nothing is committed while it waits, the pause survives "
    "separate requests, and a second thread leaves it alone")
PY
BODY03B
verdict_body
cat <<'BODY03C'
}

Test03
BODY03C
}

write_04() {
cat <<'BODY04'
Test04() {
    preflight || return
cat > "$PROBE" <<'PY'
BODY04
probe_header
cat <<'BODY04B'

BIG = {"employee": "Neha Iyer", "amount_usd": 850, "category": "software",
       "description": "JetBrains team license renewal"}
ODD = {"employee": "Anya Belov", "amount_usd": 260, "category": "travel",
       "description": "Rail fare and one night in Leeds"}

yes = thread("approve")
no = thread("reject")
for ident, claim in ((yes, BIG), (no, ODD)):
    status, opened = submit(ident, claim)
    if status != 200 or not opened.get("pending"):
        die("the claim on %s did not pause (HTTP %d, %r)"
            % (ident, status, opened))

_, before_yes = snapshot(yes)
log_before = list(before_yes.get("audit_log") or [])
intentions_before = len(before_yes.get("intentions") or [])

status, result = callback("approve|" + yes)
if status != 200:
    die("the approval callback returned HTTP %d: %r" % (status, result))

_, after_yes = snapshot(yes)
final = str(after_yes.get("final_status") or "")
if "approv" not in final.lower() or "human" not in final.lower():
    die("after a person approved it, final_status is %r; it has to record both "
        "the outcome and that a person made it" % final)
if str(after_yes.get("human_decision") or "").lower() != "approve":
    die("human_decision is %r after an approval" % after_yes.get("human_decision"))
if after_yes.get("pending"):
    die("the claim is still waiting after it was decided")

log_after = list(after_yes.get("audit_log") or [])
if len(log_after) < len(log_before) + 2:
    die("the audit log went from %d entries to %d. Resuming has to record both "
        "the decision that came back and the outcome it produced"
        % (len(log_before), len(log_after)))
if log_after[:len(log_before)] != log_before:
    die("the entries written before the pause are not still there, in order, "
        "afterwards. An audit log is append-only")
if len(after_yes.get("intentions") or []) <= intentions_before:
    die("the intentions did not grow. Finalising commits the process to a next "
        "action, and that is an intention")

status, result = callback("reject|" + no)
if status != 200:
    die("the rejection callback returned HTTP %d: %r" % (status, result))
_, after_no = snapshot(no)
final_no = str(after_no.get("final_status") or "")
if "reject" not in final_no.lower() or "human" not in final_no.lower():
    die("after a person rejected it, final_status is %r" % final_no)

_, recheck = snapshot(yes)
if str(recheck.get("final_status")) != str(after_yes.get("final_status")):
    die("deciding the second claim changed the outcome of the first, from %r "
        "to %r" % (after_yes.get("final_status"), recheck.get("final_status")))

win("a decision arriving by callback resumes the right thread, records the "
    "outcome and the person who made it, appends to the audit log without "
    "rewriting it, and leaves the other thread alone")
PY
BODY04B
verdict_body
cat <<'BODY04C'
}

Test04
BODY04C
}

write_05() {
cat <<'BODY05'
Test05() {
    preflight || return
cat > "$PROBE" <<'PY'
BODY05
probe_header
cat <<'BODY05B'

BIG = {"employee": "Neha Iyer", "amount_usd": 850, "category": "software",
       "description": "JetBrains team license renewal"}

decided = thread("replay")
status, opened = submit(decided, BIG)
if status != 200 or not opened.get("pending"):
    die("the claim did not pause (HTTP %d, %r)" % (status, opened))
status, _ = callback("approve|" + decided)
if status != 200:
    die("the first callback returned HTTP %d" % status)

_, settled = snapshot(decided)
final = settled.get("final_status")
log_len = len(settled.get("audit_log") or [])

# The reviewer clicked the button twice.
status, replay = callback("approve|" + decided)
if status == 200:
    die("a second callback on an already decided claim was accepted. A button "
        "clicked twice must not decide a claim twice")
if not 400 <= status < 500:
    die("a replayed callback answered HTTP %d; it has to be refused as a "
        "client error, not fail as a server error" % status)
_, after_replay = snapshot(decided)
if after_replay.get("final_status") != final:
    die("the replayed callback changed the outcome from %r to %r"
        % (final, after_replay.get("final_status")))
if len(after_replay.get("audit_log") or []) != log_len:
    die("the replayed callback added %d audit entries for a decision that had "
        "already been made"
        % (len(after_replay.get("audit_log") or []) - log_len))

# A decision arriving for something that does not exist.
status, unknown = callback("approve|" + thread("never-existed"))
if not 400 <= status < 500:
    die("a callback for a thread that does not exist answered HTTP %d; an "
        "unknown thread is a bad request, not a crash" % status)

# A decision nobody defined.
still_waiting = thread("bad-decision")
submit(still_waiting, BIG)
status, refused = callback("maybe|" + still_waiting)
if not 400 <= status < 500:
    die("a callback carrying an unrecognised decision answered HTTP %d"
        % status)
_, unchanged = snapshot(still_waiting)
if not unchanged.get("pending"):
    die("an unrecognised decision took the claim out of review anyway")
if unchanged.get("final_status"):
    die("an unrecognised decision produced a final status of %r"
        % unchanged.get("final_status"))

# A malformed callback body.
status, _ = callback("nonsense-with-no-separator")
if not 400 <= status < 500:
    die("a callback with no thread in it answered HTTP %d" % status)

# After all of that the service still works.
status, health = _request("GET", SVC + "/health")
if status != 200:
    die("the service is no longer healthy after the refused callbacks "
        "(HTTP %d)" % status)
fresh = thread("after-refusals")
status, opened = submit(fresh, {"employee": "Priya Sharma", "amount_usd": 45,
                                "category": "meals",
                                "description": "Team lunch after the release"})
if status != 200 or opened.get("pending"):
    die("a fresh claim after the refused callbacks returned HTTP %d, %r"
        % (status, opened))

win("a replayed decision is refused and changes nothing, unknown threads and "
    "unrecognised decisions are refused as client errors, and the service is "
    "still serving afterwards")
PY
BODY05B
verdict_body
cat <<'BODY05C'
}

Test05
BODY05C
}

for n in 01 02 03 04 05; do
    {
        echo '#!/bin/bash'
        echo "# GENERATED by gen_tests.sh - do not hand-edit."
        preamble
        echo
        "write_$n"
    } > "$OUT/script_$n.sh"
    chmod +x "$OUT/script_$n.sh"
    bash -n "$OUT/script_$n.sh"
    echo "wrote script_$n.sh"
done
