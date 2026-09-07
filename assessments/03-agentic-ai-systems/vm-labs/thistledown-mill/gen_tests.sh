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
exec 2>>"/tmp/thistledown_tc${TC}.err"
STATUS_SENT=0
report() {
    if [ "$STATUS_SENT" -eq 1 ]; then return 0; fi
    STATUS_SENT=1
    print_status "$1" "$2"
}

LAB_DIR="${LAB_DIR:-/home/user/thistledown-mill}"
MODEL_URL="${MODEL_URL:-http://127.0.0.1:8433}"
MODEL_BIN="${MODEL_BIN:-/opt/thistledown-svc/millsvc.py}"
GKEY="X-Grader-Key: thistledown-grader-tm8q"
GPATH="__tm8q"
PY="${PY:-python3}"
DEPS_READY_FILE="${DEPS_READY_FILE:-/var/log/thistledown-lab/deps.ready}"
TIMING_LOG="${TIMING_LOG:-/tmp/thistledown_timing.log}"
export PYTHONDONTWRITEBYTECODE=1
# The mill runs its planning model locally and its runs are not interactive.
# Exported here as well as in the learner profile, because the judge is a
# non-login root shell and will not read a profile script.
export CREWAI_TRACING_ENABLED=false
export CREWAI_DISABLE_TELEMETRY=true
export OTEL_SDK_DISABLED=true
export THISTLEDOWN_MODEL_URL="${MODEL_URL}/v1"
export OPENAI_API_KEY="${OPENAI_API_KEY:-thistledown-local}"
export OPENAI_API_BASE="${MODEL_URL}/v1"
export OPENAI_BASE_URL="${MODEL_URL}/v1"

# --- time budget -----------------------------------------------------------
# crewai is a heavy import - several seconds cold - and a planning run is two or
# three model turns on top of that. HARD_DEADLINE is a ceiling on the whole
# script, and every learner invocation shrinks its own bound as that deadline
# approaches, so a check that runs two jobs cannot add up past the portal cap.
CURL_MAX=${CURL_MAX:-5}
SVC_WAIT=${SVC_WAIT:-12}
DEPS_WAIT=${DEPS_WAIT:-30}
RUN_BUDGET=${RUN_BUDGET:-55}
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

