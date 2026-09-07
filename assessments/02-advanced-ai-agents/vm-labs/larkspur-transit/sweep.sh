#!/bin/bash
# Grade every candidate in reference-solution/ plus the shipped starter stubs, each
# on its own port and its own lab directory so no run can be answered by a service
# another run started. Prints one row per candidate.
#
#   PY=<venv>/bin/python ./sweep.sh
#
# A candidate is a PREFIX: prefix_server.py and prefix_solution.py. Where one half
# is missing the reference half is used, so a server-only defect is graded against
# the reference client and vice versa.
#
# Expected: the reference and every alt*  at 50/50; the starter stubs and
# _cheat_bypass at 0/50; _cheat_hardcode at 10/50 (its protocol advertisement is
# genuinely correct, which is all TC01 claims); each _defect* losing exactly the
# theme it breaks.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PY="${PY:-python3}"
PORT_BASE="${PORT_BASE:-9500}"

REF_SERVER="$DIR/reference-solution/server.py"
REF_SOLUTION="$DIR/reference-solution/solution.py"

PREFIXES=( "__stub__" "__reference__" )
while IFS= read -r p; do
    case " ${PREFIXES[*]} " in *" $p "*) ;; *) PREFIXES+=( "$p" ) ;; esac
done < <(
    cd "$DIR/reference-solution" 2>/dev/null &&
    ls -1 alt*_server.py alt*_solution.py _defect*_server.py _defect*_solution.py \
          _cheat*_server.py _cheat*_solution.py 2>/dev/null |
    sed -e 's/_server\.py$//' -e 's/_solution\.py$//' | sort -u)

# PORTAL is what the learner actually receives: main.sh breaks at the first failing
# check, so their score is the leading run of passes rather than the per-theme sum.
printf '%-26s %-8s %-8s %-7s %s\n' "CANDIDATE" "SCORE" "PORTAL" "WORST" "FAILED"
printf '%.0s-' {1..104}; echo

i=0
for prefix in "${PREFIXES[@]}"; do
    i=$((i + 1))
    port=$((PORT_BASE + i))
    case "$prefix" in
        __stub__)
            server="$DIR/app/server_stub.py"; solution="$DIR/app/solution_stub.py" ;;
        __reference__)
            server="$REF_SERVER"; solution="$REF_SOLUTION" ;;
        *)
            server="$DIR/reference-solution/${prefix}_server.py"
            solution="$DIR/reference-solution/${prefix}_solution.py"
            [ -f "$server" ]   || server="$REF_SERVER"
            [ -f "$solution" ] || solution="$REF_SOLUTION" ;;
    esac
    out="$(cd "$DIR" && PY="$PY" LAB_DIR="/tmp/lk-sweep-${i}" \
        SVC_URL="http://127.0.0.1:${port}" SERVER="$server" SOLUTION="$solution" \
        ./test-cases/scripts/run-all.sh 2>&1)"
    if printf '%s' "$out" | grep -q 'WRONG-FILE-GRADED'; then
        printf '%-26s %-8s %s\n' "$prefix" "GUARD" "graded the wrong file - run aborted"
        continue
    fi
    score="$(printf '%s' "$out" | grep -o 'SCORE: [0-9]*/[0-9]*' | head -1 | cut -d' ' -f2)"
    portal="$(printf '%s' "$out" | grep -o 'PORTAL: [0-9]*/[0-9]*' | head -1 | cut -d' ' -f2)"
    failed="$(printf '%s' "$out" | grep '^failed:' | head -1 | cut -d: -f2-)"
    worst="$(printf '%s' "$out" | sed -n 's/.*slowest test case: \([0-9]*\)s.*/\1/p' | head -1)"
    leaked="$(printf '%s' "$out" | sed -n 's/.*stray server.py processes after the run: \([0-9]*\).*/\1/p' | head -1)"
    printf '%-26s %-8s %-8s %-7s %s\n' "$prefix" "${score:-ERROR}" "${portal:-?}" "${worst:-?}s" \
        "${failed}${leaked:+  [strays=$leaked]}"
    rm -rf "/tmp/lk-sweep-${i}" "/tmp/lk-sweep-${i}-logs"
done
