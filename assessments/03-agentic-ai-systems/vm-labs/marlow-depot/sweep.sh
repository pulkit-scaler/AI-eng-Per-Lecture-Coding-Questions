#!/bin/bash
# LOCAL authoring harness: grade every candidate in reference-solution/ and
# print one row per candidate. Sequential on purpose - all candidates share the
# published ports and the image tag, so two stacks cannot be up at once.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

CANDS="${CANDS:-}"
if [ -z "$CANDS" ]; then
    CANDS="reference-solution"
    for d in reference-solution/alt* reference-solution/_defect* reference-solution/_cheat*; do
        [ -d "$d" ] && CANDS="$CANDS $d"
    done
fi

RESULTS="/tmp/marlow_sweep_results.txt"
: > "$RESULTS"

for c in $CANDS; do
    name="$(basename "$c")"
    echo "################ $name"
    out="$(CAND="$c" bash test-cases/scripts/run-all.sh 2>&1)"
    score="$(printf '%s' "$out" | grep -o 'SCORE: [0-9]*/[0-9]*' | head -1)"
    failed="$(printf '%s' "$out" | grep -o '^failed:.*' | head -1)"
    slow="$(printf '%s' "$out" | grep -o 'slowest test case: [0-9]*s' | head -1)"
    printf '%-26s %-14s %-26s %s\n' "$name" "${score:-SCORE: ?}" "${slow:-}" "${failed:-}" >> "$RESULTS"
    printf '%s\n' "$out" | grep -E '^\s+\[(PASS|FAIL)\]' | sed 's/^/    /'
    printf '%s  %s  %s\n' "${score:-?}" "${slow:-}" "${failed:-}"
done

echo
echo "================ sweep summary ================"
cat "$RESULTS"
