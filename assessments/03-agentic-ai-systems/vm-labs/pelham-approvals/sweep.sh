#!/bin/bash
# LOCAL authoring harness: grade every candidate on its own ports and lab dir.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

PY="${PY:-python3}"
CANDS="${CANDS:-}"
if [ -z "$CANDS" ]; then
    CANDS="reference-solution"
    for d in reference-solution/alt* reference-solution/_defect* \
             reference-solution/_cheat*; do
        [ -d "$d" ] && CANDS="$CANDS $d"
    done
fi

RESULTS="/tmp/pelham_sweep_results.txt"
: > "$RESULTS"
PORT=8800

free_port() {
    local port="$1"
    while curl -sf -m 1 "http://127.0.0.1:${port}/health" >/dev/null 2>&1; do
        port=$((port + 1))
    done
    echo "$port"
}

for c in $CANDS; do
    name="$(basename "$c")"
    PORT="$(free_port $((PORT + 2)))"
    SVCPORT="$(free_port $((PORT + 1)))"
    echo "################ $name  (desk $PORT, service $SVCPORT)"
    out="$(PY="$PY" SOLUTION="$DIR/$c" \
           LAB_DIR="/tmp/pelham-lab-${name}" \
           DESK_URL="http://127.0.0.1:${PORT}" \
           SVC_URL="http://127.0.0.1:${SVCPORT}" \
           bash test-cases/scripts/run-all.sh 2>&1)"
    score="$(printf '%s' "$out" | grep -o 'SCORE: [0-9]*/[0-9]*' | head -1)"
    failed="$(printf '%s' "$out" | grep -o '^failed:.*' | head -1)"
    slow="$(printf '%s' "$out" | grep -o 'slowest test case: [0-9]*s' | head -1)"
    printf '%-32s %-14s %-26s %s\n' "$name" "${score:-SCORE: ?}" "${slow:-}" \
        "${failed:-}" >> "$RESULTS"
    printf '%s\n' "$out" | grep -E '^\s+\[(PASS|FAIL)\]' | sed 's/^/    /'
    pkill -f "server.py" >/dev/null 2>&1
    rm -rf "/tmp/pelham-lab-${name}"
    sleep 1
done

echo
echo "================ sweep summary ================"
cat "$RESULTS"
