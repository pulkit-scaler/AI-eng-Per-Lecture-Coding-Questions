#!/bin/bash
# Grade every candidate in reference-solution/ plus the shipped starter stub, each
# on its own port and its own lab directory, so no run can be answered by an
# endpoint another run started. Prints one row per candidate.
#
#   PY=<venv>/bin/python ./sweep.sh
#
# Expected: solution.py and every alt*.py at 50/50; the stub, _cheat_hardcode and
# _cheat_no_endpoint at 0/50; each _defect*.py and the two scoped shortcut probes
# failing only the theme they break. The _envprobe_* files are deliberately outside
# the glob - they are environment regression tests, not candidates.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${PY:-python3}"
PORT_BASE="${PORT_BASE:-9300}"

CANDIDATES=( "app/solution_stub.py" "reference-solution/solution.py" )
while IFS= read -r f; do CANDIDATES+=( "$f" ); done < <(
    cd "$DIR" && ls -1 reference-solution/alt*.py reference-solution/_defect*.py \
                       reference-solution/_cheat*.py 2>/dev/null | sort)

# SCORE is the per-theme total this harness computes by running all five checks.
# PORTAL is what the learner actually receives: main.sh breaks at the first failing
# case, so their score is the leading run of passes. A probe that fails only check
# 5 scores 40/50 on the portal; one that fails only check 1 scores 0/50, not 40/50.
printf '%-40s %-8s %-8s %-7s %s\n' "CANDIDATE" "SCORE" "PORTAL" "WORST" "FAILED"
printf '%.0s-' {1..115}; echo

i=0
for cand in "${CANDIDATES[@]}"; do
    i=$((i + 1))
    port=$((PORT_BASE + i))
    name="$(basename "$cand")"
    out="$(cd "$DIR" && PY="$PY" LAB_DIR="/tmp/ash-sweep-${i}" \
        SVC_URL="http://127.0.0.1:${port}" SOLUTION="$DIR/$cand" \
        ./test-cases/scripts/run-all.sh 2>&1)"
    if printf '%s' "$out" | grep -q 'WRONG-FILE-GRADED'; then
        printf '%-40s %-8s %s\n' "$name" "GUARD" "graded the wrong file - run aborted"
        continue
    fi
    score="$(printf '%s' "$out" | grep -o 'SCORE: [0-9]*/[0-9]*' | head -1 | cut -d' ' -f2)"
    portal="$(printf '%s' "$out" | grep -o 'PORTAL: [0-9]*/[0-9]*' | head -1 | cut -d' ' -f2)"
    failed="$(printf '%s' "$out" | grep '^failed:' | head -1 | cut -d: -f2-)"
    worst="$(printf '%s' "$out" | sed -n 's/.*slowest test case: \([0-9]*\)s.*/\1/p' | head -1)"
    # A broken verdict stream is not a score, it is a voided run. Surface it in the
    # row rather than letting it read as an ordinary failure.
    if printf '%s' "$out" | grep -q 'VERDICT-STREAM INVARIANT BROKEN'; then
        failed="VOIDED VERDICT -${failed}"
    fi
    printf '%-40s %-8s %-8s %-7s %s\n' "$name" "${score:-ERROR}" "${portal:-?}" "${worst:-?}s" "${failed}"
    rm -rf "/tmp/ash-sweep-${i}" "/tmp/ash-sweep-${i}-logs"
done
