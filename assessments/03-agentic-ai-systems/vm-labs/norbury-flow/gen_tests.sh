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
exec 2>>"/tmp/norbury_tc${TC}.err"
STATUS_SENT=0
report() {
    if [ "$STATUS_SENT" -eq 1 ]; then return 0; fi
    STATUS_SENT=1
    print_status "$1" "$2"
}

LAB_DIR="${LAB_DIR:-/home/user/norbury-flow}"
DESK_URL="${DESK_URL:-http://127.0.0.1:8788}"
DESK_BIN="${DESK_BIN:-/opt/norbury-svc/flowsvc.py}"
GKEY_HEADER="X-Grader-Key: norbury-grader-nb6f"
GPATH="__nb6f"
PY="${PY:-python3}"
DEPS_READY_FILE="${DEPS_READY_FILE:-/var/log/norbury-lab/deps.ready}"
TIMING_LOG="${TIMING_LOG:-/tmp/norbury_timing.log}"
RUN_LOG="/tmp/norbury_tc${TC}.log"
export PYTHONDONTWRITEBYTECODE=1

# --- time budget -----------------------------------------------------------
# The one heavy import here is the symbolic algebra package, paid once per
# interpreter start. One deadline is shared across every start a check makes,
# because separate per-call bounds would add up past the portal cap.
CURL_MAX=${CURL_MAX:-5}
SVC_WAIT=${SVC_WAIT:-12}
DEPS_WAIT=${DEPS_WAIT:-90}
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
WORK="$(mktemp -d 2>/dev/null || echo /tmp/nb_work_$$)"
mkdir -p "$WORK" 2>/dev/null
chmod 700 "$WORK" 2>/dev/null
PROBE="${WORK}/probe.py"
RC_FILE="${WORK}/rc"
FLOWDIR="${WORK}/flows"
NONCE="${NONCE:-$(date +%s 2>/dev/null || echo 0)$$}"

