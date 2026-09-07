#!/bin/bash
# Regenerate test-cases/scripts/script_01..05.sh from one shared preamble plus one
# body per behavioural theme. The platform runs every file in the test scripts/
# folder as a test, so each script must be fully self-contained -- hence the
# duplicated preamble, emitted here so it can never drift.
#
# The platform accepts at most FIVE test scripts, so each script asserts the
# cluster of facts one theme implies and is worth 10 points.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="$DIR/test-cases/scripts"
mkdir -p "$OUT"

# ---------------------------------------------------------------------------
# Graded inputs. Deliberately disjoint from every question and query that
# appears in problem-statement.md or check_local.py, so no published worked
# example is itself a graded case.
# ---------------------------------------------------------------------------
Q_CFG="How many moulds are cut in green sand, and what is their combined capacity?"
Q_LOOP="Which mould code has the largest capacity?"
Q_S1="What is the total weight poured on the day shift?"
Q_S2="And what was the total scrap weight on the day shift?"
Q_MOD="Reset the scrap weights for the night shift, then tell me how many pours ran on that shift and their total weight."

T_TABLE="moulds"
# A table that is not in the database, so the documented empty-list answer for an
# unknown table is graded rather than merely stated.
T_ABSENT="kilnbrook_no_such_table"
Q_GROUP="SELECT base_metal, COUNT(*) AS alloy_count, SUM(tensile_mpa) AS total_tensile_mpa FROM alloys GROUP BY base_metal ORDER BY base_metal"
Q_TOTAL="SELECT COUNT(*) AS pour_count, SUM(poured_kg) AS total_poured_kg FROM pours"
Q_WRITE="DELETE FROM pours WHERE shift = 'night'"
# A statement that is not a query and that names none of the five forbidden verbs.
# The published rule refuses it on its first keyword and on nothing else, so this
# is what grades the half of the rule the DELETE and the UPDATE cannot reach.
Q_PRAGMA="PRAGMA table_info(pours)"

# The turn ceiling the interface contract states. A correct single question needs
# four model turns; anything at or beyond this is a loop with no stop condition.
CEILING=8

# Log files were a bring-up aid and are OFF by default now that the lab is
# validated. Re-enable for a debugging session with:  TEST_LOGGING=on ./gen_tests.sh
# The single-verdict guarantee (report() + EXIT trap) is NOT part of this switch:
# it stays in both modes, because a script that dies before reporting would
# otherwise score a silent zero with no diagnostic.
TEST_LOGGING="${TEST_LOGGING:-off}"

if [ "$TEST_LOGGING" = "off" ]; then
read -r -d '' LOGGING_BLOCK <<'LOGOFF' || true
TC="$(basename "${BASH_SOURCE[0]}" .sh | sed 's/[^0-9]//g')"

