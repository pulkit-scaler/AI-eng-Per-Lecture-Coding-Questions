#!/bin/bash
# The sequence a learner actually performs, with the SHIPPED defaults and
# nothing overridden: a cold root filesystem is provisioned from Setup.zip, the
# untouched starter is submitted straight away, the solution is then written as
# the learner, and it is submitted again.
#
# This row exists because the pack once shipped two defects that every other
# harness here was blind to, for the same reason: run-all.sh, sweep.sh and
# permutations.sh all export LAB_DIR, DESK_URL and DESK_BIN, so the values the
# VM actually uses were never once exercised. The desk was written to
# /opt/ashcombe-svc without the corpus module it imports, so it died on import
# and every check reported it unreachable; and the checks defaulted to another
# lab's project path. Both are invisible unless the defaults are used.
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

BAD=0
pass() { printf '  ok   %s\n' "$*"; }
fail() { BAD=$((BAD + 1)); printf '  FAIL %s\n' "$*"; }

echo "=== [1/6] a cold image: python3 only, no curl, no jq, no pip ==="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq --no-install-recommends unzip python3 >/dev/null 2>&1
printf '  %s   curl=%s   jq=%s\n' "$(python3 -V 2>&1)" \
    "$(command -v curl || echo none)" "$(command -v jq || echo none)"

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

echo "=== [2/6] provisioning from Setup.zip, as root ==="
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

echo "=== [3/6] the desk the setup script installed ==="
if python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8777/health', timeout=3).read()" 2>/dev/null; then
    pass "the desk answers /health on 127.0.0.1:8777 straight out of provisioning"
else
    fail "the desk is not answering after provisioning"
    tail -5 /var/log/ashcombe-desk.log 2>/dev/null | sed 's/^/       desk| /'
fi

# grade [expected-substring] -> echoes the score. NOTHING is overridden here:
# the point of this harness is the defaults the VM actually uses. A verdict that
# is right for the wrong reason is a failure too, so an optional substring is
# matched against every message.
grade() {
    local want="${1:-}" good=0 offmsg=0 unparseable=0 s out line msg
    for s in /judge/test/scripts/*; do
        # main.sh grades `tail -n 1` of stdout+stderr and reports the whole
        # submission as having no test cases if that line is not a verdict.
        # Reproduce that, or the empty-panel failure stays invisible here.
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
    echo "$unparseable" > /tmp/e2e-unparseable
    # grade runs in a subshell, so a verdict-worded-wrong count is handed back
    # through a file rather than through BAD.
    echo "$offmsg" > /tmp/e2e-offmsg
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

echo "=== [4/6] submitting the untouched starter, immediately ==="
T1=$SECONDS
S="$(grade "untouched starter")"
echo "  whole submission took $((SECONDS - T1))s"
[ "$S" = "0" ] && pass "score ${S}/50 as expected" \
               || fail "score ${S}/50, expected 0/50"
check_wording "untouched starter"
check_parseable

echo "=== [5/6] the learner writes the solution, then submits again ==="
cp "$PACK/reference-solution/intake"/*.py /home/user/ashcombe-intake/intake/
chown user:user /home/user/ashcombe-intake/intake/*.py
su - user -c 'cd ~/ashcombe-intake && python3 check_local.py' >/tmp/e2e-gate.log 2>&1 \
    && pass "the learner's own gate runs green in their project" \
    || fail "check_local.py failed for the learner (see /tmp/e2e-gate.log)"
T2=$SECONDS
S="$(grade)"
echo "  whole submission took $((SECONDS - T2))s"
[ "$S" = "50" ] && pass "score ${S}/50 with the shipped defaults" \
                || fail "score ${S}/50, expected 50/50"
check_parseable

echo "=== [6/6] the learner still owns their project ==="
ROOTED="$(find /home/user -user root 2>/dev/null | wc -l | tr -d ' ')"
if [ "${ROOTED:-0}" -eq 0 ]; then
    pass "nothing under /home/user is root-owned after two grading runs"
else
    fail "${ROOTED} root-owned paths under /home/user"
    find /home/user -user root 2>/dev/null | head -5 | sed 's/^/       /'
fi
su - user -c 'cd ~/ashcombe-intake && python3 -m intake.worker --once >/dev/null' \
    && pass "the learner can still drain their own spool afterwards" \
    || fail "the learner cannot drain their own spool after grading"

echo
echo "================================================================"
echo "failures: ${BAD}   (setup ${SETUP_SECS}s foreground)"
echo "================================================================"
[ "$BAD" -eq 0 ]