# Grading runs as root while the learner is user. The gate WRITES its report
# into the project, so ownership goes back from the EXIT trap rather than from
# a success path.
on_exit() {
    local rc=$?
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

ensure_desk() {
    curl -sf -m "$CURL_MAX" "${DESK_URL}/health" >/dev/null 2>&1 && return 0
    [ -f "$DESK_BIN" ] || return 1
    spawn_detached /tmp/norbury_desk.log "$PY" "$DESK_BIN"
    local i
    for i in $(seq 1 "$SVC_WAIT"); do
        curl -sf -m 2 "${DESK_URL}/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

prepare_flows() {
    mkdir -p "$FLOWDIR" 2>/dev/null
    return 0
}

# The graded flows are written here rather than shipped, so the learner never
# sees them. Two shapes: one that may take four steps and one capped at two.
run_probe_prepare() {
    local prep="${WORK}/prep.py"
    cat > "$prep" <<'PREP'
import json
import os

FLOWDIR = os.environ["NB_FLOWS"]
TEMPLATE = ("You are the Fallowfield desk analyst. Search the archive first, "
            "then the open web, then write the briefing.")


def node(nid, kind, **config):
    return {"id": nid, "type": kind, "config": config}


def edge(source, target, port):
    return {"source": source, "target": target, "port": port}


def build(max_iterations, memory=True):
    nodes = [node("Input-9", "ChatInput"),
             node("Brief-9", "Prompt", template=TEMPLATE),
             node("Brain-9", "LanguageModel", model="norbury-14b",
                  temperature=0.15, api_key="***",
                  max_iterations=max_iterations),
             node("Out-9", "ChatOutput")]
    edges = [edge("Input-9", "Brain-9", "input"),
             edge("Brief-9", "Brain-9", "prompt"),
             edge("Brain-9", "Out-9", "output")]
    for index, tool in enumerate(("arxiv_search", "web_search", "summarise")):
        nid = "T%d-9" % index
        nodes.insert(3, node(nid, "Tool", tool=tool, max_results=4))
        edges.append(edge(nid, "Brain-9", "tools"))
    if memory:
        nodes.insert(3, node("Recall-9", "Memory", window=8))
        edges.append(edge("Recall-9", "Brain-9", "memory"))
    return {"name": "fallowfield-desk", "nodes": nodes, "edges": edges}


os.makedirs(FLOWDIR, exist_ok=True)
for name, flow in (("graded", build(4)),
                   ("capped", build(2)),
                   ("forgetful", build(4, memory=False))):
    with open(os.path.join(FLOWDIR, name + ".json"), "w") as handle:
        json.dump(flow, handle, indent=2)
print("ok")
PREP
    ( export NB_FLOWS="$FLOWDIR" && bounded 20 "$PY" "$prep" </dev/null ) 2>&1 \
        | tail -1
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
                NORBURY_DESK_URL="$DESK_URL" \
                NB_GKEY="norbury-grader-nb6f" \
                NB_GPATH="$GPATH" \
                NB_FLOWS="$FLOWDIR" \
                NB_NONCE="$NONCE" \
                NORBURY_BASE_URL="$DESK_URL" \
      && bounded "$budget" "$PY" "$PROBE" </dev/null ) >"$RUN_LOG" 2>&1
    LAST_RC=$?
    echo "$LAST_RC" >"$RC_FILE" 2>/dev/null
    grep -o 'LABJSON:.*' "$RUN_LOG" 2>/dev/null | tail -1 | sed 's/^LABJSON://'
    return "$LAST_RC"
}

CTL_RC=0
# run_ctl <run-id> <api-key-or-empty> <argv...> : run the learner command line
# and echo its LABJSON line. An empty key means the environment does not carry
# one, which is a case this lab grades.
run_ctl() {
    local rid="$1"; shift
    local key="$1"; shift
    local budget
    budget="$(budget_left)"
    if [ "$budget" -eq 0 ]; then CTL_RC=124; return 124; fi
    reset_run "$rid"
    ( cd "$LAB_DIR" 2>/dev/null \
      && export PYTHONPATH="$LAB_DIR" \
                NORBURY_BASE_URL="$DESK_URL" \
                NORBURY_RUN_ID="$rid" \
      && if [ -n "$key" ]; then export NORBURY_API_KEY="$key"; \
         else unset NORBURY_API_KEY; fi \
      && bounded "$budget" "$PY" flowctl.py "$@" </dev/null ) >"$RUN_LOG" 2>&1
    CTL_RC=$?
    echo "$CTL_RC" >"$RC_FILE" 2>/dev/null
    grep -o 'LABJSON:.*' "$RUN_LOG" 2>/dev/null | tail -1 | sed 's/^LABJSON://'
    return "$CTL_RC"
}

reset_run() {
    curl -sf -m "$CURL_MAX" -X POST -H "$GKEY_HEADER" \
        "${DESK_URL}/${GPATH}/reset?run=$1" >/dev/null 2>&1
    return 0
}

last_rc() { cat "$RC_FILE" 2>/dev/null || echo 0; }

fail_no_json() {
    report "failed" "${1} - no LABJSON line came back (exit $(last_rc)); the output is in ${RUN_LOG}"
}

field() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }

# Refuse an unstarted project in about a second, naming every plausible cause.
require_started() {
    local missing="" f
    for f in flow/spec.py flow/runtime.py flowctl.py; do
        [ -s "${LAB_DIR}/${f}" ] || missing="${missing} ${f}"
    done
    if [ -n "$missing" ]; then
        report "failed" "these files are missing or empty in ${LAB_DIR}:${missing}"
        return 1
    fi
    local untouched
    untouched="$(grep -l 'is not written yet' "${LAB_DIR}/flow"/*.py \
        "${LAB_DIR}/flowctl.py" 2>/dev/null | xargs -n1 basename 2>/dev/null \
        | tr '\n' ' ')"
    if [ -n "$untouched" ]; then
        report "failed" "these still hold the untouched starter: ${untouched}- write the two flow modules and flowctl.py, then run python3 check_local.py from ${LAB_DIR} before submitting"
        return 1
    fi
    return 0
}

