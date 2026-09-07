#!/bin/bash
# Grade every candidate in reference-solution/ plus the shipped starter, each on its
# own port and its own lab directory so no run can be answered by an endpoint another
# run started. Prints one row per candidate.
#
#   PY=<venv>/bin/python ./sweep.sh
#
# Expected: solution.py and every alt*.py at 50/50; the starter and _cheat_hardcode
# at 0/50; each _defect*.py failing only the theme it breaks.
#
# Two score columns, and the difference matters. SCORE is the per-theme sum, which
# says which themes a candidate implements. PORTAL is what the platform would award:
# its main.sh breaks at the first failing check, so credit is a PREFIX. A candidate
# that fails check 1 and passes 2 to 5 reads 40/50 under SCORE and 0/50 on a real
# submission.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${PY:-python3}"
PORT_BASE="${PORT_BASE:-9200}"

CANDIDATES=( "app/solution_stub.py" "reference-solution/solution.py" )
while IFS= read -r f; do CANDIDATES+=( "$f" ); done < <(
    cd "$DIR" && ls -1 reference-solution/alt*.py reference-solution/_defect*.py \
                       reference-solution/_cheat*.py 2>/dev/null | sort)

printf '%-30s %-8s %-8s %-6s %s\n' "CANDIDATE" "SCORE" "PORTAL" "WORST" "FAILED"
printf '%.0s-' {1..112}; echo

i=0
for cand in "${CANDIDATES[@]}"; do
    i=$((i + 1))
    port=$((PORT_BASE + i))
    name="$(basename "$cand")"
    out="$(cd "$DIR" && PY="$PY" LAB_DIR="/tmp/kb-sweep-${i}" \
        SVC_URL="http://127.0.0.1:${port}" SOLUTION="$DIR/$cand" \
        ./test-cases/scripts/run-all.sh 2>&1)"
    if grep -q 'WRONG-FILE-GRADED' <<<"$out"; then
        printf '%-30s %-8s %s\n' "$name" "GUARD" "graded the wrong file - run aborted"
        continue
    fi
    if grep -q 'UNPARSEABLE VERDICT' <<<"$out"; then
        printf '%-30s %-8s %s\n' "$name" "VOID" \
            "a check did not end in a verdict - the portal would show no test cases"
        continue
    fi
    score="$(sed -n 's/^SCORE: \([0-9]*\/[0-9]*\).*/\1/p' <<<"$out" | head -1)"
    portal="$(sed -n 's/^PORTAL: \([0-9]*\/[0-9]*\).*/\1/p' <<<"$out" | head -1)"
    failed="$(sed -n 's/^failed:\(.*\)/\1/p' <<<"$out" | head -1)"
    worst="$(sed -n 's/.*slowest test case: \([0-9]*\)s.*/\1/p' <<<"$out" | head -1)"
    printf '%-30s %-8s %-8s %-6s %s\n' "$name" "${score:-ERROR}" "${portal:-?}" \
        "${worst:-?}s" "${failed}"
    rm -rf "/tmp/kb-sweep-${i}" "/tmp/kb-sweep-${i}-logs"
done
