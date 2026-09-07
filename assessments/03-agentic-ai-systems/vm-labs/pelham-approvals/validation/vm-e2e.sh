#!/bin/bash
# The sequence a learner actually performs, with the SHIPPED defaults and
# nothing overridden: a cold root filesystem is provisioned from Setup.zip, the
# untouched starter is submitted straight away, the solution is then written as
# the learner, and it is submitted again.
#
# This row exists because every other harness here is blind to the two failures
# that matter most on the portal, and blind for the same reason both times - the
# local setup was easier to satisfy than production:
#
#   * run-all.sh, sweep.sh and permutations.sh all export LAB_DIR, SVC_URL,
#     DESK_URL and DESK_BIN, so the values the VM actually uses were never
#     exercised once. This pack is the proof that the gap is not theoretical:
#     LAB_DIR defaulted to /home/user/pelham-rubric, a project belonging to
#     another lab entirely, while setup builds /home/user/pelham-approvals. Every
#     local harness was green throughout, because every local harness overrode
#     the very value that was wrong.
#   * a check that prints its verdict and then one more line - which is what the
#     platform helper's ERR trap does on every refusal path - looks fine to a
#     harness that greps for a verdict anywhere in the output, while the portal
#     throws the whole submission away and renders an empty panel.
#
# So this harness installs the REPLICA helper at the platform's own path and
# grades the LAST line, exactly as main.sh does.
#
#   ./validation/vm-e2e.sh            # spawn a cold Ubuntu container and run it there
#   ./validation/vm-e2e.sh --here     # run it in THIS filesystem (root; on the VM)
#
# --here provisions the real lab into /home/user and /opt: run it on the VM or
# in a container, never on your own machine.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACK="$(cd "$DIR/.." && pwd)"
IMAGE="${IMAGE:-ubuntu:25.04}"

if [ "${1:-}" != "--here" ]; then
    command -v docker >/dev/null 2>&1 || {
        echo "docker is not available; run this on the VM with --here instead"
        exit 1
    }
    [ -s "$PACK/dist/Setup.zip" ] && [ -s "$PACK/dist/TestCase.zip" ] || {
        echo "dist/ is missing a zip - run ./build.sh first"
        exit 1
    }
    echo "=== running the sequence in a cold $IMAGE ==="
    exec docker run --rm -v "$PACK:/pack:ro" "$IMAGE" \
        bash /pack/validation/vm-e2e.sh --here
fi

[ "$(id -u)" -eq 0 ] || { echo "--here has to run as root"; exit 1; }

PROJ="/home/user/pelham-approvals"
DESK_PORT=8766
SVC_PORT=8767
DEPS_READY="/var/log/pelham-lab/deps.ready"
# The setup script installs langgraph and langchain-core in a detached job, so
# provisioning returns long before the wheels have landed. The checks wait on
# the readiness file themselves, but a check that gives up on the wait reports a
# broken environment as a failure - so the wait is done here, once, and reported
# as an environment fact rather than folded into a score. A cold container has
# to fetch python3-pip from apt and two wheels from PyPI, so this is minutes,
# not seconds.
DEPS_BUDGET="${DEPS_BUDGET:-600}"

BAD=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { BAD=$((BAD + 1)); printf '  FAIL %s\n' "$*"; }

listening() {  # listening <port>
    python3 - "$1" <<'PROBE' >/dev/null 2>&1
import sys, urllib.request
urllib.request.urlopen("http://127.0.0.1:%s/health" % sys.argv[1], timeout=3).read()
PROBE
}

echo "=== [1/7] a cold image: python3 only, no curl, no jq, no pip ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends unzip python3 >/dev/null 2>&1
printf '  %s   curl=%s   jq=%s   pip=%s\n' "$(python3 -V 2>&1)" \
    "$(command -v curl || echo none)" "$(command -v jq || echo none)" \
    "$(python3 -m pip --version 2>/dev/null | cut -d' ' -f2 || echo none)"

mkdir -p /judge/setup /judge/test
unzip -qo "$PACK/dist/Setup.zip"    -d /judge/setup
unzip -qo "$PACK/dist/TestCase.zip" -d /judge/test
# The platform provides this, and the shipped checks must find it here. The
# FAITHFUL replica goes in, not a convenience stub: the real helper emits JSON
# and installs an ERR trap that exits the check, and a stub without those two
# behaviours is easier to pass than production, which makes this whole harness
# worthless.
mkdir -p /usr/local/bin/judge/test
cp "$PACK/test-cases/scripts/common.sh" /usr/local/bin/judge/test/common.sh
grep -q 'trap .handle_script_error' /usr/local/bin/judge/test/common.sh \
    || { echo "the helper in test-cases/scripts/ is not the replica - refusing to run"; exit 1; }

