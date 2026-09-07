#!/bin/bash
# Ordering matrix for the Larkspur Transit lab.
#
# The happy path passing tells you almost nothing: the failures that reach learners
# come from orderings nobody tried - submitting before writing anything, a grading
# run killed before the last check, a second submission, working after a grading
# run. Every row asserts the intended SCORE and, when it can, that the learner is
# not locked out of their own VM.
#
# Runs in two modes:
#   VM      (as root, LAB_DIR=/home/user/larkspur-transit) - asserts ownership too
#   LOCAL   (as anybody, LAB_DIR under /tmp)               - asserts scores only,
#                                                            and says which rows
#                                                            it had to skip
#
#   PY=<venv>/bin/python ./validation/permutations.sh
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PY="${PY:-python3}"
PORT="${PORT:-9701}"
SVC_URL="http://127.0.0.1:${PORT}"
SVC_BIN="$DIR/service/opsd.py"
REF="$DIR/reference-solution"

if [ "$(id -u)" = "0" ] && [ -d /home/user ]; then
    MODE="VM"; LAB_DIR="/home/user/larkspur-transit"
else
    MODE="LOCAL"; LAB_DIR="${LAB_DIR:-/tmp/larkspur-perm}"
fi
export LAB_DIR SVC_URL SVC_BIN PY
export LARKSPUR_PORT="$PORT" LARKSPUR_SERVICE_URL="$SVC_URL"

PASS=0; FAILED=0; SKIPPED=0
note() { printf '%s\n' "$*"; }
check() {
    local label="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then PASS=$((PASS+1)); printf '      ok   %-34s %s\n' "$label" "$got"
    else FAILED=$((FAILED+1)); printf '      FAIL %-34s want=%s got=%s\n' "$label" "$want" "$got"; fi
}
skip() { SKIPPED=$((SKIPPED+1)); printf '      skip %-34s %s\n' "$1" "$2"; }

start_service() {
    curl -sf -m 3 "${SVC_URL}/health" >/dev/null 2>&1 && return 0
    SETSID="$(command -v setsid || true)"
    LARKSPUR_PORT="$PORT" LARKSPUR_DB="$LAB_DIR/data/transit.db" \
        ${SETSID:+"$SETSID"} nohup "$PY" "$SVC_BIN" \
        >/tmp/larkspur_perm_svc.log 2>&1 </dev/null &
    local i
    for i in $(seq 1 20); do
        curl -sf -m 2 "${SVC_URL}/health" >/dev/null 2>&1 && return 0
        sleep 1
    done
    return 1
}

# reset_lab <server-source|none> <solution-source|none>
reset_lab() {
    rm -rf "$LAB_DIR"
    mkdir -p "$LAB_DIR/data" "$LAB_DIR/transit_kit"
    cp -R "$DIR/app/transit_kit/." "$LAB_DIR/transit_kit/"
    cp "$DIR/app/check_local.py" "$LAB_DIR/"
    printf '%s' "$SVC_URL" > "$LAB_DIR/transit_kit/service.url"
    "$PY" "$DIR/app/seed_db.py" "$LAB_DIR/data/transit.db" >/dev/null
    mkdir -p "$LAB_DIR/__pycache__" "$LAB_DIR/transit_kit/__pycache__"
    if [ "$1" = "none" ]; then cp "$DIR/app/server_stub.py" "$LAB_DIR/server.py"
    else cp "$1" "$LAB_DIR/server.py"; fi
    if [ "$2" = "none" ]; then cp "$DIR/app/solution_stub.py" "$LAB_DIR/solution.py"
    else cp "$2" "$LAB_DIR/solution.py"; fi
    if [ "$MODE" = "VM" ]; then chown -R user:user "$LAB_DIR"; fi
}

# grade full|partial|portal -> score
#
# Reads the LAST line of stdout+stderr and parses it as the JSON object the real
# common.sh emits, which is what the platform grades. Matching a RESULT: line
# anywhere would score a check whose verdict had been voided by a trailing line.
#
# "full" runs all five and sums them, which is what this matrix wants when it is
# asking whether a check leaves the VM in a good state. "portal" stops at the
# first failure, which is what main.sh actually does, so partial credit on the
# portal is a PREFIX of the five checks and not a per-theme sum.
grade() {
    local glob='script_0[1-5].sh' stop_at_first=0
    case "$1" in
        partial) glob='script_0[1-3].sh' ;;
        portal)  stop_at_first=1 ;;
    esac
    ( cd / && unset LARKSPUR_DB LARKSPUR_SESSION_ID
      p=0
      for s in "$DIR"/test-cases/scripts/$glob; do
          out="$(bash "$s" 2>&1)"
          last="$(printf '%s\n' "$out" | tail -n 1)"
          st="$(printf '%s' "$last" | jq -r '.status // "UNPARSEABLE"' 2>/dev/null || echo UNPARSEABLE)"
          if [ "$st" = "success" ]; then
              p=$((p+1))
          else
              [ "$stop_at_first" = "1" ] && break
          fi
      done
      echo $((p * 10)) )
}