# Grading runs as root while the learner is user. A planning run writes into
# out/ and crewai writes a per-project data file under the learner home, so
# ownership goes back from the EXIT trap rather than from a success path.
on_exit() {
    local rc=$?
    case "$LAB_DIR" in
        /home/user/*) chown -R user:user "$LAB_DIR" >/dev/null 2>&1 ;;
    esac
    [ -d /home/user/.local/share/thistledown-mill ] && \
        chown -R user:user /home/user/.local/share/thistledown-mill >/dev/null 2>&1
    printf 'script_%s %ss\n' "$TC" "$SECONDS" >>"$TIMING_LOG" 2>/dev/null || true
    report "failed" "TC${TC} ended without reaching a verdict (rc=${rc})"
}
trap on_exit EXIT

ensure_deps() {
    [ -f "$DEPS_READY_FILE" ] && return 0
    "$PY" -c 'import crewai' >/dev/null 2>&1 && return 0
    local i
    for i in $(seq 1 "$DEPS_WAIT"); do
        sleep 1
        [ -f "$DEPS_READY_FILE" ] && return 0
    done
    "$PY" -c 'import crewai' >/dev/null 2>&1
}

ensure_model() {
    curl -sf -m "$CURL_MAX" "${MODEL_URL}/health" >/dev/null 2>&1 && return 0
    [ -f "$MODEL_BIN" ] || return 1
    spawn_detached /tmp/thistledown_model.log "$PY" "$MODEL_BIN"
    local i
    for i in $(seq 1 "$SVC_WAIT"); do
        curl -sf -m 2 "${MODEL_URL}/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

trace_field() {
    curl -sf -m "$CURL_MAX" -H "$GKEY" "${MODEL_URL}/${GPATH}/trace?run=$1" \
        2>/dev/null | jq -r "$2"
}

reset_run() {
    curl -sf -m "$CURL_MAX" -X POST -H "$GKEY" \
        "${MODEL_URL}/${GPATH}/reset?run=$1" >/dev/null 2>&1
    return 0
}

# These helpers are called inside a command substitution, which is a subshell,
# so nothing they assign survives the call. The log path is therefore derived
# from the check number alone: it is the same string on both sides, and a
# failure message can always name a file that exists.
RUN_LOG="/tmp/thistledown_tc${TC}.log"
LAST_RC=0

# The learner program never reads its source from stdin. A background job in a
# non-interactive shell has stdin on /dev/null, so a heredoc piped into
# `python3 -` arrives empty exactly when the shell has no timeout(1) and the
# watchdog path is taken - silently, on some hosts and not others. Write the
# body out and run the file.
run_python() {
    local budget="$1" tmp rc
    shift
    tmp="$(mktemp /tmp/thistledown_body_XXXXXX)" || return 1
    cat > "$tmp"
    ( cd "$LAB_DIR" 2>/dev/null && export PYTHONPATH="$LAB_DIR" \
      && bounded "$budget" "$PY" "$tmp" "$@" </dev/null ) >"$RUN_LOG" 2>&1
    rc=$?
    rm -f "$tmp"
    return $rc
}

budget_left() {
    local left
    left=$(( HARD_DEADLINE - SECONDS ))
    if [ "$left" -lt 6 ]; then echo 0; return; fi
    if [ "$left" -lt "$RUN_BUDGET" ]; then echo "$left"; else echo "$RUN_BUDGET"; fi
}

# tool_batch <json-array-of-{tool,args}> -> a JSON array of results.
# One interpreter start however many calls are in it: importing crewai costs
# several seconds on this image, and grading cost here is interpreter starts
# rather than computation.
tool_batch() {
    local budget
    budget="$(budget_left)"
    if [ "$budget" -eq 0 ]; then LAST_RC=124; return 124; fi
    run_python "$budget" "$1" <<'TOOLBODY'
import json
import sys

from mill.tools import RunQueryTool, StockLookupTool

TOOLS = {"run_query": RunQueryTool(), "stock_lookup": StockLookupTool()}
results = []
for item in json.loads(sys.argv[1]):
    tool, args = item["tool"], item.get("args") or {}
    try:
        results.append({"tool": tool, "text": str(TOOLS[tool].run(**args))})
    except NotImplementedError as exc:
        results.append({"tool": tool, "error": "not implemented",
                        "detail": str(exc)})
    except Exception as exc:
        results.append({"tool": tool, "raised": type(exc).__name__,
                        "detail": str(exc)[:200]})
print("TOOLJSON:" + json.dumps(results))
TOOLBODY
    LAST_RC=$?
    grep -o 'TOOLJSON:.*' "$RUN_LOG" 2>/dev/null | head -1 | cut -c10-
    return "$LAST_RC"
}

# inspect_crew, with the python body on stdin -> its INSPECTJSON line
inspect_crew() {
    local budget
    budget="$(budget_left)"
    if [ "$budget" -eq 0 ]; then LAST_RC=124; return 124; fi
    run_python "$budget"
    LAST_RC=$?
    grep -o 'INSPECTJSON:.*' "$RUN_LOG" 2>/dev/null | head -1 | cut -c13-
    return "$LAST_RC"
}

# run_order <order> -> exit status of one planning job; the note is on disk.
run_order() {
    local budget
    budget="$(budget_left)"
    if [ "$budget" -eq 0 ]; then LAST_RC=124; return 124; fi
    ( cd "$LAB_DIR" 2>/dev/null && export PYTHONPATH="$LAB_DIR" \
      && bounded "$budget" "$PY" -m mill.main --order "$1" </dev/null \
    ) >"$RUN_LOG" 2>&1
    LAST_RC=$?
    return "$LAST_RC"
}

db_hash() {
    sha256sum "${LAB_DIR}/data/mill.db" 2>/dev/null | cut -d' ' -f1
}

require_started() {
    local missing="" untouched=""
    [ -s "${LAB_DIR}/config/agents.yaml" ] || missing="${missing} config/agents.yaml"
    [ -s "${LAB_DIR}/config/tasks.yaml" ]  || missing="${missing} config/tasks.yaml"
    [ -s "${LAB_DIR}/mill/tools.py" ]      || missing="${missing} mill/tools.py"
    [ -s "${LAB_DIR}/mill/crew.py" ]       || missing="${missing} mill/crew.py"
    if [ -n "$missing" ]; then
        report "failed" "these files are missing or empty in ${LAB_DIR}:${missing}"
        return 1
    fi
    # One gate per file, and never joined with &&. Joined, a learner who wrote
    # one of the four and left the others sailed through to a probe failure
    # that named a tool instead of the file they had not opened yet.
    grep -q 'the crew is not built yet' "${LAB_DIR}/mill/crew.py" 2>/dev/null \
        && untouched="${untouched} mill/crew.py"
    grep -q 'is not written yet' "${LAB_DIR}/mill/tools.py" 2>/dev/null \
        && untouched="${untouched} mill/tools.py"
    grep -q 'TODO' "${LAB_DIR}/config/agents.yaml" 2>/dev/null \
        && untouched="${untouched} config/agents.yaml"
    grep -q 'TODO' "${LAB_DIR}/config/tasks.yaml" 2>/dev/null \
        && untouched="${untouched} config/tasks.yaml"
    if [ -n "$untouched" ]; then
        report "failed" "these are still the untouched starters in ${LAB_DIR}:${untouched} - write them, then run python3 check_local.py from ${LAB_DIR} before submitting"
        return 1
    fi
    return 0
}

preflight() {
    ensure_deps || { report "failed" "crewai is not installed on this VM yet - see /var/log/thistledown-lab/pip.log"; return 1; }
    require_started || return 1
    return 0
}

preflight_model() {
    preflight || return 1
    ensure_model || { report "failed" "the planning model is not reachable on ${MODEL_URL}"; return 1; }
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

    local got item text rows want
    # Four calls, one interpreter start. No planning model is involved in any of
    # them, so nothing here can be blamed on the model.
    got="$(tool_batch '[
        {"tool": "stock_lookup", "args": {"yarn_code": "YN-LN22"}},
        {"tool": "run_query", "args": {"sql": "SELECT cloth, yarn_code FROM cloth_spec WHERE cloth = \u0027linen twill\u0027"}},
        {"tool": "run_query", "args": {"sql": "SELECT yarn_code FROM yarn_stock"}},
        {"tool": "run_query", "args": {"sql": "SELECT nosuchcolumn FROM yarn_stock"}},
        {"tool": "run_query", "args": {"sql": "SELECT COUNT(*) AS n FROM looms WHERE available = 1"}},
        {"tool": "run_query", "args": {"sql": "SELECT bin FROM yarn_stock WHERE yarn_code = \u0027YN-SK03\u0027"}}
    ]')"
    if [ -z "$got" ]; then
        report "failed" "the tools produced nothing at all - see ${RUN_LOG}"
        return
    fi
    if [ "$(printf '%s' "$got" | jq -r '[.[] | select(.error == "not implemented")] | length')" != "0" ]; then
        report "failed" "$(printf '%s' "$got" | jq -r '[.[] | select(.error) | .tool] | unique | join(" and ")') is not written yet"
        return
    fi
    if [ "$(printf '%s' "$got" | jq -r '[.[] | select(.raised)] | length')" != "0" ]; then
        report "failed" "$(printf '%s' "$got" | jq -r '[.[] | select(.raised) | "\(.tool) raised \(.raised)"] | unique | join("; ")') - a tool has to hand a problem back as text so the agent can read it"
        return
    fi

    text="$(printf '%s' "$got" | jq -r '.[0].text')"
    if ! printf '%s' "$text" | grep -q 'YN-LN22'; then
        report "failed" "stock_lookup on YN-LN22 did not mention the yarn: ${text}"
        return
    fi
    for want in 9 45; do
        if ! printf '%s' "$text" | grep -qw "$want"; then
            report "failed" "stock_lookup on YN-LN22 did not report ${want}, which is in the stock table: ${text}"
            return
        fi
    done

    text="$(printf '%s' "$got" | jq -r '.[1].text')"
    if ! printf '%s' "$text" | grep -q 'YN-LN22'; then
        report "failed" "run_query did not return the yarn that linen twill is specified in: ${text}"
        return
    fi

    rows="$(printf '%s' "$got" | jq -r '.[2].text' | grep -c 'YN-')"
    if [ "${rows:-0}" -lt 6 ]; then
        report "failed" "run_query returned ${rows} yarn rows where the store holds six"
        return
    fi

    text="$(printf '%s' "$got" | jq -r '.[3].text')"
    if [ -z "$text" ] || [ "$text" = "null" ]; then
        report "failed" "run_query said nothing at all about a column that does not exist"
        return
    fi

    # Two queries the store has to be read to answer: an aggregate over the
    # looms and one column of one row. Neither can be prepared in advance.
    text="$(printf '%s' "$got" | jq -r '.[4].text')"
    if ! printf '%s' "$text" | grep -qw '4'; then
        report "failed" "run_query counted the available looms as \"$(printf '%s' "$text" | tr '\n' ' ' | head -c 60)\" where the shed has four"
        return
    fi
    text="$(printf '%s' "$got" | jq -r '.[5].text')"
    if ! printf '%s' "$text" | grep -q 'B-04'; then
        report "failed" "run_query did not return the bin for YN-SK03: $(printf '%s' "$text" | tr '\n' ' ' | head -c 60)"
        return
    fi

    report "success" "both tools answered with the figures in the store, returned every row of the yarn table, and handed a database error back as text instead of raising - in one interpreter start"
}

Test01
B01

cat > "$BODY/02" <<'B02'
Test02() {
    preflight || return

    local before after got n bad
    before="$(db_hash)"
    if [ -z "$before" ]; then
        report "failed" "there is no mill database at ${LAB_DIR}/data/mill.db"
        return
    fi

    # Six statements that must all be refused, in one interpreter start.
    got="$(tool_batch '[
        {"tool": "run_query", "args": {"sql": "DELETE FROM yarn_stock"}},
        {"tool": "run_query", "args": {"sql": "UPDATE yarn_stock SET cones_on_hand = 0"}},
        {"tool": "run_query", "args": {"sql": "DROP TABLE looms"}},
        {"tool": "run_query", "args": {"sql": "SELECT 1; DROP TABLE looms"}},
        {"tool": "run_query", "args": {"sql": "SELECT yarn_code FROM yarn_stock; DELETE FROM looms"}},
        {"tool": "run_query", "args": {"sql": "PRAGMA writable_schema = 1"}}
    ]')"
    if [ -z "$got" ]; then
        report "failed" "run_query produced nothing for any of the write attempts - see ${RUN_LOG}"
        return
    fi
    n="$(printf '%s' "$got" | jq -r 'length')"
    if [ "$n" != "6" ]; then
        report "failed" "only ${n} of the six write attempts came back at all - see ${RUN_LOG}"
        return
    fi
    if [ "$(printf '%s' "$got" | jq -r '[.[] | select(.raised)] | length')" != "0" ]; then
        report "failed" "run_query raised on $(printf '%s' "$got" | jq -r '[.[] | select(.raised) | .raised] | unique | join(", ")') instead of refusing in words - an agent cannot read an exception"
        return
    fi
    # A refusal must say so, and must not carry rows back.
    bad="$(printf '%s' "$got" | jq -r '
        [.[] | select((.text // "") | test("refus|not allowed|only|reject|one statement"; "i") | not) | .text // "empty"]
        | join(" /// ")')"
    if [ -n "$bad" ]; then
        report "failed" "one of the write attempts was answered with \"$(printf '%s' "$bad" | head -c 110)\" - a refusal has to say that it is one"
        return
    fi
    bad="$(printf '%s' "$got" | jq -r '[.[] | select((.text // "") | test("^(yarn_code|loom|cloth)"; "i"))] | length')"
    if [ "${bad:-0}" != "0" ]; then
        report "failed" "one of the write attempts came back with rows - a statement that is not a plain SELECT has to be refused before it runs"
        return
    fi

    after="$(db_hash)"
    if [ "$before" != "$after" ]; then
        report "failed" "the mill database changed while those statements were tried - the connection has to be opened read-only so a bypass physically cannot write"
        return
    fi

    report "success" "six write and multi-statement attempts were each refused in words, none returned rows, and the database is byte for byte what it was before"
}

Test02
B02

cat > "$BODY/03" <<'B03'
Test03() {
    preflight || return

    local got agents tasks process tooled field
    got="$(inspect_crew <<'INSPECTBODY'
import json

import yaml

from mill import millkit
from mill.crew import build_crew

crew = build_crew()
agents_cfg = yaml.safe_load((millkit.CONFIG_DIR / "agents.yaml").read_text())
tasks_cfg = yaml.safe_load((millkit.CONFIG_DIR / "tasks.yaml").read_text())


def norm(text):
    return " ".join(str(text or "").split())


agents = []
for agent in crew.agents:
    agents.append({
        "role": norm(getattr(agent, "role", "")),
        "goal": norm(getattr(agent, "goal", "")),
        "backstory": norm(getattr(agent, "backstory", "")),
        "tools": sorted(getattr(t, "name", "") for t in (getattr(agent, "tools", None) or [])),
        "max_iter": getattr(agent, "max_iter", None),
    })

tasks = []
for task in crew.tasks:
    tasks.append({
        "description": norm(getattr(task, "description", "")),
        "expected_output": norm(getattr(task, "expected_output", "")),
    })

wanted_agents = {key: {field: norm(value.get(field))
                       for field in ("role", "goal", "backstory")}
                 for key, value in (agents_cfg or {}).items()}
wanted_tasks = {key: {field: norm(value.get(field))
                      for field in ("description", "expected_output")}
                for key, value in (tasks_cfg or {}).items()}

print("INSPECTJSON:" + json.dumps({
    "agents": agents,
    "tasks": tasks,
    "process": str(getattr(crew, "process", "")),
    "config_agents": wanted_agents,
    "config_tasks": wanted_tasks,
    "max_iter_expected": millkit.MAX_ITER,
}))
INSPECTBODY
)"
    if [ -z "$got" ]; then
        report "failed" "build_crew() did not produce an inspectable crew - see ${RUN_LOG}"
        return
    fi

    agents="$(printf '%s' "$got" | jq -r '.agents | length')"
    tasks="$(printf '%s' "$got" | jq -r '.tasks | length')"
    if [ "$agents" != "2" ] || [ "$tasks" != "2" ]; then
        report "failed" "the crew has ${agents} agents and ${tasks} tasks where the mill runs two of each"
        return
    fi

    process="$(printf '%s' "$got" | jq -r '.process')"
    if ! printf '%s' "$process" | grep -qi 'sequential'; then
        report "failed" "the crew process is ${process} - the analyst has to finish before the planner starts"
        return
    fi

    # Every agent and task the crew holds has to come from the files, not from
    # strings written into the Python. Each comparison brackets both sides: in
    # jq, `sort == (...)` inside a pipe evaluates the right-hand side against
    # the piped value rather than the root, which silently compares an array
    # against null.
    for field in role goal; do
        if [ "$(printf '%s' "$got" | jq --arg f "$field" \
                '([.agents[][$f]] | sort) == ([.config_agents[][$f]] | sort)' \
                2>/dev/null)" != "true" ]; then
            report "failed" "the agent ${field}s on the crew are not the ${field}s in config/agents.yaml - the crew has to be built from the configuration files"
            return
        fi
    done
    for field in description expected_output; do
        if [ "$(printf '%s' "$got" | jq --arg f "$field" \
                '([.tasks[][$f]] | sort) == ([.config_tasks[][$f]] | sort)' \
                2>/dev/null)" != "true" ]; then
            report "failed" "the task ${field}s on the crew are not the ones in config/tasks.yaml"
            return
        fi
    done
    if [ "$(printf '%s' "$got" | jq '[.agents[].backstory | select(length > 0)] | length' 2>/dev/null)" != "2" ]; then
        report "failed" "one of the agents has no backstory - a role with no backstory has nothing to hold it to the method"
        return
    fi

    tooled="$(printf '%s' "$got" | jq -r '[.agents[] | select(.tools | index("run_query"))] | length')"
    if [ "$tooled" != "1" ]; then
        report "failed" "${tooled} of the two agents hold run_query - only the one that reads the store may have it"
        return
    fi
    if [ "$(printf '%s' "$got" | jq '.max_iter_expected as $cap | all(.agents[]; .max_iter == $cap)' 2>/dev/null)" != "true" ]; then
        report "failed" "an agent is not capped at the mill turn limit of $(printf '%s' "$got" | jq -r '.max_iter_expected') - a planning agent without a cap can keep asking forever"
        return
    fi

    report "success" "two agents and two tasks, all four built from the configuration files, running sequentially, with the database tool held by exactly one agent and both capped at the mill turn limit"
}

Test03
B03

# ---------------------------------------------------------------- TC04 ------
cat > "$BODY/04" <<'B04'
Test04() {
    preflight_model || return

    local order="TM-4312" note calls tools queries
    reset_run "$order"
    rm -f "${LAB_DIR}/out/${order}.md" 2>/dev/null

    run_order "$order"
    if [ "$LAST_RC" -ne 0 ]; then
        report "failed" "the planning job on ${order} exited ${LAST_RC}: $(tail -3 "$RUN_LOG" 2>/dev/null | tr '\n' ' ' | head -c 220)"
        return
    fi
    note="${LAB_DIR}/out/${order}.md"
    if [ ! -s "$note" ]; then
        report "failed" "no planning note was written to out/${order}.md"
        return
    fi

    # The order is for poplin shirting, which is specified in YN-CT08, and the
    # store holds 51 cones of 30 metres. Those three facts are only in the
    # database, so a note carrying them was written from a query.
    if ! grep -q 'YN-CT08' "$note"; then
        report "failed" "the planning note for ${order} never names the yarn the cloth is specified in - the cloth specification is in the database"
        return
    fi
    for want in 51 30; do
        if ! grep -qw "$want" "$note"; then
            report "failed" "the planning note for ${order} does not carry ${want} from the stock row - the figures in the note have to come out of the store"
            return
        fi
    done

    calls="$(trace_field "$order" '.calls')"
    tools="$(trace_field "$order" '.tool_calls')"
    queries="$(trace_field "$order" '.queries | length')"
    if [ "${tools:-0}" -lt 1 ] || [ "${queries:-0}" -lt 1 ]; then
        report "failed" "the planning model was never asked to run a query on ${order} - the analyst has to reach the database through its tool"
        return
    fi
    if ! trace_field "$order" '.queries | join(" ")' | grep -q 'YN-CT08'; then
        report "failed" "the query that ran did not name YN-CT08"
        return
    fi
    if [ "${calls:-0}" -lt 2 ]; then
        report "failed" "the whole job took ${calls} planning turn - a crew that queries and then writes takes more than one"
        return
    fi

    report "success" "the job on ${order} ran a query naming YN-CT08 over ${calls} planning turns and the note carries the stock figures 51 and 30 straight out of the store"
}

Test04
B04

# ---------------------------------------------------------------- TC05 ------
cat > "$BODY/05" <<'B05'
Test05() {
    preflight_model || return

    local order="TM-4366" note got text calls
    # The cloth on this order is specified in a yarn the mill does not stock.
    got="$(tool_batch '[{"tool": "stock_lookup", "args": {"yarn_code": "YN-ZZ99"}}]')"
    if [ -z "$got" ]; then
        report "failed" "stock_lookup returned nothing for a yarn that is not stocked - see ${RUN_LOG}"
        return
    fi
    if [ -n "$(printf '%s' "$got" | jq -r '.[0].raised // empty')" ]; then
        report "failed" "stock_lookup raised $(printf '%s' "$got" | jq -r '.[0].raised') on a yarn that is not stocked - a missing row is a normal answer, not an error"
        return
    fi
    text="$(printf '%s' "$got" | jq -r '.[0].text // empty')"
    if [ -z "$text" ]; then
        report "failed" "stock_lookup said nothing at all about a yarn that is not stocked"
        return
    fi
    if printf '%s' "$text" | grep -qE '\b[0-9]+\b.*\b[0-9]+\b'; then
        report "failed" "stock_lookup returned figures for YN-ZZ99, which has no row in the store: ${text}"
        return
    fi

    reset_run "$order"
    rm -f "${LAB_DIR}/out/${order}.md" 2>/dev/null
    run_order "$order"
    if [ "$LAST_RC" -ne 0 ]; then
        report "failed" "the planning job on ${order} exited ${LAST_RC} instead of finishing with an honest answer: $(tail -3 "$RUN_LOG" 2>/dev/null | tr '\n' ' ' | head -c 220)"
        return
    fi
    note="${LAB_DIR}/out/${order}.md"
    if [ ! -s "$note" ]; then
        report "failed" "no planning note was written for ${order} - an order that cannot be met still needs a note saying so"
        return
    fi
    if ! grep -q 'YN-ZZ99' "$note"; then
        report "failed" "the note for ${order} does not name the yarn its cloth is specified in"
        return
    fi

    calls="$(trace_field "$order" '.calls')"
    if [ "${calls:-0}" -gt 8 ]; then
        report "failed" "the job on ${order} took ${calls} planning turns - an agent that cannot find what it needs has to stop at its cap rather than keep asking"
        return
    fi
    if [ "${calls:-0}" -lt 2 ]; then
        report "failed" "the job on ${order} took ${calls} planning turns, so the crew did not run"
        return
    fi

    report "success" "a yarn with no row came back as a plain answer rather than an error, and the job on ${order} still produced a note in ${calls} planning turns instead of looping"
}

Test05
B05

for n in 01 02 03 04 05; do
    case "$n" in
        01) t="the tools answer with what is actually in the store" ;;
        02) t="nothing but a plain SELECT reaches the database" ;;
        03) t="the crew is built from the configuration files" ;;
        04) t="a planning note carries figures only a query could supply" ;;
        05) t="a yarn that is not stocked ends the job honestly" ;;
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