preflight() {
    ensure_deps || { report "failed" "curl and jq are not installed yet; the setup job that installs them has not finished"; return 1; }
    ensure_desk || { report "failed" "the model endpoint is not reachable on ${DESK_URL}"; return 1; }
    prepare_flows || { report "failed" "Grader could not prepare its flows"; return 1; }
    require_started || return 1
    return 0
}
PRE
}

probe_header() {
cat <<'PH'
import json
import os
import sys
import urllib.request

sys.path.insert(0, os.getcwd())

GK = os.environ.get("NB_GKEY", "")
GP = os.environ.get("NB_GPATH", "")
BASE = os.environ.get("NORBURY_DESK_URL", "http://127.0.0.1:8788")
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


FLOWDIR = os.environ.get("NB_FLOWS", "")
NONCE = os.environ.get("NB_NONCE", "0")


def session(name):
    return "tc-%s-%s" % (name, NONCE)


def node(nid, kind, **config):
    return {"id": nid, "type": kind, "config": config}


def edge(source, target, port):
    return {"source": source, "target": target, "port": port}


def write_flow(name, flow):
    """Put a flow where the learner command line can be pointed at it."""
    os.makedirs(FLOWDIR, exist_ok=True)
    path = os.path.join(FLOWDIR, name + ".json")
    with open(path, "w") as handle:
        json.dump(flow, handle, indent=2)
    return path


def research_flow(tools=("arxiv_search", "web_search", "summarise"),
                  max_iterations=4, memory=True, model="norbury-14b",
                  temperature=0.15, template=None):
    """A flow of the shape a builder exports, with the knobs the checks move."""
    if template is None:
        template = ("You are the Fallowfield desk analyst. Search the archive "
                    "first, then the open web, then write the briefing.")
    nodes = [node("Input-9", "ChatInput"),
             node("Brief-9", "Prompt", template=template),
             node("Brain-9", "LanguageModel", model=model,
                  temperature=temperature, api_key="***",
                  max_iterations=max_iterations),
             node("Out-9", "ChatOutput")]
    edges = [edge("Input-9", "Brain-9", "input"),
             edge("Brief-9", "Brain-9", "prompt"),
             edge("Brain-9", "Out-9", "output")]
    for index, tool in enumerate(tools):
        nid = "T%d-9" % index
        nodes.insert(3, node(nid, "Tool", tool=tool, max_results=4))
        edges.append(edge(nid, "Brain-9", "tools"))
    if memory:
        nodes.insert(3, node("Recall-9", "Memory", window=8))
        edges.append(edge("Recall-9", "Brain-9", "memory"))
    return {"name": "fallowfield-desk", "nodes": nodes, "edges": edges}


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

FlowError = load("flow.spec", "FlowError")
validate = load("flow.spec", "validate")
load_flow = load("flow.spec", "load_flow")


def broken(kind):
    flow = research_flow()
    nodes = flow["nodes"]
    edges = flow["edges"]
    if kind == "unknown component":
        nodes.append(node("Mystery-9", "VectorStore", collection="notes"))
        edges.append(edge("Mystery-9", "Brain-9", "tools"))
        return flow, ("Mystery-9",)
    if kind == "an edge pointing at nothing":
        edges.append(edge("Ghost-9", "Brain-9", "tools"))
        return flow, ("Ghost-9",)
    if kind == "two outputs":
        nodes.append(node("Out-Extra", "ChatOutput"))
        edges.append(edge("Brain-9", "Out-Extra", "output"))
        return flow, ("ChatOutput",)
    if kind == "no input":
        flow["nodes"] = [n for n in nodes if n["type"] != "ChatInput"]
        flow["edges"] = [e for e in edges if e["source"] != "Input-9"]
        return flow, ("ChatInput",)
    if kind == "a tool that does not exist":
        for candidate in nodes:
            if candidate["type"] == "Tool":
                candidate["config"]["tool"] = "wikipedia_lookup"
                return flow, (candidate["id"],)
    if kind == "a model with no model named":
        for candidate in nodes:
            if candidate["type"] == "LanguageModel":
                candidate["config"].pop("model", None)
                return flow, (candidate["id"],)
    if kind == "a loop":
        nodes.append(node("Relay-9", "Prompt", template="loop"))
        edges.append(edge("Brain-9", "Relay-9", "prompt"))
        edges.append(edge("Relay-9", "Brain-9", "prompt"))
        # Either end of the cycle is a fair thing to name.
        return flow, ("Relay-9", "Brain-9")
    if kind == "an output nothing reaches":
        flow["edges"] = [e for e in edges if e.get("target") != "Out-9"]
        return flow, ("Out-9",)
    raise AssertionError(kind)


CASES = ["unknown component", "an edge pointing at nothing", "two outputs",
         "no input", "a tool that does not exist",
         "a model with no model named", "a loop", "an output nothing reaches"]

accepted = []
unnamed = []
for kind in CASES:
    flow, expected = broken(kind)
    try:
        validate(flow)
    except FlowError as exc:
        message = str(exc)
        if not any(name in message for name in expected):
            unnamed.append("%s: the message names none of %s (%r)"
                           % (kind, ", ".join(expected), message[:110]))
        continue
    except Exception as exc:
        die("validate raised %s on a flow with %s. A flow this runtime cannot "
            "run has to be refused as a FlowError, not crash: %s"
            % (type(exc).__name__, kind, exc))
    accepted.append(kind)

if accepted:
    die("these flows were accepted as runnable: %s. A prototype that half-runs "
        "is worse than one that refuses to start, because the half that did "
        "not run says nothing" % "; ".join(accepted))
if unnamed:
    die("%d refusal(s) did not say which node was the problem: %s"
        % (len(unnamed), "; ".join(unnamed[:2])))

for label, flow in (("the full research flow", research_flow()),
                    ("a flow with no tools and no memory",
                     research_flow(tools=(), memory=False))):
    try:
        validate(flow)
    except Exception as exc:
        die("%s was refused: %s: %s" % (label, type(exc).__name__, exc))

missing = os.path.join(FLOWDIR, "does-not-exist.json")
try:
    load_flow(missing)
except FlowError:
    pass
except Exception as exc:
    die("load_flow raised %s for a file that is not there; that is a FlowError "
        "like any other unrunnable flow: %s" % (type(exc).__name__, exc))
else:
    die("load_flow returned something for a file that does not exist")

win("all %d broken flows refused with the offending node named, both runnable "
    "flows accepted, and a missing file refused the same way" % len(CASES))
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

FlowError = load("flow.spec", "FlowError")
plan = load("flow.spec", "plan")

flow = research_flow()
try:
    order = plan(flow)
except Exception as exc:
    die("plan raised %s on a runnable flow: %s" % (type(exc).__name__, exc))

if not isinstance(order, list):
    die("plan must return a list of node ids, it returned %r"
        % type(order).__name__)
ids = [n["id"] for n in flow["nodes"]]
if sorted(order) != sorted(ids):
    die("plan returned %d entries for %d nodes; every node runs exactly once "
        "(%r)" % (len(order), len(ids), order))
if len(set(order)) != len(order):
    die("plan lists a node more than once")

position = {node_id: index for index, node_id in enumerate(order)}
for connection in flow["edges"]:
    source, target = connection["source"], connection["target"]
    if position[source] >= position[target]:
        die("plan puts %s at %d and %s at %d, but %s feeds %s. Everything a "
            "node consumes has to be resolved before it"
            % (source, position[source], target, position[target], source,
               target))

if order[0] != "Input-9":
    die("plan starts at %s; the flow starts where the message comes in"
        % order[0])
if order[-1] != "Out-9":
    die("plan ends at %s; the flow ends where the answer leaves" % order[-1])

small = research_flow(tools=(), memory=False)
small_order = plan(small)
if [n for n in small_order if n not in [x["id"] for x in small["nodes"]]]:
    die("plan invented nodes that are not in the flow: %r" % small_order)
if small_order.index("Brain-9") <= small_order.index("Brief-9"):
    die("the prompt has to be resolved before the model that uses it")

looped = research_flow()
looped["nodes"].append(node("Relay-9", "Prompt", template="loop"))
looped["edges"].append(edge("Brain-9", "Relay-9", "prompt"))
looped["edges"].append(edge("Relay-9", "Brain-9", "prompt"))
try:
    plan(looped)
except FlowError:
    pass
except Exception as exc:
    die("plan raised %s on a flow with a loop in it, rather than refusing it "
        "as a FlowError: %s" % (type(exc).__name__, exc))
else:
    die("plan returned an order for a flow whose nodes feed each other in a "
        "circle; there is no order that satisfies it")

win("plan orders every node once, never before what it consumes, starting at "
    "the input and ending at the output, and refuses a flow with a loop")
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
    local prepared missing_key ran
    prepared="$(run_probe_prepare)"
    if [ "$prepared" != "ok" ]; then
        report "failed" "Grader could not write its flow: ${prepared}"
        return
    fi
    missing_key="$(run_ctl "tc03-nokey" "" run "${FLOWDIR}/graded.json" \
        --message "Research sparse retrieval routing" --session "nokey-${NONCE}")"
    NOKEY_RC="$(last_rc)"
    ran="$(run_ctl "tc03" "nb-live-8842" run "${FLOWDIR}/graded.json" \
        --message "Research sparse retrieval routing" --session "cfg-${NONCE}")"
    RUN_RC="$(last_rc)"
    if [ -z "$ran" ]; then
        report "failed" "flowctl run printed no LABJSON line (exit ${RUN_RC}); its output is in ${RUN_LOG}"
        return
    fi
    if [ "$RUN_RC" -ne 0 ]; then
        report "failed" "flowctl run exited ${RUN_RC} on a flow that is runnable and a credential that is present; its output is in ${RUN_LOG}"
        return
    fi
    if [ "$NOKEY_RC" -eq 0 ]; then
        report "failed" "with no credential in the environment the run still succeeded. The export carries a placeholder where the key was, and a runtime that treats that as a credential ships a flow nobody can authenticate"
        return
    fi
    export NB_NOKEY="$missing_key"
cat > "$PROBE" <<'PY'
BODY03
probe_header
cat <<'BODY03B'

from flow_kit import API_KEY_ENV

nokey = os.environ.get("NB_NOKEY") or ""
if API_KEY_ENV not in nokey:
    die("the run without a credential failed, but its message does not name "
        "the environment variable to set. That message is the whole difference "
        "between a five-second fix and an afternoon: %r" % nokey[:160])

seen = trace("tc03")
calls = seen.get("model_calls", 0)
if not calls:
    die("the model endpoint was never called")
if seen.get("placeholder_seen"):
    die("the placeholder from the export was sent to the endpoint %d time(s) "
        "as if it were a credential" % seen["placeholder_seen"])

for config in seen.get("configs") or []:
    if config.get("model") != "norbury-14b":
        die("the flow declares the model norbury-14b and the endpoint was "
            "asked for %r. A configuration that stays in the JSON is not "
            "configuration" % config.get("model"))
    if abs(float(config.get("temperature") or 0) - 0.15) > 1e-6:
        die("the flow declares a temperature of 0.15 and the endpoint saw %r"
            % config.get("temperature"))

systems = seen.get("systems") or []
if not systems or "Fallowfield desk analyst" not in systems[0]:
    die("the prompt node text never reached the endpoint; the first system "
        "message it saw was %r" % (systems[0][:120] if systems else None))

offered = seen.get("offered") or []
expected = ["arxiv_search", "web_search", "summarise"]
for names in offered:
    if sorted(names) != sorted(expected):
        die("the flow wires %s and the endpoint was offered %s. The tools a "
            "model can reach for are the ones the flow connected, no more and "
            "no fewer" % (expected, names))

win("model, temperature, prompt text and the three wired tools all reached the "
    "endpoint, the export placeholder never did, and a missing credential "
    "failed with a message naming %s" % API_KEY_ENV)
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
    local prepared full capped
    prepared="$(run_probe_prepare)"
    if [ "$prepared" != "ok" ]; then
        report "failed" "Grader could not write its flows: ${prepared}"
        return
    fi
    full="$(run_ctl "tc04-full" "nb-live-8842" run "${FLOWDIR}/graded.json" \
        --message "Research sparse retrieval routing" --session "full-${NONCE}")"
    capped="$(run_ctl "tc04-capped" "nb-live-8842" run "${FLOWDIR}/capped.json" \
        --message "Research sparse retrieval routing" --session "cap-${NONCE}")"
    if [ -z "$full" ] || [ -z "$capped" ]; then
        report "failed" "flowctl run printed no LABJSON line for one of the two flows; its output is in ${RUN_LOG}"
        return
    fi
    export NB_FULL="$full" NB_CAPPED="$capped"
cat > "$PROBE" <<'PY'
BODY04
probe_header
cat <<'BODY04B'

full = json.loads(os.environ["NB_FULL"])
capped = json.loads(os.environ["NB_CAPPED"])
replies = _get("/" + GP + "/replies")
order = replies["order"]
texts = replies["tool_replies"]

seen = trace("tc04-full")
ran = [call["tool"] for call in seen.get("tool_calls") or []]
if ran != order:
    die("the flow wires %s and the tools that actually ran were %s, in that "
        "order. The loop runs the tool the model asked for, not a list of its "
        "own" % (order, ran))
for call in seen.get("tool_calls") or []:
    if call.get("max_results") != 4:
        die("the tool node sets max_results to 4 and %s was called with %r; "
            "the settings on a node are part of what it is"
            % (call["tool"], call.get("max_results")))

if list(full.get("tool_calls") or []) != order:
    die("the run reports tool calls %r while the endpoint recorded %r"
        % (full.get("tool_calls"), ran))
reply = str(full.get("reply") or "")
if len(reply.strip()) < 20:
    die("the flow returned %r after three tool calls" % reply[:80])
evidence = [name for name in order if texts[name][:24] in reply]
if not evidence:
    die("nothing any of the tools found appears in the answer. The observations "
        "have to go back to the model, or the tools were run for nothing")
if full.get("stopped_early"):
    die("a flow allowed four steps stopped early after three tool calls")

seen = trace("tc04-capped")
ran = [call["tool"] for call in seen.get("tool_calls") or []]
if len(ran) != 2:
    die("the flow caps the loop at two steps and %d tool call(s) were made: "
        "%s. The cap is what stops a prototype loop becoming a bill"
        % (len(ran), ran))
if ran != order[:2]:
    die("the two steps that ran were %s; the model asks for them in the order "
        "%s" % (ran, order[:2]))
if not seen.get("forced_finals"):
    die("the loop hit its cap and stopped without asking the model to wrap up. "
        "Returning the last tool output raw is not an answer")
if not capped.get("stopped_early"):
    die("the run does not record that it stopped early, so nobody reading the "
        "log would know the answer is partial")
if len(str(capped.get("reply") or "").strip()) < 20:
    die("the capped run returned %r; running out of steps still has to end in "
        "something to say" % str(capped.get("reply"))[:80])

win("three tools called in the order the model asked for with their node "
    "settings, their findings in the answer, and a flow capped at two steps "
    "stopped there and still produced a wrap-up")
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
    local prepared first second other forgetful_a forgetful_b
    prepared="$(run_probe_prepare)"
    if [ "$prepared" != "ok" ]; then
        report "failed" "Grader could not write its flows: ${prepared}"
        return
    fi
    first="$(run_ctl "tc05-a" "nb-live-8842" run "${FLOWDIR}/graded.json" \
        --message "Research sparse retrieval routing" --session "mem-${NONCE}")"
    second="$(run_ctl "tc05-b" "nb-live-8842" run "${FLOWDIR}/graded.json" \
        --message "What did I ask you first?" --session "mem-${NONCE}")"
    other="$(run_ctl "tc05-c" "nb-live-8842" run "${FLOWDIR}/graded.json" \
        --message "What did I ask you first?" --session "fresh-${NONCE}")"
    forgetful_a="$(run_ctl "tc05-d" "nb-live-8842" run "${FLOWDIR}/forgetful.json" \
        --message "Research sparse retrieval routing" --session "nomem-${NONCE}")"
    forgetful_b="$(run_ctl "tc05-e" "nb-live-8842" run "${FLOWDIR}/forgetful.json" \
        --message "What did I ask you first?" --session "nomem-${NONCE}")"
    if [ -z "$first" ] || [ -z "$second" ] || [ -z "$other" ] \
       || [ -z "$forgetful_b" ]; then
        report "failed" "one of the five runs printed no LABJSON line; the last output is in ${RUN_LOG}"
        return
    fi
    export NB_FIRST="$first" NB_SECOND="$second" NB_OTHER="$other" \
           NB_FORGETFUL="$forgetful_b" NB_SESSION="mem-${NONCE}"
cat > "$PROBE" <<'PY'
BODY05
probe_header
cat <<'BODY05B'

first = json.loads(os.environ["NB_FIRST"])
second = json.loads(os.environ["NB_SECOND"])
other = json.loads(os.environ["NB_OTHER"])
forgetful = json.loads(os.environ["NB_FORGETFUL"])

if "routing" not in str(second.get("reply") or "").lower():
    die("the second turn in the same session did not recall the first. The "
        "flow wires a Memory node, so the conversation so far has to go back "
        "to the model. It replied %r" % str(second.get("reply"))[:120])
if int(second.get("turns") or 0) < 2:
    die("the second turn reports %r turns in the session" % second.get("turns"))

if "routing" in str(other.get("reply") or "").lower():
    die("a different session recalled a conversation it was not part of. Each "
        "session is its own conversation, which is what lets one deployment "
        "serve more than one person")

if "routing" in str(forgetful.get("reply") or "").lower():
    die("a flow with no Memory node still carried the earlier turn. What the "
        "runtime does is what the flow wires, not what would be nice")

path = os.path.join(os.getcwd(), "runs",
                    "%s.json" % os.environ["NB_SESSION"])
if not os.path.exists(path):
    die("no run log at runs/%s.json. A deployment nobody can look back at is "
        "a deployment nobody can debug" % os.environ["NB_SESSION"])
try:
    with open(path) as handle:
        record = json.load(handle)
except Exception as exc:
    die("the run log is not readable JSON: %s" % exc)

turns = record.get("turns") or []
if len(turns) < 2:
    die("the run log holds %d turn(s) after two turns in that session"
        % len(turns))
if "routing" not in str(turns[0].get("message") or "").lower():
    die("the first turn in the log is %r" % str(turns[0].get("message"))[:80])
if not turns[0].get("reply"):
    die("the log records the first message with no reply beside it")
if list(turns[0].get("tool_calls") or []) != ["arxiv_search", "web_search",
                                              "summarise"]:
    die("the log records the tool calls for the first turn as %r"
        % (turns[0].get("tool_calls"),))

win("a second turn in the same session recalled the first, a different session "
    "did not, a flow with no memory node did not, and the run log carries both "
    "turns with the tools each one used")
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
