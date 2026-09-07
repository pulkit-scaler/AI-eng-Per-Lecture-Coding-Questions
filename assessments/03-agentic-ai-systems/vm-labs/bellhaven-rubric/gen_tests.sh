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
exec 2>>"/tmp/bellhaven_tc${TC}.err"
STATUS_SENT=0
report() {
    if [ "$STATUS_SENT" -eq 1 ]; then return 0; fi
    STATUS_SENT=1
    print_status "$1" "$2"
}

LAB_DIR="${LAB_DIR:-/home/user/bellhaven-rubric}"
DESK_URL="${DESK_URL:-http://127.0.0.1:8755}"
DESK_BIN="${DESK_BIN:-/opt/bellhaven-svc/judgesvc.py}"
GKEY_HEADER="X-Grader-Key: bellhaven-grader-bh4r"
GPATH="__bh4r"
PY="${PY:-python3}"
DEPS_READY_FILE="${DEPS_READY_FILE:-/var/log/bellhaven-lab/deps.ready}"
TIMING_LOG="${TIMING_LOG:-/tmp/bellhaven_timing.log}"
RUN_LOG="/tmp/bellhaven_tc${TC}.log"
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
WORK="$(mktemp -d 2>/dev/null || echo /tmp/bh_work_$$)"
mkdir -p "$WORK" 2>/dev/null
chmod 700 "$WORK" 2>/dev/null
PROBE="${WORK}/probe.py"
RC_FILE="${WORK}/rc"
POOL="${WORK}/pool.json"
# The graded gate run writes its report HERE, not into the learner project.
# Running as root inside /home/user/... leaves a root-owned reports/eval.json
# behind, and the learner's own gate can then never rewrite it. The EXIT trap
# hands ownership back as a second line of defence, but nothing should need it.
REPORT="${WORK}/reports/eval.json"

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
# a check would run before the symbolic algebra package exists - and then blame
# the learner for code that cannot import it.
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

# A VM whose symbolic algebra package never installed is a broken VM, not a
# wrong answer. Say so, instead of reporting that the learner metrics module
# does not import.
require_sympy() {
    "$PY" -c "import sympy" >/dev/null 2>&1 && return 0
    report "failed" "the symbolic algebra package this lab runs on is not installed on this VM, so nothing here can be graded - this is an environment fault, not your code. The install log is at /var/log/bellhaven-lab/deps.log"
    return 1
}

ensure_desk() {
    curl -sf -m "$CURL_MAX" "${DESK_URL}/health" >/dev/null 2>&1 && return 0
    [ -f "$DESK_BIN" ] || return 1
    spawn_detached /tmp/bellhaven_desk.log "$PY" "$DESK_BIN"
    local i
    for i in $(seq 1 "$SVC_WAIT"); do
        curl -sf -m 2 "${DESK_URL}/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

fetch_pool() {
    curl -sf -m "$CURL_MAX" -H "$GKEY_HEADER" \
        "${DESK_URL}/${GPATH}/pool" -o "$POOL" 2>/dev/null
    [ -s "$POOL" ] || return 1
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
                BELLHAVEN_DESK_URL="$DESK_URL" \
                BH_GKEY="bellhaven-grader-bh4r" \
                BH_GPATH="$GPATH" \
                BH_POOL="$POOL" \
                BH_REPORT="$REPORT" \
      && bounded "$budget" "$PY" "$PROBE" </dev/null ) >"$RUN_LOG" 2>&1
    LAST_RC=$?
    echo "$LAST_RC" >"$RC_FILE" 2>/dev/null
    grep -o 'LABJSON:.*' "$RUN_LOG" 2>/dev/null | tail -1 | sed 's/^LABJSON://'
    return "$LAST_RC"
}

GATE_RC=0
# run_gate <run-id> <out-path> [extra args...] : run the learner gate; echo its
# LABJSON. The out path is a parameter because a second run with different
# thresholds must not overwrite the report the first one left behind.
run_gate() {
    local rid="$1"; shift
    local out="$1"; shift
    local budget
    budget="$(budget_left)"
    if [ "$budget" -eq 0 ]; then GATE_RC=124; return 124; fi
    ( cd "$LAB_DIR" 2>/dev/null \
      && export PYTHONPATH="$LAB_DIR" \
                BELLHAVEN_DESK_URL="$DESK_URL" \
                BELLHAVEN_RUN_ID="$rid" \
      && bounded "$budget" "$PY" gate.py --pool "$POOL" \
             --out "$out" "$@" </dev/null ) >"$RUN_LOG" 2>&1
    GATE_RC=$?
    echo "$GATE_RC" >"$RC_FILE" 2>/dev/null
    grep -o 'LABJSON:.*' "$RUN_LOG" 2>/dev/null | tail -1 | sed 's/^LABJSON://'
    return "$GATE_RC"
}