root_owned() {
    [ "$MODE" = "VM" ] || { echo "-"; return; }
    find "$LAB_DIR" ! -user user 2>/dev/null | wc -l | tr -d ' '
}

learner_can_work() {
    local rc
    if [ "$MODE" = "VM" ]; then
        su - user -c "cd '$LAB_DIR' && python3 check_local.py" >/tmp/larkspur_perm_work.log 2>&1
        rc=$?
    else
        ( cd "$LAB_DIR" && "$PY" check_local.py ) >/tmp/larkspur_perm_work.log 2>&1
        rc=$?
    fi
    [ "$rc" -eq 0 ] && grep -q 'run_agent_loop' /tmp/larkspur_perm_work.log && echo yes || echo no
}

stray_servers() {
    pgrep -f 'server\.py' 2>/dev/null | wc -l | tr -d ' '
}

note "mode: $MODE   lab: $LAB_DIR   service: $SVC_URL"
reset_lab "$REF/server.py" "$REF/solution.py"
start_service || { echo "ERROR: operations service would not start"; exit 1; }

note ""
note "[1] both files written, graded once"
reset_lab "$REF/server.py" "$REF/solution.py"
check "score" 50 "$(grade full)"
check "stray server.py processes" 0 "$(stray_servers)"
if [ "$MODE" = "VM" ]; then check "files not owned by user" 0 "$(root_owned)"
else skip "files not owned by user" "no lab user off-VM"; fi
check "learner can still work" yes "$(learner_can_work)"

note ""
note "[2] nothing written (the starter stubs), graded"
reset_lab none none
check "score" 0 "$(grade full)"
check "stray server.py processes" 0 "$(stray_servers)"
if [ "$MODE" = "VM" ]; then check "files not owned by user" 0 "$(root_owned)"
else skip "files not owned by user" "no lab user off-VM"; fi

note ""
note "[3] server written, client still a stub"
reset_lab "$REF/server.py" none
check "score" 40 "$(grade full)"
if [ "$MODE" = "VM" ]; then check "files not owned by user" 0 "$(root_owned)"
else skip "files not owned by user" "no lab user off-VM"; fi

note ""
note "[4] client written, server still a stub"
reset_lab none "$REF/solution.py"
check "score" 0 "$(grade full)"
if [ "$MODE" = "VM" ]; then check "files not owned by user" 0 "$(root_owned)"
else skip "files not owned by user" "no lab user off-VM"; fi

note ""
note "[5] one file missing from disk entirely"
reset_lab "$REF/server.py" "$REF/solution.py"
rm -f "$LAB_DIR/solution.py"
check "score" 40 "$(grade full)"
check "stray server.py processes" 0 "$(stray_servers)"

note ""
note "[6] partial grading (killed after the third check)"
reset_lab "$REF/server.py" "$REF/solution.py"
check "score" 30 "$(grade partial)"
if [ "$MODE" = "VM" ]; then check "files not owned by user" 0 "$(root_owned)"
else skip "files not owned by user" "no lab user off-VM"; fi
check "learner can still work" yes "$(learner_can_work)"

note ""
note "[7] graded twice in a row"
reset_lab "$REF/server.py" "$REF/solution.py"
t0=$SECONDS; first="$(grade full)"; t1=$((SECONDS - t0))
t0=$SECONDS; second="$(grade full)"; t2=$((SECONDS - t0))
check "first score" 50 "$first"
check "second score" 50 "$second"
check "second run no slower than 2x" yes "$([ "$t2" -le $((t1 * 2 + 5)) ] && echo yes || echo no)"
note "      (first ${t1}s, second ${t2}s)"

note ""
note "[8] graded first, then the learner works, then graded again"
reset_lab none none
check "score before any work" 0 "$(grade full)"
cp "$REF/server.py" "$LAB_DIR/server.py"
cp "$REF/solution.py" "$LAB_DIR/solution.py"
if [ "$MODE" = "VM" ]; then chown user:user "$LAB_DIR/server.py" "$LAB_DIR/solution.py"; fi
check "learner can work after grading" yes "$(learner_can_work)"
check "score after the work" 50 "$(grade full)"
if [ "$MODE" = "VM" ]; then check "files not owned by user" 0 "$(root_owned)"
else skip "files not owned by user" "no lab user off-VM"; fi

