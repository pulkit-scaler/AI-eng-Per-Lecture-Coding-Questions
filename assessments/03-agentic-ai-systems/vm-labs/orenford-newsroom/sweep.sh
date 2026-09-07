#!/bin/bash
# LOCAL authoring harness: grade every candidate on its own pair of ports.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

PY="${PY:-python3}"
CANDS="${CANDS:-}"
if [ -z "$CANDS" ]; then
    CANDS="reference-solution/serve.py"
    for f in reference-solution/alt*.py reference-solution/_defect*.py \
             reference-solution/_cheat*.py; do
        [ -f "$f" ] && CANDS="$CANDS $f"
    done
fi

RESULTS="/tmp/orenford_sweep_results.txt"
: > "$RESULTS"
WIRE=8700
SERVE=8800

free_port() {
    local port="$1"
    while curl -sf -m 1 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; do
        port=$((port + 1))
    done
    echo "$port"
}

for c in $CANDS; do
    name="$(basename "$c" .py)"
    WIRE="$(free_port $((WIRE + 1)))"
    SERVE="$(free_port $((SERVE + 1)))"
    echo "################ $name  (wire $WIRE, service $SERVE)"
    out="$(PY="$PY" SOLUTION="$DIR/$c" \
           LAB_DIR="/tmp/orenford-lab-${name}" \
           WIRE_URL="http://127.0.0.1:${WIRE}" \
           SERVE_PORT="$SERVE" SERVE_URL="http://127.0.0.1:${SERVE}" \
           bash test-cases/scripts/run-all.sh 2>&1)"
    score="$(printf '%s' "$out" | grep -o 'SCORE: [0-9]*/[0-9]*' | head -1)"
    failed="$(printf '%s' "$out" | grep -o '^failed:.*' | head -1)"
    slow="$(printf '%s' "$out" | grep -o 'slowest test case: [0-9]*s' | head -1)"
    printf '%-30s %-14s %-26s %s\n' "$name" "${score:-SCORE: ?}" "${slow:-}" \
        "${failed:-}" >> "$RESULTS"
    printf '%s\n' "$out" | grep -E '^\s+\[(PASS|FAIL)\]' | sed 's/^/    /'
    printf '%s  %s  %s\n' "${score:-?}" "${slow:-}" "${failed:-}"
    pkill -f "orenford-lab-${name}" >/dev/null 2>&1
    rm -rf "/tmp/orenford-lab-${name}"
done

echo
echo "================ sweep summary ================"
cat "$RESULTS"