last_rc() { cat "$RC_FILE" 2>/dev/null || echo 0; }

fail_no_json() {
    report "failed" "${1} - no LABJSON line came back (exit $(last_rc)); the output is in ${RUN_LOG}"
}

field() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }

# Refuse an unstarted project in about a second, naming every plausible cause.
require_started() {
    local missing="" f
    for f in harness/dataset.py harness/metrics.py harness/judge.py \
             harness/ensemble.py gate.py; do
        [ -s "${LAB_DIR}/${f}" ] || missing="${missing} ${f}"
    done
    if [ -n "$missing" ]; then
        report "failed" "these files are missing or empty in ${LAB_DIR}:${missing}"
        return 1
    fi
    local untouched
    untouched="$(grep -l 'is not written yet' "${LAB_DIR}/harness"/*.py \
        "${LAB_DIR}/gate.py" 2>/dev/null | xargs -n1 basename 2>/dev/null \
        | tr '\n' ' ')"
    if [ -n "$untouched" ]; then
        report "failed" "these still hold the untouched starter: ${untouched}- write the four harness modules and gate.py, then run python3 check_local.py from ${LAB_DIR} before submitting"
        return 1
    fi
    return 0
}

preflight() {
    ensure_deps || { report "failed" "curl and jq are not installed yet; the setup job that installs them has not finished"; return 1; }
    ensure_desk || { report "failed" "the review desk is not reachable on ${DESK_URL}"; return 1; }
    fetch_pool || { report "failed" "Grader could not read its prediction pool from the review desk on ${DESK_URL}"; return 1; }
    require_sympy || return 1
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

GK = os.environ.get("BH_GKEY", "")
GP = os.environ.get("BH_GPATH", "")
BASE = os.environ.get("BELLHAVEN_DESK_URL", "http://127.0.0.1:8755")
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


def pool():
    with open(os.environ["BH_POOL"]) as handle:
        return json.load(handle)["pool"]


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

build_golden = load("harness.dataset", "build_golden")

SUBJECTS = ["algebra", "geometry", "counting", "precalculus"]
LEVELS = [1, 3]
pool_records = []
counter = 0
for subject in SUBJECTS:
    for level in LEVELS:
        for repeat in range(5):
            counter += 1
            pool_records.append({
                "id": "px-%03d" % counter,
                "subject": subject,
                "level": level,
                "problem": "problem number %d" % counter,
                "gold_answer": str(counter),
                "predicted_answer": str(counter),
                "is_stress_test": False,
                "trace": [],
            })
STRESS_IDS = []
for index in range(3):
    counter += 1
    STRESS_IDS.append("px-%03d" % counter)
    pool_records.append({
        "id": "px-%03d" % counter,
        "subject": "algebra",
        "level": 1,
        "problem": "known failure mode %d" % index,
        "gold_answer": str(counter),
        "predicted_answer": str(counter),
        "is_stress_test": True,
        "trace": [],
    })

SIZE = 12
PER_BUCKET = 2

try:
    chosen = build_golden(list(pool_records), SIZE, PER_BUCKET, 7)
except TypeError:
    try:
        chosen = build_golden(list(pool_records), SIZE, PER_BUCKET)
    except Exception as exc:
        die("build_golden raised %s: %s" % (type(exc).__name__, exc))
except Exception as exc:
    die("build_golden raised %s: %s" % (type(exc).__name__, exc))

if not isinstance(chosen, list):
    die("build_golden must return a list of records, it returned %r"
        % type(chosen).__name__)
if len(chosen) != SIZE:
    die("build_golden returned %d records for a requested size of %d"
        % (len(chosen), SIZE))

ids = [r.get("id") for r in chosen]
if len(set(ids)) != len(ids):
    die("build_golden returned the same record more than once")
known = {r["id"] for r in pool_records}
strays = [i for i in ids if i not in known]
if strays:
    die("build_golden returned records that are not in the pool: %s" % strays[:3])

missing = [i for i in STRESS_IDS if i not in ids]
if missing:
    die("build_golden dropped %d of the %d stress tests (%s). Those are the "
        "failure modes somebody wrote down on purpose; a sample without them "
        "measures the easy half of the problem" % (len(missing),
                                                   len(STRESS_IDS), missing))

counts = {}
for record in chosen:
    key = (record.get("subject"), record.get("level"))
    counts[key] = counts.get(key, 0) + 1
over = {k: v for k, v in counts.items() if v > PER_BUCKET
        and k != ("algebra", 1)}
if over:
    die("build_golden took more than %d from a stratum: %s"
        % (PER_BUCKET, sorted(over.items())[:3]))
if len(counts) < 6:
    die("build_golden drew from only %d of the 8 strata; a stratified sample "
        "spreads across the strata before it takes a second from any of them"
        % len(counts))

again = build_golden(list(pool_records), SIZE, PER_BUCKET, 7)
if [r.get("id") for r in again] != ids:
    die("build_golden gave a different sample the second time with the same "
        "seed; an evaluation you cannot reproduce is not a measurement")

win("golden set: %d records over %d strata, cap of %d respected, all %d stress "
    "tests kept, and reproducible" % (len(chosen), len(counts), PER_BUCKET,
                                      len(STRESS_IDS)))
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

exact_match = load("harness.metrics", "exact_match")
symbolic_match = load("harness.metrics", "symbolic_match")

# prediction, gold, exact, symbolic
CASES = [
    ("22", "22", 1, 1),
    ("48", "48.0", 1, 1),
    ("48", "$48", 1, 1),
    ("48.5", "48", 0, 0),
    ("0.75", "3/4", 0, 1),
    ("0.5", "1/2", 0, 1),
    ("19/12", "\\frac{19}{12}", 0, 1),
    ("25*pi", "25\\pi", 0, 1),
    ("90", "90^\\circ", 0, 1),
    ("sqrt(144)", "12", 0, 1),
    ("12", "24", 0, 0),
    (None, "9", 0, 0),
    ("not a number", "7", 0, 0),
]

wrong_exact = []
wrong_symbolic = []
for prediction, gold, want_exact, want_symbolic in CASES:
    try:
        got_exact = exact_match(prediction, gold)
    except Exception as exc:
        die("exact_match raised %s on (%r, %r): %s"
            % (type(exc).__name__, prediction, gold, exc))
    try:
        got_symbolic = symbolic_match(prediction, gold)
    except Exception as exc:
        die("symbolic_match raised %s on (%r, %r); it has to treat an "
            "unparseable answer as wrong rather than raise: %s"
            % (type(exc).__name__, prediction, gold, exc))
    if float(got_exact) != float(want_exact):
        wrong_exact.append("%r vs %r wanted %s got %s"
                           % (prediction, gold, want_exact, got_exact))
    if float(got_symbolic) != float(want_symbolic):
        wrong_symbolic.append("%r vs %r wanted %s got %s"
                              % (prediction, gold, want_symbolic, got_symbolic))

if wrong_exact:
    die("exact_match got %d of %d cases wrong: %s"
        % (len(wrong_exact), len(CASES), "; ".join(wrong_exact[:3])))
if wrong_symbolic:
    die("symbolic_match got %d of %d cases wrong: %s"
        % (len(wrong_symbolic), len(CASES), "; ".join(wrong_symbolic[:3])))

# The whole point of the second metric is that it is strictly kinder than the
# first on the same data, without being kinder on answers that are wrong.
records = pool()
exact_total = sum(float(exact_match(r["predicted_answer"], r["gold_answer"]))
                  for r in records)
symbolic_total = sum(float(symbolic_match(r["predicted_answer"],
                                          r["gold_answer"]))
                     for r in records)
if symbolic_total <= exact_total:
    die("over the whole pool the symbolic metric scored %g and the string "
        "metric scored %g. The symbolic one has to recover the equivalent "
        "forms the string one misses" % (symbolic_total, exact_total))

win("%d metric cases correct, and over the pool the symbolic metric recovers "
    "%g answers the string metric marks wrong"
    % (len(CASES), symbolic_total - exact_total))
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

build_judge_prompt = load("harness.judge", "build_judge_prompt")
parse_judge_response = load("harness.judge", "parse_judge_response")
judge_prediction = load("harness.judge", "judge_prediction")

facts = expected()
keys = facts["rubric_keys"]

# 1. The parser has to survive the shapes a model actually replies in.
SHAPES = [
    ("fenced json",
     "```json\n{\"correct\": 1, \"reasoning_quality\": 4, "
     "\"used_tool_appropriately\": 1, \"explanation\": \"fine\"}\n```",
     1, 4),
    ("json after prose",
     "Here is my assessment.\n\n{\"correct\": 0, \"reasoning_quality\": 2, "
     "\"used_tool_appropriately\": 0, \"explanation\": \"no\"}\n\nThanks.",
     0, 2),
    ("bare json",
     "{\"correct\": 1, \"reasoning_quality\": 5, "
     "\"used_tool_appropriately\": 1, \"explanation\": \"good\"}", 1, 5),
]
for label, text, want_correct, want_quality in SHAPES:
    try:
        parsed = parse_judge_response(text)
    except Exception as exc:
        die("parse_judge_response raised %s on a %s reply: %s"
            % (type(exc).__name__, label, exc))
    if not isinstance(parsed, dict):
        die("parse_judge_response must return a dict, it returned %r"
            % type(parsed).__name__)
    for key in keys:
        if key not in parsed:
            die("parse_judge_response dropped the %s field from a %s reply"
                % (key, label))
    if int(parsed["correct"]) != want_correct:
        die("parse_judge_response read correct=%r from a %s reply, expected %d"
            % (parsed["correct"], label, want_correct))
    if int(parsed["reasoning_quality"]) != want_quality:
        die("parse_judge_response read reasoning_quality=%r from a %s reply, "
            "expected %d" % (parsed["reasoning_quality"], label, want_quality))

for label, text in (("a reply with no JSON in it",
                     "The work here is hard to follow so I would not award it."),
                    ("truncated JSON", "{\"correct\": 1, \"reasoning_qual"),
                    ("an empty reply", "")):
    try:
        parsed = parse_judge_response(text)
    except Exception as exc:
        die("parse_judge_response raised %s on %s. One unparseable reply must "
            "not take the run down: record it as a failure to grade and carry "
            "on: %s" % (type(exc).__name__, label, exc))
    if not isinstance(parsed, dict) or "correct" not in parsed:
        die("parse_judge_response returned %r for %s; it still has to return a "
            "record in the rubric shape" % (parsed, label))
    if int(parsed.get("correct", 1)) != 0:
        die("parse_judge_response scored %s as correct=%r. A reply that could "
            "not be read is not evidence that the answer was right"
            % (label, parsed.get("correct")))

# 2. The prompt has to carry everything the grader needs.
records = {r["id"]: r for r in pool()}
target = records["bh-103"]
try:
    prompt = build_judge_prompt(target)
except Exception as exc:
    die("build_judge_prompt raised %s: %s" % (type(exc).__name__, exc))
if not isinstance(prompt, str):
    die("build_judge_prompt must return a string, it returned %r"
        % type(prompt).__name__)

run = "tc03-prompt"
reset(run)
os.environ["BELLHAVEN_RUN_ID"] = run
try:
    verdict = judge_prediction(target, "nyx")
except Exception as exc:
    die("judge_prediction raised %s: %s" % (type(exc).__name__, exc))

seen = trace(run)
calls = seen.get("calls") or []
if seen.get("unmatched"):
    die("the grading model was sent %d prompt(s) it could not attribute to any "
        "submission; the problem text has to be in the prompt"
        % seen["unmatched"])
if not calls:
    die("judge_prediction did not reach the grading model at all")
call = calls[-1]
if call["family"] != "nyx":
    die("judge_prediction sent the work to the %s family when it was asked for "
        "nyx" % call["family"])
for flag, complaint in (
        ("has_gold", "the reference answer"),
        ("has_prediction", "the submitted answer"),
        ("has_trace", "the working the agent showed"),
        ("asks_rubric", "the four rubric fields it is supposed to return")):
    if not call.get(flag):
        die("the prompt the grading model received did not contain %s. A "
            "grader cannot score what it was not shown" % complaint)

if int(verdict.get("correct", -1)) != 1:
    die("judge_prediction returned correct=%r for a submission the nyx family "
        "scores as correct" % verdict.get("correct"))

win("parser survived %d reply shapes and 3 unreadable ones, and the prompt "
    "carried the problem, the reference answer, the submission, the working "
    "and the rubric" % len(SHAPES))
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

observed_agreement = load("harness.ensemble", "observed_agreement")
cohen_kappa = load("harness.ensemble", "cohen_kappa")
ensemble = load("harness.ensemble", "ensemble")

# label, first, second, expected observed, expected kappa (None = undefined)
CASES = [
    ("perfect agreement with variance", [1, 0, 1, 0], [1, 0, 1, 0], 1.0, 1.0),
    ("total disagreement", [1, 1, 0, 0], [0, 0, 1, 1], 0.0, -1.0),
    ("one grader used one label only", [1, 1, 1, 1], [1, 0, 1, 1], 0.75, None),
    ("both graders used one label only", [1, 1, 1, 1], [1, 1, 1, 1], 1.0, None),
    ("the mixed case",
     [1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 0, 1],
     [1, 1, 1, 0, 1, 1, 1, 0, 1, 1, 0, 1], 11 / 12.0, 0.75),
]

for label, first, second, want_observed, want_kappa in CASES:
    try:
        got_observed = observed_agreement(list(first), list(second))
    except Exception as exc:
        die("observed_agreement raised %s on %s: %s"
            % (type(exc).__name__, label, exc))
    if abs(float(got_observed) - want_observed) > 1e-6:
        die("observed_agreement returned %r for %s, expected %.4f"
            % (got_observed, label, want_observed))
    try:
        got_kappa = cohen_kappa(list(first), list(second))
    except Exception as exc:
        die("cohen_kappa raised %s on %s: %s" % (type(exc).__name__, label, exc))
    if want_kappa is None:
        if got_kappa is not None and got_kappa == got_kappa:
            die("cohen_kappa returned %r for the case where %s. Kappa is not "
                "computable without variance, and returning a number there is "
                "how a run in which everything scored the same gets reported "
                "as perfect agreement" % (got_kappa, label))
    else:
        if got_kappa is None or got_kappa != got_kappa:
            die("cohen_kappa returned %r for %s, expected %.4f"
                % (got_kappa, label, want_kappa))
        if abs(float(got_kappa) - want_kappa) > 1e-4:
            die("cohen_kappa returned %.4f for %s, expected %.4f"
                % (float(got_kappa), label, want_kappa))

first = [1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 0, 1]
second = [1, 1, 1, 0, 1, 1, 1, 0, 1, 1, 0, 1]
try:
    outcome = ensemble(list(first), list(second))
except Exception as exc:
    die("ensemble raised %s: %s" % (type(exc).__name__, exc))
try:
    resolved, review = outcome
except Exception:
    die("ensemble must return a pair of resolved verdicts and the positions "
        "needing review, it returned %r" % (outcome,))
if len(resolved) != len(first):
    die("ensemble returned %d verdicts for %d items"
        % (len(resolved), len(first)))
if list(review) != [3]:
    die("ensemble sent %r for review; the graders disagreed on exactly one "
        "item, at position 3" % (list(review),))
if resolved[3] is not None:
    die("ensemble settled position 3 as %r. Two graders who disagree do not "
        "make a majority; that item goes to a person"
        % (resolved[3],))
for index in range(len(first)):
    if index == 3:
        continue
    if resolved[index] != first[index]:
        die("ensemble resolved position %d as %r when both graders said %r"
            % (index, resolved[index], first[index]))

win("agreement and kappa correct on %d vectors including two degenerate ones, "
    "and the single disagreement was escalated rather than voted on"
    % len(CASES))
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
    local clean rc_clean strict kappa passed review size
    local tight rc_tight reasons
    clean="$(run_gate "gate-tc${TC}-clean" "$REPORT")"
    rc_clean="$(last_rc)"
    if [ -z "$clean" ]; then
        report "failed" "gate.py printed no LABJSON summary (exit ${rc_clean}); its output is in ${RUN_LOG}"
        return
    fi
    passed="$(field "$clean" .passed)"
    strict="$(field "$clean" .ensemble_strict)"
    kappa="$(field "$clean" .kappa)"
    size="$(field "$clean" .size)"
    review="$(field "$clean" '.review | join(",")')"
    if [ "$passed" != "true" ]; then
        reasons="$(field "$clean" '.reasons | join("; ")')"
        report "failed" "on a pool that should clear both gates, gate.py failed the build: ${reasons}"
        return
    fi
    if [ "$rc_clean" -ne 0 ]; then
        report "failed" "gate.py reported a passing build but exited ${rc_clean}; a passing gate has to exit 0 so it can sit in a pipeline"
        return
    fi
    if [ "$review" != "bh-104" ]; then
        report "failed" "the review queue held [${review}] when the two graders disagree on exactly bh-104. Anything else means the disagreements are not being escalated, or items are being escalated that both graders settled"
        return
    fi
    # Trip the agreement gate without changing anything else.
    tight="$(run_gate "gate-tc${TC}-tight" "${WORK}/tight.json" --min-kappa 0.95)"
    rc_tight="$(last_rc)"
    if [ -z "$tight" ]; then
        report "failed" "gate.py printed no summary when run with a higher agreement floor (exit ${rc_tight}); see ${RUN_LOG}"
        return
    fi
    if [ "$(field "$tight" .passed)" = "true" ] || [ "$rc_tight" -eq 0 ]; then
        report "failed" "with the agreement floor raised to 0.95 and a measured kappa of ${kappa}, gate.py still passed the build and exited ${rc_tight}. A score whose graders do not agree is the one you must not ship on"
        return
    fi
    if ! printf '%s' "$tight" | grep -qi 'kappa\|agreement'; then
        report "failed" "gate.py failed the build but its reasons do not say that agreement was what tripped; an on-call engineer has to know which gate fired"
        return
    fi
cat > "$PROBE" <<'PY'
BODY05
probe_header
cat <<'BODY05B'

# The path the gate was given, which is a directory it had to create itself.
path = os.environ["BH_REPORT"]
if not os.path.exists(path):
    die("gate.py wrote no report at the --out path it was given (%s); the "
        "directory has to be created if it is not there" % path)
try:
    with open(path) as handle:
        report = json.load(handle)
except Exception as exc:
    die("the report gate.py wrote is not readable JSON: %s" % exc)

for section in ("dataset", "metrics", "agreement", "review_queue", "gate"):
    if section not in report:
        die("the report has no %s section" % section)

metrics = report["metrics"]
for name in ("exact_match", "symbolic_match", "ensemble_strict"):
    if name not in metrics:
        die("the report does not carry the %s figure. A single accuracy number "
            "with no metric named beside it is not a result" % name)
if not (metrics["symbolic_match"] > metrics["exact_match"]):
    die("the report puts the symbolic metric at %r and the string metric at "
        "%r; on this pool the symbolic one recovers answers the string one "
        "marks wrong" % (metrics["symbolic_match"], metrics["exact_match"]))

agreement = report["agreement"]
if "kappa" not in agreement or "observed" not in agreement:
    die("the report gives kappa without the raw observed agreement beside it, "
        "or the other way round. High observed agreement with a low kappa is "
        "the ordinary case and quoting one alone hides it")
if abs(float(agreement["observed"]) - 11 / 12.0) > 1e-6:
    die("the report puts observed agreement at %r, and the two graders agree "
        "on 11 of the 12 items" % agreement["observed"])
if agreement["kappa"] is None or abs(float(agreement["kappa"]) - 0.75) > 1e-3:
    die("the report puts kappa at %r; on these two graders it is 0.75"
        % agreement["kappa"])

if report["review_queue"] != ["bh-104"]:
    die("the report review queue is %r, expected the one item the graders "
        "disagree on" % (report["review_queue"],))
if not report["gate"].get("passed"):
    die("the report records a failed gate for a run that passed")

# The report has to describe grading that actually happened. The desk counted
# every prompt it was sent for that run.
seen = trace("gate-tc05-clean")
calls = seen.get("calls") or []
size = int(report["dataset"]["size"])
if len(calls) < 2 * size:
    die("the desk was sent %d grading prompts for a report covering %d items "
        "with two graders; a report is a record of grading that happened, not "
        "a document produced beside it" % (len(calls), size))
families = {call["family"] for call in calls}
if len(families) < 2:
    die("every grading prompt went to the %s family. Two graders from the same "
        "family agree with each other for reasons that have nothing to do with "
        "the answer being right" % ", ".join(sorted(families)))
graded_ids = {call["item"] for call in calls}
missing = [i for i in report["dataset"]["ids"] if i not in graded_ids]
if missing:
    die("these items are in the report but were never sent to a grader: %s"
        % missing[:3])

win("gate passed a clean pool and exited 0, failed on a raised agreement floor "
    "with a reason that names it, escalated exactly the disagreement, and the "
    "report carries both metrics, both agreement figures and the queue")
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
