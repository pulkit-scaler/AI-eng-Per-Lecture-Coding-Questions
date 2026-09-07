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
exec 2>>"/tmp/ashcombe_tc${TC}.err"
STATUS_SENT=0
report() {
    if [ "$STATUS_SENT" -eq 1 ]; then return 0; fi
    STATUS_SENT=1
    print_status "$1" "$2"
}

LAB_DIR="${LAB_DIR:-/home/user/ashcombe-intake}"
DESK_URL="${DESK_URL:-http://127.0.0.1:8777}"
DESK_BIN="${DESK_BIN:-/opt/ashcombe-svc/intakesvc.py}"
GKEY_HEADER="X-Grader-Key: ashcombe-grader-ac5t"
GPATH="__ac5t"
PY="${PY:-python3}"
DEPS_READY_FILE="${DEPS_READY_FILE:-/var/log/ashcombe-lab/deps.ready}"
TIMING_LOG="${TIMING_LOG:-/tmp/ashcombe_timing.log}"
RUN_LOG="/tmp/ashcombe_tc${TC}.log"
export PYTHONDONTWRITEBYTECODE=1

# --- time budget -----------------------------------------------------------
# The one heavy import here is the PDF library, paid once per interpreter
# start. One deadline is shared across every start a check makes, because
# separate per-call bounds would add up past the portal cap.
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
WORK="$(mktemp -d 2>/dev/null || echo /tmp/ac_work_$$)"
mkdir -p "$WORK" 2>/dev/null
chmod 700 "$WORK" 2>/dev/null
PROBE="${WORK}/probe.py"
RC_FILE="${WORK}/rc"
INBOX="${WORK}/inbox"
OUTDIR="${WORK}/out"
LEDGER="${WORK}/ledger.jsonl"