note ""
note "[9] the database has been deleted by accident"
reset_lab "$REF/server.py" "$REF/solution.py"
rm -f "$LAB_DIR/data/transit.db"
score="$(grade full)"
check "no crash, a score comes back" yes "$([ -n "$score" ] && echo yes || echo no)"
note "      (score without a database: ${score})"
check "stray server.py processes" 0 "$(stray_servers)"

note ""
note "[10] grading does not touch the learner project"
# The strongest form of the ownership assertion, and the one that does not need
# root. "find -user root" cannot see this class of bug at all when provisioning
# pre-creates the file and root writes land in place, so assert the invariant
# itself: the project is a set of files with contents and metadata, and grading
# must not add to it, change it, or resurrect anything from it.
reset_lab "$REF/server.py" "$REF/solution.py"
# The learner writes a file of their own and runs their code once, exactly as they
# would before submitting.
printf 'notes to self\n' > "$LAB_DIR/NOTES.txt"
( cd "$LAB_DIR" && "$PY" -c 'import solution' ) >/dev/null 2>&1
if [ "$MODE" = "VM" ]; then chown -R user:user "$LAB_DIR"; fi

project_fingerprint() {
    # Every path, its size, its mode and a digest of its contents. Sorted, so the
    # comparison is order-independent.
    ( cd "$LAB_DIR" 2>/dev/null || return 0
      find . -type f 2>/dev/null | LC_ALL=C sort | while read -r f; do
          printf '%s %s %s\n' "$f" \
              "$(wc -c <"$f" 2>/dev/null | tr -d ' ')" \
              "$(ls -l "$f" 2>/dev/null | awk '{print $1}')"
      done
      find . -type f 2>/dev/null | LC_ALL=C sort | xargs cat 2>/dev/null | \
          { command -v shasum >/dev/null 2>&1 && shasum || sha1sum; } 2>/dev/null )
}

before="$(project_fingerprint)"
pyc_before="$(find "$LAB_DIR" -name '*.pyc' 2>/dev/null | wc -l | tr -d ' ')"
note "      (the learner own run left ${pyc_before} bytecode files, which are theirs)"
score1="$(grade full)"
after1="$(project_fingerprint)"
score2="$(grade full)"
after2="$(project_fingerprint)"
check "score, first grading" 50 "$score1"
check "score, second grading" 50 "$score2"
check "project unchanged by grading" yes \
    "$([ "$before" = "$after1" ] && echo yes || echo no)"
check "project unchanged by regrading" yes \
    "$([ "$after1" = "$after2" ] && echo yes || echo no)"
if [ "$before" != "$after1" ]; then
    note "      what grading changed:"
    diff <(printf '%s\n' "$before") <(printf '%s\n' "$after1") | sed 's/^/        /'
fi
# Nothing grading writes may be resurrected: delete the learner own file and
# confirm a grading run does not put it back (which would mean the checks are
# bootstrapping state into the project).
rm -f "$LAB_DIR/NOTES.txt"
grade full >/dev/null
check "deleted file not recreated by grading" yes \
    "$([ -e "$LAB_DIR/NOTES.txt" ] && echo no || echo yes)"
# The learner own run above left its own bytecode caches, which is normal and
# theirs. What must be zero is the number grading ADDED - this is the count that
# used to be non-zero, and root-owned, before the checks ran against a copy.
pyc_after="$(find "$LAB_DIR" -name '*.pyc' 2>/dev/null | wc -l | tr -d ' ')"
check "bytecode files added by grading" "$pyc_before" "$pyc_after"
if [ "$MODE" = "VM" ]; then
    check "files not owned by user" 0 "$(root_owned)"
    check "learner can still work" yes "$(learner_can_work)"
else
    skip "files not owned by user" "no lab user off-VM; the invariant above is what can be proven here"
fi

note ""
note "[11] portal scoring is a prefix, not a per-theme sum"
# main.sh breaks at the first failing case, so a solution that fails an early
# check never runs the later ones. A defect in check 1 scores 0, not 40.
reset_lab "$REF/_defect1_server.py" "$REF/solution.py"
check "defect in check 1, all five run" 40 "$(grade full)"
check "defect in check 1, portal order" 0 "$(grade portal)"
reset_lab "$REF/server.py" "$REF/_defect5_solution.py"
check "defect in check 5, portal order" 40 "$(grade portal)"

note ""
note "----------------------------------------------------------------"
note "permutation matrix: ${PASS} ok, ${FAILED} failed, ${SKIPPED} skipped  (mode ${MODE})"
note "----------------------------------------------------------------"
[ "$FAILED" -eq 0 ] || exit 1
