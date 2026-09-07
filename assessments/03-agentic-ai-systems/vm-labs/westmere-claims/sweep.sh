#!/bin/bash
# LOCAL authoring harness: grade every candidate on its own port and lab dir so
# the rows cannot contaminate each other.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

PY="${PY:-python3}"
CANDS="${CANDS:-}"
if [ -z "$CANDS" ]; then
    CANDS="reference-solution/claimctl.py"
    for f in reference-solution/alt*.py reference-solution/_defect*.py \
             reference-solution/_cheat*.py; do
        [ -f "$f" ] && CANDS="$CANDS $f"
    done
fi

RESULTS="/tmp/westmere_sweep_results.txt"
: > "$RESULTS"
PORT=8600

# A desk from an earlier sweep can still be dying on a port, and grading a
# candidate against a desk on its way out reads as a broken candidate. Step past
# anything that answers.
free_port() {
    local port="$1"
    while curl -sf -m 1 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; do
        port=$((port + 1))
    done
    echo "$port"
}

for c in $CANDS; do
    name="$(basename "$c" .py)"
    PORT="$(free_port $((PORT + 1)))"
    echo "################ $name  (port $PORT)"
    out="$(PY="$PY" SOLUTION="$DIR/$c" \
           LAB_DIR="/tmp/westmere-lab-${name}" \
           DESK_URL="http://127.0.0.1:${PORT}" \
           bash test-cases/scripts/run-all.sh 2>&1)"
    score="$(printf '%s' "$out" | grep -o 'SCORE: [0-9]*/[0-9]*' | head -1)"
    failed="$(printf '%s' "$out" | grep -o '^failed:.*' | head -1)"
    slow="$(printf '%s' "$out" | grep -o 'slowest test case: [0-9]*s' | head -1)"
    printf '%-28s %-14s %-26s %s\n' "$name" "${score:-SCORE: ?}" "${slow:-}" \
        "${failed:-}" >> "$RESULTS"
    printf '%s\n' "$out" | grep -E '^\s+\[(PASS|FAIL)\]' | sed 's/^/    /'
    printf '%s  %s  %s\n' "${score:-?}" "${slow:-}" "${failed:-}"
    rm -rf "/tmp/westmere-lab-${name}"
done

echo
echo "================ sweep summary ================"
cat "$RESULTS"