# Grading runs as root while the learner is user. The gate WRITES its report
# into the project, so ownership goes back from the EXIT trap rather than from
# a success path.
on_exit() {
    local rc=$?
    case "$LAB_DIR" in
        /home/user/*) chown -R user:user "$LAB_DIR" >/dev/null 2>&1 ;;
    esac
    rm -rf "$WORK" >/dev/null 2>&1
    printf 'script_%s %ss\n' "$TC" "$SECONDS" >>"$TIMING_LOG" 2>/dev/null || true
    report "failed" "TC${TC} ended without reaching a verdict (rc=${rc})"
}
trap on_exit EXIT

# The readiness file is the ONLY thing that means the detached install has
# resolved. It is deliberately not proxied by "curl and jq are present": those
# two are installed in the foreground now, so a proxy on them is always true and
# a check would run before the PDF library exists - and then blame the learner
# for code that cannot import it.
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

# A VM whose PDF library never installed is a broken VM, not a wrong answer.
# Say so, instead of reporting that the learner triage module does not import.
require_pdf_lib() {
    "$PY" -c "import fitz" >/dev/null 2>&1 && return 0
    report "failed" "the PDF library this lab runs on is not installed on this VM, so nothing here can be graded - this is an environment fault, not your code. The install log is at /var/log/ashcombe-lab/deps.log"
    return 1
}

ensure_desk() {
    curl -sf -m "$CURL_MAX" "${DESK_URL}/health" >/dev/null 2>&1 && return 0
    [ -f "$DESK_BIN" ] || return 1
    spawn_detached /tmp/ashcombe_desk.log "$PY" "$DESK_BIN"
    local i
    for i in $(seq 1 "$SVC_WAIT"); do
        curl -sf -m 2 "${DESK_URL}/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

# The graded documents come from the desk, so they are never in the learner
# project and never in the setup script.
fetch_corpus() {
    local raw="${WORK}/corpus.json"
    curl -sf -m "$CURL_MAX" -H "$GKEY_HEADER" \
        "${DESK_URL}/${GPATH}/corpus?set=graded" -o "$raw" 2>/dev/null
    [ -s "$raw" ] || return 1
    mkdir -p "$INBOX" "$OUTDIR"
    CORPUS_JSON="$raw" INBOX_DIR="$INBOX" "$PY" - <<'UNPACK'
import base64, json, os, sys
with open(os.environ["CORPUS_JSON"]) as handle:
    payload = json.load(handle)
target = os.environ["INBOX_DIR"]
for document in payload["documents"]:
    with open(os.path.join(target, document["name"]), "wb") as out:
        out.write(base64.b64decode(document["b64"]))
sys.stderr.write("unpacked %d\n" % len(payload["documents"]))
UNPACK
    [ -n "$(ls -A "$INBOX" 2>/dev/null)" ] || return 1
    return 0
}

reset_run() {
    curl -sf -m "$CURL_MAX" -X POST -H "$GKEY_HEADER" \
        "${DESK_URL}/${GPATH}/reset?run=$1" >/dev/null 2>&1
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
                ASHCOMBE_DESK_URL="$DESK_URL" \
                AC_GKEY="ashcombe-grader-ac5t" \
                AC_GPATH="$GPATH" \
                AC_INBOX="$INBOX" \
                AC_OUT="$OUTDIR" \
                AC_LEDGER="$LEDGER" \
      && bounded "$budget" "$PY" "$PROBE" </dev/null ) >"$RUN_LOG" 2>&1
    LAST_RC=$?
    echo "$LAST_RC" >"$RC_FILE" 2>/dev/null
    grep -o 'LABJSON:.*' "$RUN_LOG" 2>/dev/null | tail -1 | sed 's/^LABJSON://'
    return "$LAST_RC"
}

WORKER_RC=0
# run_worker <run-id> : drain the graded inbox with the learner worker and echo
# its LABJSON summary. The directories are the ones this check owns, so nothing
# is written into the learner project.
run_worker() {
    local rid="$1"; shift
    reset_run "$rid"
    local budget
    budget="$(budget_left)"
    if [ "$budget" -eq 0 ]; then WORKER_RC=124; return 124; fi
    ( cd "$LAB_DIR" 2>/dev/null \
      && export PYTHONPATH="$LAB_DIR" \
                ASHCOMBE_DESK_URL="$DESK_URL" \
                ASHCOMBE_RUN_ID="$rid" \
      && bounded "$budget" "$PY" -m intake.worker --once \
             --inbox "$INBOX" --out "$OUTDIR" --ledger "$LEDGER" \
             "$@" </dev/null ) >"$RUN_LOG" 2>&1
    WORKER_RC=$?
    echo "$WORKER_RC" >"$RC_FILE" 2>/dev/null
    grep -o 'LABJSON:.*' "$RUN_LOG" 2>/dev/null | tail -1 | sed 's/^LABJSON://'
    return "$WORKER_RC"
}

last_rc() { cat "$RC_FILE" 2>/dev/null || echo 0; }

# Pointing a learner at an empty file is a dead end. When a run printed nothing
# at all, say that instead, and name the usual cause: a module that defines its
# helpers but never runs anything when invoked as a command.
run_evidence() {
    if [ -s "$RUN_LOG" ]; then
        printf 'its output is in %s' "$RUN_LOG"
    else
        printf 'it printed nothing at all, so %s is empty. A module that only defines functions exits quietly like this: check that "python3 -m intake.worker --once" really parses its arguments, drains the spool and prints the LABJSON line' "$RUN_LOG"
    fi
}

fail_no_json() {
    report "failed" "${1} - no LABJSON line came back (exit $(last_rc)); $(run_evidence)"
}

field() { printf '%s' "$1" | jq -r "$2" 2>/dev/null; }

# Refuse an unstarted project in about a second, naming every plausible cause.
require_started() {
    local missing="" f
    for f in intake/triage.py intake/chunk.py intake/worker.py; do
        [ -s "${LAB_DIR}/${f}" ] || missing="${missing} ${f}"
    done
    if [ -n "$missing" ]; then
        report "failed" "these files are missing or empty in ${LAB_DIR}:${missing}"
        return 1
    fi
    local untouched
    untouched="$(grep -l 'is not written yet' "${LAB_DIR}/intake"/*.py \
        2>/dev/null | xargs -n1 basename 2>/dev/null | tr '\n' ' ')"
    if [ -n "$untouched" ]; then
        report "failed" "these still hold the untouched starter: ${untouched}- write the three intake modules, then run python3 check_local.py from ${LAB_DIR} before submitting"
        return 1
    fi
    return 0
}

preflight() {
    ensure_deps || { report "failed" "curl and jq are not installed yet; the setup job that installs them has not finished"; return 1; }
    ensure_desk || { report "failed" "the intake desk is not reachable on ${DESK_URL}"; return 1; }
    fetch_corpus || { report "failed" "Grader could not read its documents from the intake desk on ${DESK_URL}"; return 1; }
    require_pdf_lib || return 1
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

GK = os.environ.get("AC_GKEY", "")
GP = os.environ.get("AC_GPATH", "")
BASE = os.environ.get("ASHCOMBE_DESK_URL", "http://127.0.0.1:8777")
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


INBOX = os.environ.get("AC_INBOX", "")
OUTDIR = os.environ.get("AC_OUT", "")
LEDGER = os.environ.get("AC_LEDGER", "")


def documents():
    """The graded documents, by name, with what the desk knows about them."""
    payload = _get("/" + GP + "/corpus?set=graded")
    return {d["name"]: d for d in payload["documents"]}


def ledger_rows():
    if not os.path.exists(LEDGER):
        return []
    rows = []
    with open(LEDGER) as handle:
        for line in handle:
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except ValueError:
                    pass
    return rows


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
    reset_run "tc01"
cat > "$PROBE" <<'PY'
BODY01
probe_header
cat <<'BODY01B'

classify = load("intake.triage", "classify")

FLAVOR_OF = {"digital": "digital", "scanned": "scanned", "mixed": "mixed"}

before = trace("tc01").get("parses") or []
known = documents()
wrong = []
for name, document in sorted(known.items()):
    path = os.path.join(INBOX, name)
    try:
        result = classify(path)
    except Exception as exc:
        die("classify raised %s on %s: %s" % (type(exc).__name__, name, exc))
    if not isinstance(result, dict):
        die("classify must return a dict, it returned %r for %s"
            % (type(result).__name__, name))
    for key in ("flavor", "pages", "text_pages"):
        if key not in result:
            die("classify left %s out of its answer for %s" % (key, name))

    pages = int(document["pages"])
    text_pages = list(document["text_pages"])
    if len(text_pages) == pages:
        expected = "digital"
    elif not text_pages:
        expected = "scanned"
    else:
        expected = "mixed"

    if str(result["flavor"]) != expected:
        wrong.append("%s is %s, called %s" % (name, expected, result["flavor"]))
        continue
    if int(result["pages"]) != pages:
        wrong.append("%s has %d pages, reported %s"
                     % (name, pages, result["pages"]))
    if sorted(int(p) for p in result["text_pages"]) != sorted(text_pages):
        wrong.append("%s carries text on pages %s, reported %s"
                     % (name, text_pages, result["text_pages"]))

if wrong:
    die("triage got %d of %d documents wrong: %s"
        % (len(wrong), len(known), "; ".join(wrong[:3])))

after = trace("tc01").get("parses") or []
if len(after) != len(before):
    die("classify sent %d document(s) to the parsing API. Triage is the cheap "
        "look you take before you pay to parse anything, and it has to answer "
        "from the file itself" % (len(after) - len(before)))

flavors = {}
for name, document in known.items():
    pages = int(document["pages"])
    text_pages = list(document["text_pages"])
    key = ("digital" if len(text_pages) == pages
           else "scanned" if not text_pages else "mixed")
    flavors[key] = flavors.get(key, 0) + 1
win("all %d documents triaged correctly (%s), and none of them went near the "
    "parsing API to do it"
    % (len(known), ", ".join("%d %s" % (v, k) for k, v in sorted(flavors.items()))))
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
    local summary
    summary="$(run_worker "tc02")"
    if [ -z "$summary" ]; then
        report "failed" "the worker printed no LABJSON summary (exit $(last_rc)); $(run_evidence)"
        return
    fi
cat > "$PROBE" <<'PY'
BODY02
probe_header
cat <<'BODY02B'

EXPECTED_STRATEGY = {"digital": "fast", "mixed": "hi_res",
                     "scanned": "ocr_only"}
COST_PER_PAGE = {"fast": 1, "hi_res": 5, "ocr_only": 8}

known = documents()
seen = trace("tc02")
parses = seen.get("parses") or []
if not parses:
    die("the parsing API was never called. Draining the spool has to actually "
        "parse the documents in it")
if seen.get("unknown"):
    die("%d parse request(s) carried a document the intake account does not "
        "hold; the bytes sent have to be the bytes of the file"
        % seen["unknown"])

by_name = {}
for parse in parses:
    by_name.setdefault(parse["name"], []).append(parse)

missing = [name for name in known if name not in by_name]
if missing:
    die("these documents were never parsed: %s" % ", ".join(sorted(missing)))

wrong = []
repeats = []
budget = 0
for name, document in sorted(known.items()):
    pages = int(document["pages"])
    text_pages = list(document["text_pages"])
    flavor = ("digital" if len(text_pages) == pages
              else "scanned" if not text_pages else "mixed")
    want = EXPECTED_STRATEGY[flavor]
    budget += COST_PER_PAGE[want] * pages
    chosen = {p["strategy"] for p in by_name[name]}
    if chosen != {want}:
        wrong.append("%s is %s so it needs %s, it was sent to %s"
                     % (name, flavor, want, ", ".join(sorted(chosen))))
    if len(by_name[name]) > 1:
        repeats.append("%s parsed %d times" % (name, len(by_name[name])))

if wrong:
    die("%d document(s) went to the wrong strategy: %s"
        % (len(wrong), "; ".join(wrong[:3])))
if repeats:
    die("the same document was parsed more than once in a single drain: %s"
        % "; ".join(repeats[:3]))

spent = int(seen.get("cost_units") or 0)
if spent > budget:
    die("the drain cost %d units where %d was enough. Reaching for the "
        "expensive strategy on a document that does not need it is the whole "
        "cost of getting routing wrong" % (spent, budget))

rows = ledger_rows()
if len(rows) < len(known):
    die("the ledger holds %d rows for %d documents" % (len(rows), len(known)))
for row in rows:
    if row.get("status") == "ok" and not row.get("strategy"):
        die("a ledger row for %r does not record which strategy was used"
            % row.get("source"))

produced = [f for f in os.listdir(OUTDIR)] if os.path.isdir(OUTDIR) else []
for name in sorted(known):
    stem = os.path.splitext(name)[0]
    if not any(f.startswith(stem) for f in produced):
        die("%s was parsed but left no artefact behind" % name)

win("all %d documents routed by flavor, each parsed once, %d cost units spent "
    "against a budget of %d, and every document left an artefact"
    % (len(known), spent, budget))
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

layout_aware_chunks = load("intake.chunk", "layout_aware_chunks")

TABLE_TEXT = ("Line  Part        Qty   Unit\n"
              "1     RK-90        12    4.25\n"
              "2     RK-91        30    2.10\n"
              "3     RK-92         6   11.80")
LONG_A = "Delivery is expected before the end of the month. " * 4
LONG_B = "Late fees apply after the due date stated on the order. " * 4

ELEMENTS = [
    {"type": "Title", "text": "Rookhope Castings order", "page": 1},
    {"type": "NarrativeText", "text": "Order RC-6120 raised on 2026-05-02.",
     "page": 1},
    {"type": "Table", "text": TABLE_TEXT, "page": 1},
    {"type": "NarrativeText", "text": LONG_A, "page": 1},
    {"type": "NarrativeText", "text": LONG_B, "page": 1},
    {"type": "Title", "text": "Delivery instructions", "page": 2},
    {"type": "NarrativeText", "text": "Deliver to gate two before ten.",
     "page": 2},
    {"type": "NarrativeText", "text": "   ", "page": 2},
]
SOURCE = "rookhope-order.pdf"
MAX_CHARS = 400

try:
    chunks = layout_aware_chunks(list(ELEMENTS), SOURCE, MAX_CHARS)
except TypeError:
    try:
        chunks = layout_aware_chunks(list(ELEMENTS), SOURCE)
    except Exception as exc:
        die("layout_aware_chunks raised %s: %s" % (type(exc).__name__, exc))
except Exception as exc:
    die("layout_aware_chunks raised %s: %s" % (type(exc).__name__, exc))

if not isinstance(chunks, list) or not chunks:
    die("layout_aware_chunks returned %r; it has to return a list of chunks"
        % (chunks,))
if not all(isinstance(c, str) for c in chunks):
    die("every chunk has to be a string; got %s"
        % sorted({type(c).__name__ for c in chunks}))

missing_source = [i for i, c in enumerate(chunks) if SOURCE not in c]
if missing_source:
    die("%d chunk(s) do not name the document they came from. A retrieved "
        "fragment with no source is a fragment nobody can check"
        % len(missing_source))

table_chunks = [c for c in chunks if "RK-91" in c]
if len(table_chunks) != 1:
    die("the table appears in %d chunks. A table is one unit: split it and the "
        "rows lose the header that gave them meaning" % len(table_chunks))
table_chunk = table_chunks[0]
for row in ("RK-90", "RK-91", "RK-92", "Qty"):
    if row not in table_chunk:
        die("the table chunk lost %r" % row)
if "Order RC-6120" in table_chunk or "Delivery is expected" in table_chunk:
    die("the table chunk has narrative text merged into it; keeping a table "
        "whole also means keeping other things out of it")
if "Rookhope Castings order" not in table_chunk:
    die("the table chunk does not carry the section title it sat under, so a "
        "reader has no idea which order it belongs to")

tail = [c for c in chunks if "Deliver to gate two" in c]
if len(tail) != 1:
    die("the closing narrative landed in %d chunks" % len(tail))
if "Delivery instructions" not in tail[0]:
    die("a chunk under the second title still carries the first title as its "
        "section; the section has to follow the document")

long_chunks = [c for c in chunks if "Delivery is expected" in c
               or "Late fees apply" in c]
if not long_chunks:
    die("the long narrative disappeared from the output entirely")
oversized = [len(c) for c in chunks if len(c) > MAX_CHARS * 2]
if oversized:
    die("a narrative chunk came out at %d characters against a limit of %d; "
        "the limit is what keeps a chunk retrievable"
        % (max(oversized), MAX_CHARS))
if len(long_chunks) < 2:
    die("both long narrative elements were packed into one chunk of %d "
        "characters against a limit of %d"
        % (max(len(c) for c in long_chunks), MAX_CHARS))

blank = [c for c in chunks if not c.split("]", 1)[-1].strip()]
if blank:
    die("%d chunk(s) carry no text at all; an element with nothing in it is "
        "not worth a chunk" % len(blank))

if layout_aware_chunks([], SOURCE, MAX_CHARS):
    die("an empty element list produced chunks")

win("%d chunks: the table stayed whole and labelled, every chunk names its "
    "source and its section, the section follows the document, the long "
    "narrative was split at the limit and the empty element was dropped"
    % len(chunks))
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
    local first second third
    first="$(run_worker "tc04-a")"
    if [ -z "$first" ]; then
        report "failed" "the worker printed no LABJSON summary on the first drain (exit $(last_rc)); $(run_evidence)"
        return
    fi
    second="$(run_worker "tc04-b")"
    if [ -z "$second" ]; then
        report "failed" "the worker printed no LABJSON summary on the second drain (exit $(last_rc)); $(run_evidence)"
        return
    fi
    # The same bytes under a different name is still the same document.
    FIRST_DOC="$(ls -1 "$INBOX" | head -1)"
    cp "${INBOX}/${FIRST_DOC}" "${INBOX}/renamed-copy.pdf" 2>/dev/null
    third="$(run_worker "tc04-c")"
    if [ -z "$third" ]; then
        report "failed" "the worker printed no LABJSON summary on the third drain (exit $(last_rc)); $(run_evidence)"
        return
    fi
    export AC_FIRST="$first" AC_SECOND="$second" AC_THIRD="$third"
cat > "$PROBE" <<'PY'
BODY04
probe_header
cat <<'BODY04B'

first = json.loads(os.environ["AC_FIRST"])
second = json.loads(os.environ["AC_SECOND"])
third = json.loads(os.environ["AC_THIRD"])
known = documents()

if int(first.get("processed", 0)) != len(known):
    die("the first drain processed %s of %d documents"
        % (first.get("processed"), len(known)))

parses_b = trace("tc04-b").get("parses") or []
if parses_b:
    die("the second drain sent %d document(s) back to the parsing API. Work "
        "already done is not paid for twice: %s"
        % (len(parses_b), ", ".join(sorted({p["name"] for p in parses_b}))))
if int(second.get("processed", 0)) != 0:
    die("the second drain reports %s document(s) processed over an inbox that "
        "had not changed" % second.get("processed"))
if int(second.get("skipped", 0)) != len(known):
    die("the second drain reports %s skipped, expected %d"
        % (second.get("skipped"), len(known)))

rows_now = ledger_rows()
if len(rows_now) != len(known):
    die("the ledger holds %d rows after two drains of %d documents; a document "
        "that was skipped is not a document that was processed"
        % (len(rows_now), len(known)))

parses_c = trace("tc04-c").get("parses") or []
if parses_c:
    die("a copy of a document already handled, under a different filename, was "
        "parsed again. The same bytes are the same document whatever the file "
        "is called (%s)" % ", ".join(sorted({p["name"] for p in parses_c})))
if int(third.get("processed", 0)) != 0:
    die("the third drain processed %s document(s); the only new file was a "
        "copy of one already done" % third.get("processed"))

produced = sorted(os.listdir(OUTDIR)) if os.path.isdir(OUTDIR) else []
for name in sorted(known):
    stem = os.path.splitext(name)[0]
    if not any(f.startswith(stem) for f in produced):
        die("%s has no artefact after three drains" % name)
if any(f.startswith("renamed-copy") for f in produced):
    die("the copy under a new filename produced a second artefact for a "
        "document that had already been done")

win("first drain did %d documents, the second did none and cost nothing, and a "
    "copy under a new filename was recognised as the same document"
    % len(known))
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
    local summary
    # Two documents nobody can parse, dropped in among the good ones.
    printf 'this is not a PDF at all, it is a note somebody saved wrong\n' \
        > "${INBOX}/scanner-error.pdf"
    : > "${INBOX}/zero-bytes.pdf"
    summary="$(run_worker "tc05")"
    WORKER_EXIT="$(last_rc)"
    if [ -z "$summary" ]; then
        report "failed" "the worker printed no LABJSON summary (exit ${WORKER_EXIT}); one unreadable document must not stop it printing a result. $(run_evidence)"
        return
    fi
    if [ "$WORKER_EXIT" -ne 0 ]; then
        report "failed" "the worker exited ${WORKER_EXIT} because two of the documents in the spool could not be read. A corrupt document is a recorded failure, not a failed run - the other documents were still there to be done"
        return
    fi
    export AC_SUMMARY="$summary"
cat > "$PROBE" <<'PY'
BODY05
probe_header
cat <<'BODY05B'

summary = json.loads(os.environ["AC_SUMMARY"])
known = documents()
BROKEN = {"scanner-error.pdf", "zero-bytes.pdf"}

if int(summary.get("failed", 0)) != len(BROKEN):
    die("the run reports %s failed document(s); two of the files in the spool "
        "could not be read" % summary.get("failed"))
if int(summary.get("processed", 0)) != len(known):
    die("the run reports %s processed; the %d readable documents were still "
        "there to be done after the unreadable ones"
        % (summary.get("processed"), len(known)))

rows = ledger_rows()
by_source = {}
for row in rows:
    by_source.setdefault(row.get("source"), []).append(row)

for name in sorted(BROKEN):
    entries = by_source.get(name) or []
    if not entries:
        die("%s is not in the ledger at all. A document that could not be read "
            "still has to be accounted for, or nobody knows it was dropped"
            % name)
    row = entries[-1]
    if row.get("status") != "failed":
        die("%s is recorded with status %r" % (name, row.get("status")))
    reason = str(row.get("reason") or "").strip()
    if len(reason) < 8:
        die("%s is recorded as failed with no reason. The reason is what tells "
            "somebody whether to re-scan it or chase the sender" % name)

for name in sorted(known):
    entries = [r for r in (by_source.get(name) or []) if r.get("status") == "ok"]
    if not entries:
        die("%s has no successful ledger row; the readable documents have to "
            "come through regardless of what else was in the spool" % name)

produced = set(os.listdir(OUTDIR)) if os.path.isdir(OUTDIR) else set()
for name in sorted(known):
    stem = os.path.splitext(name)[0]
    if not any(f.startswith(stem) for f in produced):
        die("%s produced no artefact" % name)
for name in sorted(BROKEN):
    stem = os.path.splitext(name)[0]
    if any(f.startswith(stem) for f in produced):
        die("%s produced an artefact even though it could not be read" % name)

seen = trace("tc05")
if seen.get("unknown"):
    die("%d unreadable document(s) were sent to the parsing API anyway. Triage "
        "is what stops you paying to parse a file that is not a document"
        % seen["unknown"])

win("both unreadable documents recorded as failed with a reason and no "
    "artefact, all %d readable documents still came through, and the run "
    "exited cleanly" % len(known))
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