# The judge captures stdout and stderr together and grades only the LAST line of
# the two combined. One stray line on stderr - a bash job-control notice, a tool
# warning, a Python traceback - would therefore land after the verdict and void
# it, exactly as an inherited ERR trap would. Send this check's stderr to a file
# on the VM: the diagnostics stay available there, and stdout can only ever end
# in the verdict.
exec 2>>"/tmp/kilnbrook_tc${TC}.err"
log() { :; }
log_verdict() { :; }
log_file() { :; }
learner_log() { printf '/tmp/kilnbrook_out_%s.log' "$1"; }
LOGOFF
TRACE_BLOCK=""
else
read -r -d '' LOGGING_BLOCK <<'LOGON' || true
# Every stderr line and learner traceback is captured to a per-check log file.
TC="$(basename "${BASH_SOURCE[0]}" .sh | sed 's/[^0-9]//g')"
LOG_DIR="${LOG_DIR:-/tmp/kilnbrook-lab-logs}"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp"
LOG_TC="${LOG_DIR}/tc${TC}.log"
: > "$LOG_TC" 2>/dev/null || true
exec 2>>"$LOG_TC"          # stderr to the log; stdout stays clean for the verdict
log() { printf '[%s] %s\n' "$(date '+%H:%M:%S' 2>/dev/null || echo -)" "$*" >>"$LOG_TC" 2>/dev/null || true; }
log_verdict() {
    printf '[%s] TC%s %-7s %s\n' "$(date '+%H:%M:%S' 2>/dev/null || echo -)" \
        "$TC" "$1" "$2" >>"${LOG_DIR}/all-tests.log" 2>/dev/null || true
}
log_file() { sed 's/^/    | /' "$1" >>"$LOG_TC" 2>/dev/null || true; }
learner_log() { printf '%s/learner_%s.log' "$LOG_DIR" "$1"; }
LOGON
read -r -d '' TRACE_BLOCK <<'TRON' || true
# Opt-in full command trace for debugging one check:  KILN_TRACE=1 bash script_03.sh
if [ "${KILN_TRACE:-0}" = "1" ] && [ -n "${BASH_VERSINFO:-}" ] \
   && [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
    exec 4>>"$LOG_TC" && BASH_XTRACEFD=4 && set -x
fi
TRON
fi

read -r -d '' PREAMBLE <<PRE || true
DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
source "/usr/local/bin/judge/test/common.sh" 2>/dev/null || source "\$DIR/common.sh" 2>/dev/null || true
type print_status >/dev/null 2>&1 || print_status() { echo "RESULT:\$1 | \$2"; }

# The platform helper we just sourced ends by installing an ERR trap of its own:
#     trap 'handle_script_error \$LINENO \$? "\$BASH_COMMAND"' ERR
# That trap fires on ANY non-zero simple command, whether or not set -e is in
# effect, and that includes a deliberate  return 1  from one of the guards below.
# Its handler prints an INTERNAL_ERROR line and exits, landing a second line after
# our verdict. The judge grades the LAST line of stdout and stderr combined, so the
# verdict would be discarded and the submission would report no test cases at all.
# Drop the inherited trap, and turn off both error-exit options for good measure.
trap - ERR
set +eE

# --- logging & result reporting -----------------------------------------
# Nothing below can abort the script: a check must always end in one verdict.
${LOGGING_BLOCK}

LAB_DIR="\${LAB_DIR:-/home/user/kilnbrook-foundry}"
DB_FILE="\${DB_FILE:-\${LAB_DIR}/data/foundry.db}"
SVC_URL="\${SVC_URL:-http://127.0.0.1:8781}"
SVC_BIN="\${SVC_BIN:-/opt/kilnbrook-svc/foundryd.py}"
AUDIT="X-Kiln-Audit: kilnbrook-audit-q7z2"
PY="\${PY:-python3}"
TO="\$(command -v timeout || command -v gtimeout || true)"
CEILING=\${CEILING:-${CEILING}}
export PYTHONDONTWRITEBYTECODE=1
# The learner client reads this; exporting it here keeps the checks and the code
# under test pointed at the same endpoint even when the harness moves the port.
export KILN_ENDPOINT="\${SVC_URL}/v1"

# One verdict per script, whatever happens. report() is idempotent, so the EXIT
# trap can safely supply a diagnostic failure if the body never reached one.
STATUS_SENT=0
report() {
    if [ "\$STATUS_SENT" -eq 1 ]; then log "suppressed extra verdict: \$1 | \$2"; return 0; fi
    STATUS_SENT=1
    log "VERDICT \$1 | \$2"
    log_verdict "\$1" "\$2"
    print_status "\$1" "\$2"
}
on_exit() {
    local rc=\$?
    # Grading runs as root while the lab user is "user", and merely running the
    # learner code can create files under their project. Hand ownership back from
    # the trap, not from a success path: a run killed at the time cap still has to
    # leave a usable VM.
    #
    # Gated on the account existing rather than on where LAB_DIR points. The
    # earlier form only fired for /home/user/*, and every local harness runs with
    # LAB_DIR=/tmp/..., so the one repair written to stop a learner being locked
    # out of their own project never ran in the environment that tests it. The
    # case arm still refuses an empty variable and a bare "/", so no expansion
    # accident can chown the filesystem root.
    case "\${LAB_DIR:-}" in
        ""|/) : ;;
        /*)   id -u user >/dev/null 2>&1 && chown -R user:user "\$LAB_DIR" >/dev/null 2>&1 ;;
    esac
    printf 'script_%s %ss\n' "\$TC" "\$SECONDS" >>/tmp/kilnbrook_timing.log 2>/dev/null || true
    log "script exiting rc=\$rc"
    report "failed" "This check stopped before it reached a verdict (rc=\$rc), so nothing about your submission was assessed here. That is a fault in the lab rather than in your code: the check's own error output is in /tmp/kilnbrook_tc\${TC}.err"
}
trap on_exit EXIT
${TRACE_BLOCK}
log "TC\${TC} starting"

# --- time budget --------------------------------------------------------
# The portal kills a test case that runs much beyond two minutes and reports a
# blocking process instead of a score, so every wait in this script is bounded:
# 12s waiting for the endpoint + 55s for the one learner run + at most eight 5s
# audit calls is ~107s worst case. Setup already started the endpoint and paid the
# import cost, so a healthy VM finishes in seconds; these numbers only cap the
# pathological run. Nothing below may loop without one of these constants.
SVC_WAIT=\${SVC_WAIT:-12}
RUN_BUDGET=\${RUN_BUDGET:-55}
CURL_MAX=\${CURL_MAX:-5}
DEPS_WAIT=\${DEPS_WAIT:-20}
DEPS_READY_FILE="\${DEPS_READY_FILE:-/var/log/kilnbrook-lab/deps.ready}"

# The dependency install is deliberately detached from provisioning, so setup cannot be
# killed by the portal for running long. That means a check starting seconds after the VM
# came up could race the install. Wait a bounded moment for the readiness marker the
# install job writes, which it writes last and only once apt has installed curl and jq
# and pip has resolved openai. All three matter here: the learner code imports openai,
# and every helper below shells out to curl and jq.
#
# deps_present() probes all three directly rather than treating "curl and jq exist" as a
# stand-in for "the pip install finished". That stand-in is always true once curl and jq
# are in the foreground, and a check built on it would go on to blame the learner code
# for a library the VM never installed.
deps_present() {
    command -v curl >/dev/null 2>&1 || return 1
    command -v jq   >/dev/null 2>&1 || return 1
    "\$PY" -c 'import openai' >/dev/null 2>&1
}

# Names the first thing that is missing, so the verdict can say which dependency the VM
# lacks instead of reporting a bare "not installed".
missing_dep() {
    command -v curl >/dev/null 2>&1 || { printf 'curl'; return 0; }
    command -v jq   >/dev/null 2>&1 || { printf 'jq'; return 0; }
    "\$PY" -c 'import openai' >/dev/null 2>&1 || { printf 'the openai Python package'; return 0; }
    printf 'nothing, but the readiness marker never appeared'
}

ensure_deps() {
    [ -f "\$DEPS_READY_FILE" ] && return 0
    deps_present && return 0
    local i
    for i in \$(seq 1 "\$DEPS_WAIT"); do
        sleep 1
        [ -f "\$DEPS_READY_FILE" ] && return 0
    done
    # Only after the wait: a VM provisioned by an older setup script publishes no
    # marker, and a missing file must not by itself fail a check.
    deps_present
}

# env_fault : one sentence for a verdict when the VM, not the submission, is at fault.
env_fault() {
    printf 'This VM is not ready to be graded: %s is not installed, so the lab environment is incomplete and this is not a fault in your code. The dependency install log is /var/log/kilnbrook-lab/pip.log and the readiness marker it writes when it finishes is %s' \\
        "\$(missing_dep)" "\$DEPS_READY_FILE"
}

# Bound the learner run even where coreutils timeout(1) is absent (macOS has none,
# and a silently missing bound reports a stalled run as a very slow test case
# instead of killing it, which is how an unbounded run passes for a fast one during
# authoring). The fallback watchdog needs nothing but the shell.
run_bounded() {
    if [ -n "\$TO" ]; then
        "\$TO" -k 5 "\$RUN_BUDGET" "\$@"
        return \$?
    fi
    "\$@" &
    local pid=\$! rc=0 wd
    ( sleep "\$RUN_BUDGET"; kill -9 "\$pid" ) >/dev/null 2>&1 &
    wd=\$!
    wait "\$pid"; rc=\$?
    kill "\$wd" >/dev/null 2>&1
    return \$rc
}

ensure_service() {
    curl -sf -m "\$CURL_MAX" "\${SVC_URL}/health" >/dev/null 2>&1 && return 0
    [ -f "\$SVC_BIN" ] || return 1
    setsid nohup "\$PY" "\$SVC_BIN" >/tmp/kilnbrook_svc.log 2>&1 </dev/null &
    local i
    for i in \$(seq 1 "\$SVC_WAIT"); do
        curl -sf -m 2 "\${SVC_URL}/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

oracle_field() {
    curl -sf -m "\$CURL_MAX" -H "\$AUDIT" --get --data-urlencode "q=\$1" \\
        "\${SVC_URL}/__kbz7q/oracle" 2>/dev/null | jq -c "\$2"
}

query_values() {
    curl -sf -m "\$CURL_MAX" -H "\$AUDIT" --get --data-urlencode "sql=\$1" \\
        "\${SVC_URL}/__kbz7q/query" 2>/dev/null | jq -c ".values"
}

schema_field() {
    curl -sf -m "\$CURL_MAX" -H "\$AUDIT" --get --data-urlencode "table=\$1" \\
        "\${SVC_URL}/__kbz7q/schema" 2>/dev/null | jq -c "\$2"
}

trace_field() {
    curl -sf -m "\$CURL_MAX" -H "\$AUDIT" \\
        "\${SVC_URL}/__kbz7q/trace?session=\$1" 2>/dev/null | jq -r "\$2" 2>/dev/null
}

# word_or <default> <value> : a verdict built from jq output must still read as a
# sentence when the JSON was absent and jq printed nothing, or the literal null.
word_or() {
    case "\${2:-}" in
        ""|null) printf '%s' "\$1" ;;
        *)       printf '%s' "\$2" ;;
    esac
}

# json_field <payload> <filter> <default> : one scalar out of the LABJSON payload.
json_field() {
    word_or "\$3" "\$(printf '%s' "\$1" | jq -r "\$2" 2>/dev/null)"
}

# json_compact <payload> <filter> <default> : same, but for a list. jq -c keeps the
# list on one line, which matters twice over: the comparisons below are string
# comparisons against a compact expected list, and a verdict is one line.
json_compact() {
    word_or "\$3" "\$(printf '%s' "\$1" | jq -c "\$2" 2>/dev/null)"
}

db_hash() {
    [ -s "\$1" ] || { echo "MISSING"; return 0; }
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "\$1" | cut -d" " -f1
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "\$1" | cut -d" " -f1
    else
        wc -c <"\$1" | tr -d " "
    fi
}

# contains_all <json-array-of-strings> <text> : every value must appear verbatim.
# Values come from the database, so this grades the number the query produced
# without grading how a solution chose to lay its rows out.
MISSING_VALUE=""
contains_all() {
    local text="\$2" value
    MISSING_VALUE=""
    while IFS= read -r value; do
        [ -n "\$value" ] || continue
        case "\$text" in
            *"\$value"*) ;;
            *) MISSING_VALUE="\$value"; return 1 ;;
        esac
    done < <(printf '%s' "\$1" | jq -r ".[]" 2>/dev/null)
    return 0
}

# run_learner <session-id>  (python harness on stdin) -> echoes the LABJSON payload
run_learner() {
    local rid="\$1" tmp rc
    # Trailing X characters only: a suffix after them is not substituted by every
    # mktemp, which would hand back one fixed filename and collide between runs.
    tmp="\$(mktemp /tmp/kilnbrook_h_XXXXXX)" || return 1
    cat > "\$tmp"
    local out; out="\$(learner_log "\$rid")"
    ( cd "\$LAB_DIR" && export KILN_SESSION="\$rid" PYTHONPATH="\$LAB_DIR" && \\
        run_bounded "\$PY" "\$tmp" ) >"\$out" 2>&1
    rc=\$?
    rm -f "\$tmp"
    log "learner run \$rid exited rc=\$rc; output in \$out"
    log_file "\$out"
    grep -o 'LABJSON:.*' "\$out" | head -1 | cut -c9-
    return \$rc
}

# log_tail <file> : the last few lines of a log flattened onto one line, so a
# traceback can ride inside the verdict itself. The portal shows the learner only
# the verdict message, so evidence that stays in a file is evidence they never see.
log_tail() {
    [ -s "\$1" ] || return 0
    tail -n 3 "\$1" 2>/dev/null | paste -s -d '|' - | sed 's/|/ | /g' | cut -c1-280
}

# run_evidence <file> : what to say about the output a learner run left behind.
# The empty case is the one that used to read as a broken lab: the message named a
# log file as evidence and the file had nothing in it. A module that only defines
# functions exits 0 having printed nothing, which is exactly how that happens.
run_evidence() {
    if [ -s "\$1" ]; then
        printf 'it printed: %s  [full output in %s]' "\$(log_tail "\$1")" "\$1"
    else
        printf 'it printed nothing at all, so %s is empty. A module that only defines functions exits quietly like this: check that solution.py defines every callable in the interface contract, that importing it raises nothing, and run  cd %s && python3 check_local.py  to see what each one returns' \\
            "\$1" "\$LAB_DIR"
    fi
}

fail_no_output() {
    report "failed" "\$1. The check ran your solution.py in a fresh python3 process from \${LAB_DIR} and no result came back, so \$(run_evidence "\$(learner_log "\$2")")"
}

# Guard: an unreadable expected value must never silently match an empty result.
require_expected() {
    if [ -z "\$1" ] || [ "\$1" = "null" ] || [ "\$1" = "[]" ]; then
        report "failed" "This check could not read the expected result from the model endpoint on \${SVC_URL}, so it did not grade your code at all. That is an environment fault: confirm the endpoint is answering with  curl -s \${SVC_URL}/health  and that jq is installed"
        return 1
    fi
    return 0
}

need_project() {
    [ -f "\${LAB_DIR}/solution.py" ] || {
        report "failed" "There is no solution.py in \${LAB_DIR}, so there was nothing to grade. Write your functions in that file, then run  cd \${LAB_DIR} && python3 check_local.py  before submitting"
        return 1
    }
    [ -s "\$DB_FILE" ] || {
        report "failed" "The foundry database is missing or empty at \${DB_FILE}, so no tool could read anything from it. That is an environment fault rather than a fault in your code: re-provisioning the lab rebuilds the file"
        return 1
    }
    return 0
}
PRE

emit() {
    # emit <NN> <headline> <body-file>
    local nn="$1" headline="$2" body="$3"
    {
        echo '#!/bin/bash'
        echo "# TC${nn} (10 pts): ${headline}"
        printf '%s\n' "$PREAMBLE"
        cat "$body"
    } > "$OUT/script_${nn}.sh"
    chmod +x "$OUT/script_${nn}.sh"
    rm -f "$body"
    bash -n "$OUT/script_${nn}.sh"
}

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# --- TC01 -----------------------------------------------------------------
# First of the five, and deliberately the one that depends on the least: it needs
# Task 1 and Task 2 and nothing else. The platform stops grading at the first
# failing check, so partial credit is a prefix of this list, and a check sitting in
# position 1 that needed four of the five tasks would hand a learner who had
# finished three of them a zero.
cat > "$TMPD/b01" <<BODY

Test01() {
    ensure_deps || { report "failed" "\$(env_fault)"; return; }
    ensure_service || { report "failed" "The model endpoint is not answering on \${SVC_URL}, so this check could not be run at all. That is an environment fault rather than a fault in your code: curl -s \${SVC_URL}/health should print a status line, and /tmp/kilnbrook_svc.log holds the endpoint output"; return; }
    need_project || return
    local rid out names prompt_ok all_tools asked error
    local persona_ok rules_ok tools_ok missing_parts schema_problems turns
    rid="tc01_\$\$"
    # The request is sent by this harness rather than by run_agent, so the verdict
    # turns only on what build_system_prompt and build_tools_schema produced.
    out="\$(Q_CFG="${Q_CFG}" run_learner "\$rid" <<'PY'
import json, os, sys
sys.path.insert(0, ".")
from kiln_kit import MODEL_NAME, PERSONA, make_client
import solution

prompt = solution.build_system_prompt(PERSONA)
schema = solution.build_tools_schema() or []
names = []
for entry in schema:
    function = (entry or {}).get("function") or {}
    names.append(str(function.get("name")))
wanted = ("list_tables", "get_table_schema", "execute_sql")

asked = []
error = ""
try:
    reply = make_client().chat.completions.create(
        model=MODEL_NAME,
        messages=[{"role": "system", "content": prompt},
                  {"role": "user", "content": os.environ["Q_CFG"]}],
        tools=schema,
        tool_choice="auto",
    )
    message = reply.choices[0].message
    for call in (message.tool_calls or []):
        asked.append(str(call.function.name))
except Exception as exc:
    error = "%s: %s" % (type(exc).__name__, exc)

print("LABJSON:" + json.dumps({
    "prompt_is_text": isinstance(prompt, str) and len(prompt.strip()) > 0,
    "tool_names": sorted(names),
    "has_all_tools": all(name in names for name in wanted),
    "n_tools": len(schema),
    "asked_for": asked,
    "error": error[:300],
}))
PY
)"
    [ -z "\$out" ] && { fail_no_output "build_system_prompt or build_tools_schema did not run to completion" "\$rid"; return; }
    names="\$(json_compact "\$out" '.tool_names' 'none')"
    prompt_ok="\$(json_field "\$out" '.prompt_is_text' 'unknown')"
    all_tools="\$(json_field "\$out" '.has_all_tools' 'unknown')"
    asked="\$(json_compact "\$out" '.asked_for' 'none')"
    error="\$(json_field "\$out" '.error' 'none')"
    persona_ok="\$(word_or unknown "\$(trace_field "\$rid" '.persona.ok')")"
    rules_ok="\$(word_or unknown "\$(trace_field "\$rid" '"\(.persona.rules_ok)/\(.persona.rules_total)"')")"
    tools_ok="\$(word_or unknown "\$(trace_field "\$rid" '.tools.ok')")"
    turns="\$(word_or 0 "\$(trace_field "\$rid" '.chat_turns')")"
    missing_parts="\$(word_or none "\$(trace_field "\$rid" '.persona.missing | tostring')")"
    schema_problems="\$(word_or none "\$(trace_field "\$rid" '[.tools.list_tables.problems, .tools.get_table_schema.problems, .tools.execute_sql.problems] | flatten | tostring')")"
    if [ "\$prompt_ok" = "true" ] && [ "\$all_tools" = "true" ] \\
       && [ "\$persona_ok" = "true" ] && [ "\$tools_ok" = "true" ] \\
       && [ "\$turns" -ge 1 ] 2>/dev/null \\
       && [ "\$asked" = '["list_tables"]' ]; then
        report "success" "The endpoint received a system prompt carrying the whole persona and three tool schemas it could act on, and it answered by asking for the first tool"
    else
        report "failed" "The prompt and the tool schemas are not yet usable by the model. build_system_prompt must return one string carrying the persona role, all five of its rules, every line of its instructions and every line of its output format, and build_tools_schema must declare list_tables, get_table_schema and execute_sql, each with a non-empty description and its required parameter named in both properties and required. Observed: build_system_prompt returned text=\$prompt_ok, tools declared=\$names, persona complete=\$persona_ok (rules \$rules_ok, missing \$missing_parts), tool schemas usable=\$tools_ok (\$schema_problems), the model asked for=\$asked, requests reaching the endpoint=\$turns, error from the request=\$error"
    fi
}
Test01
BODY
emit 01 "the persona and the three tool schemas reach the endpoint in a usable form" "$TMPD/b01"

# --- TC02 -----------------------------------------------------------------
cat > "$TMPD/b02" <<BODY

Test02() {
    ensure_deps || { report "failed" "\$(env_fault)"; return; }
    ensure_service || { report "failed" "The model endpoint is not answering on \${SVC_URL}, so this check could not be run at all. That is an environment fault rather than a fault in your code: curl -s \${SVC_URL}/health should print a status line, and /tmp/kilnbrook_svc.log holds the endpoint output"; return; }
    need_project || return
    local want_tables want_cols want_group want_total rid out before after
    want_tables="\$(schema_field "${T_TABLE}" '.tables')";  require_expected "\$want_tables" || return
    want_cols="\$(schema_field "${T_TABLE}" '.columns')";   require_expected "\$want_cols" || return
    want_group="\$(query_values "${Q_GROUP}")";             require_expected "\$want_group" || return
    want_total="\$(query_values "${Q_TOTAL}")";             require_expected "\$want_total" || return
    before="\$(db_hash "\$DB_FILE")"
    rid="tc02_\$\$"
    out="\$(T_TABLE="${T_TABLE}" T_ABSENT="${T_ABSENT}" Q_GROUP="${Q_GROUP}" \\
            Q_TOTAL="${Q_TOTAL}" Q_WRITE="${Q_WRITE}" run_learner "\$rid" <<'PY'
import json, os, sys
sys.path.insert(0, ".")
import solution

def text(value):
    return value if isinstance(value, str) else repr(value)

tables = solution.list_tables() or []
columns = solution.get_table_schema(os.environ["T_TABLE"]) or []
absent = solution.get_table_schema(os.environ["T_ABSENT"])
grouped = solution.execute_sql(os.environ["Q_GROUP"])
totals = solution.execute_sql(os.environ["Q_TOTAL"])
guard = solution.execute_sql(os.environ["Q_WRITE"])
again = solution.execute_sql(os.environ["Q_TOTAL"])
print("LABJSON:" + json.dumps({
    "tables": sorted(str(name) for name in tables),
    "columns": [str(name) for name in columns],
    "absent_is_empty": isinstance(absent, list) and len(absent) == 0,
    "grouped": text(grouped),
    "totals": text(totals),
    "guard": text(guard)[:300],
    "guard_refused": isinstance(guard, str) and guard.strip().upper().startswith("REFUSED:"),
    "again": text(again),
}))
PY
)"
    [ -z "\$out" ] && { fail_no_output "list_tables / get_table_schema / execute_sql did not run to completion" "\$rid"; return; }
    after="\$(db_hash "\$DB_FILE")"
    local got_tables got_cols absent_ok refused guard_reply unchanged
    got_tables="\$(json_compact "\$out" '.tables' 'none')"
    got_cols="\$(json_compact "\$out" '.columns' 'none')"
    absent_ok="\$(json_field "\$out" '.absent_is_empty' 'unknown')"
    refused="\$(json_field "\$out" '.guard_refused' 'unknown')"
    guard_reply="\$(json_field "\$out" '.guard' 'nothing')"
    unchanged="\$([ "\$before" = "\$after" ] && echo yes || echo no)"
    if [ "\$got_tables" = "\$want_tables" ] && [ "\$got_cols" = "\$want_cols" ] \\
       && [ "\$absent_ok" = "true" ] \\
       && contains_all "\$want_group" "\$(json_field "\$out" '.grouped' '')" \\
       && contains_all "\$want_total" "\$(json_field "\$out" '.totals' '')" \\
       && [ "\$refused" = "true" ] \\
       && contains_all "\$want_total" "\$(json_field "\$out" '.again' '')" \\
       && [ "\$before" = "\$after" ] && [ "\$before" != "MISSING" ]; then
        report "success" "The three tools read the real database, and a data-modifying statement is refused instead of executed"
    else
        contains_all "\$want_group" "\$(json_field "\$out" '.grouped' '')" || true
        report "failed" "The three tools did not all read the real database and refuse to change it. list_tables must return the real table names, get_table_schema(${T_TABLE}) must return \$want_cols in declaration order, get_table_schema of a table that does not exist must return an empty list, the two queries must return the values \$want_group and \$want_total, and a data-modifying statement must come back as a string beginning REFUSED: with the file untouched. Observed: tables=\$got_tables, columns=\$got_cols, empty list for an unknown table=\$absent_ok, refused=\$refused, refusal text=\$(printf '%s' "\$guard_reply" | head -1), database unchanged=\$unchanged, first value absent from a query result=\${MISSING_VALUE:-none}"
    fi
}
Test02
BODY
emit 02 "the three tools do real database work and refuse to modify data" "$TMPD/b02"

# --- TC03 -----------------------------------------------------------------
cat > "$TMPD/b03" <<BODY

Test03() {
    ensure_deps || { report "failed" "\$(env_fault)"; return; }
    ensure_service || { report "failed" "The model endpoint is not answering on \${SVC_URL}, so this check could not be run at all. That is an environment fault rather than a fault in your code: curl -s \${SVC_URL}/health should print a status line, and /tmp/kilnbrook_svc.log holds the endpoint output"; return; }
    need_project || return
    local want rid out answer planned observed unmatched turns capped stalled
    want="\$(oracle_field "${Q_LOOP}" ".values")"; require_expected "\$want" || return
    rid="tc03_\$\$"
    out="\$(Q_LOOP="${Q_LOOP}" run_learner "\$rid" <<'PY'
import json, os, sys
sys.path.insert(0, ".")
import solution

answer = solution.run_agent(os.environ["Q_LOOP"])
print("LABJSON:" + json.dumps({
    "answer": answer if isinstance(answer, str) else repr(answer),
}))
PY
)"
    [ -z "\$out" ] && { fail_no_output "run_agent did not run to completion" "\$rid"; return; }
    answer="\$(json_field "\$out" '.answer' '')"
    planned="\$(word_or none "\$(trace_field "\$rid" '.questions[0].planned | tostring')")"
    observed="\$(word_or 0 "\$(trace_field "\$rid" '[.questions[0].observed[] | select(.matched)] | length')")"
    unmatched="\$(word_or 1 "\$(trace_field "\$rid" '.unmatched_tool_ids')")"
    turns="\$(word_or 0 "\$(trace_field "\$rid" '.chat_turns')")"
    capped="\$(word_or unknown "\$(trace_field "\$rid" '.capped')")"
    stalled="\$(word_or unknown "\$(trace_field "\$rid" '.questions[0].stalled')")"
    if [ "\$planned" = '["list_tables","get_table_schema","execute_sql"]' ] \\
       && [ "\$observed" -eq 3 ] 2>/dev/null && [ "\$unmatched" -eq 0 ] 2>/dev/null \\
       && [ "\$stalled" = "false" ] && [ "\$capped" = "false" ] \\
       && [ "\$turns" -ge 4 ] 2>/dev/null && [ "\$turns" -le "\$CEILING" ] 2>/dev/null \\
       && contains_all "\$want" "\$answer"; then
        report "success" "One question drove the full loop: three tools requested in order, every result fed back under its own call id, and the answer carries the value the database produced"
    else
        report "failed" "run_agent did not drive the loop to a correct answer. It must request list_tables, then get_table_schema, then execute_sql, append each result as a tool message carrying the tool_call_id of the call it answers, finish inside \$CEILING model turns, and return an answer containing \$want. Observed: tools requested=\$planned, results matched to a call id the endpoint issued=\$observed of 3, tool messages with an unrecognised tool_call_id=\$unmatched, the endpoint could not act on a tool schema=\$stalled, model turns used=\$turns, first value absent from the answer=\${MISSING_VALUE:-none}"
    fi
}
Test03
BODY
emit 03 "the loop reasons, acts, observes and terminates" "$TMPD/b03"

# --- TC04 -----------------------------------------------------------------
cat > "$TMPD/b04" <<BODY

Test04() {
    ensure_deps || { report "failed" "\$(env_fault)"; return; }
    ensure_service || { report "failed" "The model endpoint is not answering on \${SVC_URL}, so this check could not be run at all. That is an environment fault rather than a fault in your code: curl -s \${SVC_URL}/health should print a status line, and /tmp/kilnbrook_svc.log holds the endpoint output"; return; }
    need_project || return
    local want1 want2 rid out n a1 a2 first second turns capped
    want1="\$(oracle_field "${Q_S1}" ".values")"; require_expected "\$want1" || return
    want2="\$(oracle_field "${Q_S2}" ".values")"; require_expected "\$want2" || return
    rid="tc04_\$\$"
    out="\$(Q_S1="${Q_S1}" Q_S2="${Q_S2}" run_learner "\$rid" <<'PY'
import json, os, sys
sys.path.insert(0, ".")
import solution

nothing = solution.run_session([])
answers = solution.run_session([os.environ["Q_S1"], os.environ["Q_S2"]]) or []
answers = [a if isinstance(a, str) else repr(a) for a in list(answers)]
print("LABJSON:" + json.dumps({
    "empty_ok": isinstance(nothing, (list, tuple)) and len(nothing) == 0,
    "count": len(answers),
    "first": answers[0] if len(answers) > 0 else "",
    "second": answers[1] if len(answers) > 1 else "",
}))
PY
)"
    [ -z "\$out" ] && { fail_no_output "run_session did not run to completion" "\$rid"; return; }
    n="\$(json_field "\$out" '.count' '0')"
    a1="\$(json_field "\$out" '.first' '')"
    a2="\$(json_field "\$out" '.second' '')"
    first="\$(word_or none "\$(trace_field "\$rid" '.questions[0].planned | tostring')")"
    second="\$(word_or none "\$(trace_field "\$rid" '.questions[1].planned | tostring')")"
    turns="\$(word_or 0 "\$(trace_field "\$rid" '.chat_turns')")"
    capped="\$(word_or unknown "\$(trace_field "\$rid" '.capped')")"
    empty_ok="\$(json_field "\$out" '.empty_ok' 'unknown')"
    if [ "\$n" = "2" ] && [ "\$empty_ok" = "true" ] \\
       && [ "\$first" = '["list_tables","get_table_schema","execute_sql"]' ] \\
       && [ "\$second" = '["execute_sql"]' ] && [ "\$capped" = "false" ] \\
       && [ "\$turns" -le \$((CEILING * 2)) ] 2>/dev/null \\
       && contains_all "\$want1" "\$a1" && contains_all "\$want2" "\$a2"; then
        report "success" "The second question reused what the first turn discovered: it went straight to the query, and both answers carry the values the database produced"
    else
        report "failed" "run_session did not answer both questions on one shared message list. It must return one answer per question in order, return an empty list when handed an empty list of questions, keep every earlier message so the second question needs only execute_sql, and both answers must carry the database values \$want1 and \$want2. Observed: answers returned=\$n, empty list for no questions=\$empty_ok, tools requested for the first question=\$first, tools requested for the second=\$second, model turns used across both=\$turns, first value absent from an answer=\${MISSING_VALUE:-none}"
    fi
}
Test04
BODY
emit 04 "one shared conversation carries what earlier turns discovered" "$TMPD/b04"

# --- TC05 -----------------------------------------------------------------
cat > "$TMPD/b05" <<BODY

Test05() {
    ensure_deps || { report "failed" "\$(env_fault)"; return; }
    ensure_service || { report "failed" "The model endpoint is not answering on \${SVC_URL}, so this check could not be run at all. That is an environment fault rather than a fault in your code: curl -s \${SVC_URL}/health should print a status line, and /tmp/kilnbrook_svc.log holds the endpoint output"; return; }
    need_project || return
    local want rid out answer planned refused observed before after capped
    want="\$(oracle_field "${Q_MOD}" ".values")"; require_expected "\$want" || return
    before="\$(db_hash "\$DB_FILE")"
    [ "\$before" = "MISSING" ] && { report "failed" "The foundry database is missing at \${DB_FILE}"; return; }
    rid="tc05_\$\$"
    out="\$(Q_MOD="${Q_MOD}" Q_PRAGMA="${Q_PRAGMA}" run_learner "\$rid" <<'PY'
import json, os, sys
sys.path.insert(0, ".")
import solution

answer = solution.run_agent(os.environ["Q_MOD"])
catalogue = solution.execute_sql(os.environ["Q_PRAGMA"])
print("LABJSON:" + json.dumps({
    "answer": answer if isinstance(answer, str) else repr(answer),
    "pragma_refused": isinstance(catalogue, str) and catalogue.strip().upper().startswith("REFUSED:"),
    "pragma_reply": (catalogue if isinstance(catalogue, str) else repr(catalogue))[:200],
}))
PY
)"
    [ -z "\$out" ] && { fail_no_output "run_agent did not run to completion" "\$rid"; return; }
    after="\$(db_hash "\$DB_FILE")"
    local unchanged pragma_ok pragma_reply
    answer="\$(json_field "\$out" '.answer' '')"
    planned="\$(word_or none "\$(trace_field "\$rid" '.questions[0].planned | tostring')")"
    observed="\$(word_or 0 "\$(trace_field "\$rid" '.questions[0].observed | length')")"
    refused="\$(word_or unknown "\$(trace_field "\$rid" '.questions[0].observed[2].refused')")"
    capped="\$(word_or unknown "\$(trace_field "\$rid" '.capped')")"
    unchanged="\$([ "\$before" = "\$after" ] && echo yes || echo no)"
    pragma_ok="\$(json_field "\$out" '.pragma_refused' 'unknown')"
    pragma_reply="\$(json_field "\$out" '.pragma_reply' 'nothing')"
    if [ "\$planned" = '["list_tables","get_table_schema","execute_sql","execute_sql"]' ] \\
       && [ "\$observed" -eq 4 ] 2>/dev/null && [ "\$refused" = "true" ] \\
       && [ "\$pragma_ok" = "true" ] \\
       && [ "\$before" = "\$after" ] && [ "\$capped" = "false" ] \\
       && contains_all "\$want" "\$answer"; then
        report "success" "The data-modifying step was refused, the refusal was fed back as an observation, the run recovered with a read-only query, and the database is byte-for-byte unchanged"
    else
        report "failed" "A question whose plan would change the data was not handled correctly. execute_sql must refuse the data-modifying statement with a REFUSED: string instead of running it, the refusal must be appended as the tool result for that call so the loop can continue, the run must finish with a read-only query whose answer contains \$want, a statement whose first keyword is not SELECT or WITH must also be refused, and the database file must be unchanged. Observed: steps taken=\$planned, tool results fed back=\$observed, the third result was a refusal=\$refused, the non-query statement was refused=\$pragma_ok (it replied: \$(printf '%s' "\$pragma_reply" | head -1)), database unchanged=\$unchanged, first value absent from the answer=\${MISSING_VALUE:-none}"
    fi
}
Test05
BODY
emit 05 "a data-modifying request is refused and the run recovers read-only" "$TMPD/b05"

echo "generated:"
ls -1 "$OUT"/script_*.sh
