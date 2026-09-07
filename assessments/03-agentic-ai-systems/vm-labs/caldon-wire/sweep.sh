#!/bin/bash
# Grade every candidate in reference-solution/ and check each against what it
# is supposed to score. Each candidate gets its own port and lab directory, so
# a run cannot see another one.
#
#   ./sweep.sh                 # every candidate
#   ./sweep.sh alt1 defect3    # only candidates whose name matches
#
# PY must point at an interpreter that has the openai package.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${PY:-python3}"
BASE_PORT="${BASE_PORT:-8850}"

# candidate:expected-score:checks-it-must-lose (empty = none)
EXPECT="
solution.py:50:
alt1_create_task.py:50:
alt2_taskgroup.py:50:
_defect1_sequential_batch.py:40:01
_defect2_no_semaphore.py:40:02
_defect3_bare_gather.py:40:03
_defect4_no_deadline.py:40:04
_defect5_buffered_stream.py:40:05
_cheat_sleep_deadline.py:40:04
_cheat_hardcode.py:0:01 02 03 04 05
_cheat_allsync.py:0:01 02 03 04 05
_cheat_threads.py:0:01 02 03 04 05
_cheat_leaked_task.py:40:04
_probe_loop_per_thread.py:50:
_envprobe_numpy.py:0:01 02 03 04 05
"

FILTER="$*"
INDEX=0
BAD=0
printf '%-32s %6s %6s  %s\n' "CANDIDATE" "SCORE" "WANT" "VERDICT"
printf '%.0s-' $(seq 1 78); echo

while IFS= read -r row; do
    [ -n "$row" ] || continue
    name="${row%%:*}"; rest="${row#*:}"
    want="${rest%%:*}"; lose="${rest#*:}"
    if [ -n "$FILTER" ]; then
        match=0
        for token in $FILTER; do
            case "$name" in *"$token"*) match=1 ;; esac
        done
        [ "$match" -eq 1 ] || continue
    fi
    [ -f "$DIR/reference-solution/$name" ] || {
        printf '%-32s %6s %6s  MISSING FILE\n' "$name" "-" "$want"; BAD=$((BAD+1)); continue; }

    INDEX=$((INDEX + 1))
    port=$((BASE_PORT + INDEX))
    lab="/tmp/caldon-sweep-${INDEX}"
    out="$(LAB_DIR="$lab" SVC_URL="http://127.0.0.1:${port}" \
           SOLUTION="$DIR/reference-solution/$name" PY="$PY" \
           LOG_DIR="/tmp/caldon-sweep-${INDEX}-logs" \
           bash "$DIR/test-cases/scripts/run-all.sh" 2>&1)"
    score="$(printf '%s' "$out" | grep -o 'SCORE: [0-9]*' | head -1 | tr -cd '0-9')"
    failed="$(printf '%s' "$out" | grep -o '\[FAIL\] script_[0-9]*' \
              | sed 's/.*script_//' | tr '\n' ' ' | sed 's/ $//')"
    verdict="ok"
    if [ "${score:-x}" != "$want" ]; then
        verdict="WRONG SCORE"
        BAD=$((BAD + 1))
    elif [ "$(printf '%s' "$failed" | tr -s ' ')" != "$(printf '%s' "$lose" | tr -s ' ')" ]; then
        verdict="WRONG CHECKS lost=[${failed}] want=[${lose}]"
        BAD=$((BAD + 1))
    elif [ -n "$lose" ]; then
        verdict="ok (lost ${failed} only)"
    fi
    printf '%-32s %6s %6s  %s\n' "$name" "${score:-?}" "$want" "$verdict"
    [ "$verdict" = "ok" ] || [ "${verdict#ok }" != "$verdict" ] || \
        printf '%s\n' "$out" | grep -E '^\s+\[FAIL\]' | sed 's/^/      /'
    rm -rf "$lab" "/tmp/caldon-sweep-${INDEX}-logs"
done <<< "$EXPECT"

printf '%.0s-' $(seq 1 78); echo
if [ "$BAD" -eq 0 ]; then
    echo "sweep clean: every candidate scored exactly what it should"
else
    echo "sweep FAILED: ${BAD} candidate(s) did not behave as expected"
fi
exit "$BAD"