echo "=== [2/7] provisioning from Setup.zip, as root ==="
T0=$SECONDS
bash /judge/setup/scripts/setup_script.sh >/tmp/e2e-setup.log 2>&1
SETUP_RC=$?
SETUP_SECS=$((SECONDS - T0))
echo "  setup rc=${SETUP_RC}, foreground wall clock ${SETUP_SECS}s"
grep -E 'WARN|LAB NOT READY' /tmp/e2e-setup.log | sed 's/^/    /' | head -10
[ "$SETUP_RC" -eq 0 ] && pass "provisioning returned cleanly" \
                      || fail "provisioning exited ${SETUP_RC}"
grep -q 'LAB NOT READY' /tmp/e2e-setup.log \
    && fail "provisioning reported LAB NOT READY (see /tmp/e2e-setup.log)" \
    || pass "provisioning reported the lab ready"
command -v jq >/dev/null 2>&1 \
    && pass "jq is present before any check runs, so a verdict can be printed" \
    || fail "jq is absent after provisioning - no check can emit a verdict"
[ -s "${PROJ}/server.py" ] \
    && pass "the project the checks default to exists: ${PROJ}" \
    || fail "${PROJ} was not built by provisioning, and that is where the checks look"

echo "=== [3/7] the LangGraph install the setup script detached ==="
# Grading before the detached job has resolved is not a fair reading of the
# pack: langgraph is what the lab runs on, and a check that meets a VM without
# it reports an environment fault rather than a score.
DEPS_WAITED=0
while [ ! -f "$DEPS_READY" ] && [ "$DEPS_WAITED" -lt "$DEPS_BUDGET" ]; do
    sleep 5
    DEPS_WAITED=$((DEPS_WAITED + 5))
    [ $((DEPS_WAITED % 60)) -eq 0 ] && printf '  still installing at t+%ss\n' "$DEPS_WAITED"
done
if [ -f "$DEPS_READY" ]; then
    pass "the detached install published ${DEPS_READY} after ${DEPS_WAITED}s"
    printf '    state: %s\n' "$(cat /var/log/pelham-lab/deps.state 2>/dev/null || echo unknown)"
else
    fail "${DEPS_READY} never arrived within ${DEPS_BUDGET}s; the checks would each burn their DEPS_WAIT and report a broken VM"
    tail -8 /var/log/pelham-lab/deps.log 2>/dev/null | sed 's/^/       deps| /'
fi
if python3 -c 'import langgraph, langchain_core' 2>/dev/null; then
    pass "langgraph and langchain-core import for the interpreter the checks use"
else
    fail "langgraph does not import after provisioning; every check would refuse as an environment fault"
    tail -8 /var/log/pelham-lab/deps.log 2>/dev/null | sed 's/^/       deps| /'
fi

echo "=== [4/7] the finance desk the setup script installed ==="
if listening "$DESK_PORT"; then
    pass "the desk answers /health on 127.0.0.1:${DESK_PORT} straight out of provisioning"
else
    fail "the desk is not answering after provisioning"
    tail -5 /var/log/pelham-desk.log 2>/dev/null | sed 's/^/       desk| /'
fi

# grade [expected-substring] -> echoes the score. NOTHING is overridden here:
# the point of this harness is the defaults the VM actually uses. main.sh grades
# `tail -n 1` of stdout+stderr and reports the whole submission as having no
# test cases if that line is not a verdict, so that is reproduced too.
grade() {
    local want="${1:-}" good=0 offmsg=0 unparseable=0 s out line msg
    for s in /judge/test/scripts/*; do
        out="$(bash "$s" 2>&1)"
        line="$(printf '%s\n' "$out" | tail -n 1)"
        msg="$(printf '%s' "$line" | jq -r '.message // empty' 2>/dev/null)"
        case "$line" in
            *'"status"'*'"success"'*) good=$((good + 1)) ;;
            *'"status"'*'"failed"'*)  ;;
            *) unparseable=$((unparseable + 1))
               printf '    %-14s LAST LINE IS NOT A VERDICT: %s\n' \
                   "$(basename "$s")" "$line" >&2
               continue ;;
        esac
        printf '    %-14s %s\n' "$(basename "$s")" "${msg:-$line}" >&2
        if [ -n "$want" ] && ! printf '%s' "$msg" | grep -qF -- "$want"; then
            offmsg=$((offmsg + 1))
        fi
    done
    # grade runs in a subshell, so these counts come back through files.
    echo "$offmsg" > /tmp/e2e-offmsg
    echo "$unparseable" > /tmp/e2e-unparseable
    echo $((good * 10))
}

check_wording() {  # check_wording <substring>
    local off; off="$(cat /tmp/e2e-offmsg 2>/dev/null || echo 0)"
    [ "${off:-0}" -eq 0 ] \
        && pass "every message named: $1" \
        || fail "${off} check(s) gave their verdict without mentioning: $1"
}

# The failure that produced an empty panel on the portal: a verdict printed and
# then a further line, so the judge graded the wrong line and posted no results.
check_parseable() {
    local bad; bad="$(cat /tmp/e2e-unparseable 2>/dev/null || echo 0)"
    [ "${bad:-0}" -eq 0 ] \
        && pass "every check ended on a parseable verdict - the panel will have rows" \
        || fail "${bad} check(s) did not end on a verdict; the portal would show an empty panel"
}

echo "=== [5/7] submitting the untouched starter, immediately ==="
T1=$SECONDS
S="$(grade "untouched starter")"
echo "  whole submission took $((SECONDS - T1))s"
[ "$S" = "0" ] && pass "score ${S}/50 as expected" \
               || fail "score ${S}/50, expected 0/50"
check_wording "untouched starter"
check_parseable

echo "=== [6/7] the learner writes the solution, then submits again ==="
cp "$PACK/reference-solution/server.py" "${PROJ}/"
cp "$PACK/reference-solution/bdi"/*.py "${PROJ}/bdi/"
chown -R user:user "$PROJ"
su - user -c 'cd ~/pelham-approvals && python3 check_local.py' >/tmp/e2e-gate.log 2>&1 \
    && pass "the learner's own check_local.py runs green in their project" \
    || { fail "check_local.py failed for the learner (see /tmp/e2e-gate.log)"
         tail -8 /tmp/e2e-gate.log | sed 's/^/       gate| /'; }
T2=$SECONDS
S="$(grade)"
echo "  whole submission took $((SECONDS - T2))s"
[ "$S" = "50" ] && pass "score ${S}/50 with the shipped defaults" \
                || fail "score ${S}/50, expected 50/50"
check_parseable

echo "=== [7/7] the learner still owns their project, and their port ==="
ROOTED="$(find /home/user -user root 2>/dev/null | wc -l | tr -d ' ')"
if [ "${ROOTED:-0}" -eq 0 ]; then
    pass "nothing under /home/user is root-owned after two grading runs"
else
    fail "${ROOTED} root-owned paths under /home/user"
    find /home/user -user root 2>/dev/null | head -5 | sed 's/^/       /'
fi
# What grading can take away in this lab is not a file but a port: the checks
# start the learner's own service when it is not already up, and a root-owned
# process still holding ${SVC_PORT} afterwards is a lab the learner cannot get
# back into. So the port is asserted free first, and only then is the learner
# asked to start their service on it.
if listening "$SVC_PORT"; then
    fail "something is still listening on ${SVC_PORT} after grading; the learner cannot start their own service"
    ss -ltnp 2>/dev/null | grep ":${SVC_PORT}" | sed 's/^/       /'
else
    pass "port ${SVC_PORT} is free again after grading"
fi
su - user -c "cd ~/pelham-approvals && PYTHONPATH=\$HOME/pelham-approvals \
    PELHAM_SERVICE_PORT=${SVC_PORT} PELHAM_DESK_URL=http://127.0.0.1:${DESK_PORT} \
    PYTHONDONTWRITEBYTECODE=1 nohup python3 server.py \
    >/tmp/e2e-learner-svc.log 2>&1 & echo started" >/dev/null 2>&1
LEARNER_UP=1
for _i in $(seq 1 40); do
    if listening "$SVC_PORT"; then LEARNER_UP=0; break; fi
    sleep 1
done
if [ "$LEARNER_UP" -eq 0 ]; then
    pass "the learner can still start their own service on ${SVC_PORT} afterwards"
else
    fail "the learner service would not start after grading"
    tail -8 /tmp/e2e-learner-svc.log 2>/dev/null | sed 's/^/       svc| /'
fi
pkill -u user -f 'python3 server.py' >/dev/null 2>&1

echo
echo "================================================================"
echo "failures: ${BAD}   (setup ${SETUP_SECS}s foreground, deps +${DEPS_WAITED}s detached)"
echo "================================================================"
[ "$BAD" -eq 0 ]
