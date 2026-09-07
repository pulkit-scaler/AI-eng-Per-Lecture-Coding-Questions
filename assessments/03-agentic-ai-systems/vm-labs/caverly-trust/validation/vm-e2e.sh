#!/bin/bash
# The sequence a learner actually performs, with the SHIPPED defaults and
# nothing overridden: a cold root filesystem is provisioned from Setup.zip, the
# untouched starter is submitted straight away, the solution is then written as
# the learner, and it is submitted again.
#
# This row exists because every other harness in this pack is blind to a whole
# class of failure, and blind for two reasons that come down to the same thing -
# the local setup was easier to satisfy than production:
#
#   * run-all.sh, sweep.sh and permutations.sh all export LAB_DIR, DESK_URL and
#     DESK_BIN, so the values the VM actually uses were never exercised once;
#   * a convenience common.sh with no ERR trap lets a check print its verdict
#     and then an INTERNAL_ERROR line - which is what the real helper causes on
#     every refusal path - and that looks perfectly fine locally while the
#     portal throws the whole submission away and renders an empty panel.
#
# So this harness installs the REPLICA helper at the platform's own path and
# grades the LAST line, exactly as main.sh does.
#
# It is also the only place the scorecard-ownership defect is visible. A check
# runs the learner gate as root, the gate WRITES its scorecard, and if that
# write lands inside /home/user the learner can never replace the file again.
# The ordering matrix reproduces the shape of that under /tmp; only a real
# provisioned filesystem with a real `user` account proves it.
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
# This lab installs no pip packages at all, so unzip and python3 are genuinely
# everything the image gets. curl and jq are the checks' own dependencies and
# provisioning has to supply them; leaving them out here is what proves it does.
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
# A check cannot even print a verdict without jq: print_status in the platform
# helper is a `jq -n` call, so an absent jq turns every row into silence.
command -v jq >/dev/null 2>&1 \
    && pass "jq is present before any check runs, so a verdict can be printed" \
    || fail "jq is absent after provisioning - no check can emit a verdict"

echo "=== [3/6] the desk the setup script installed ==="
if python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8744/health', timeout=3).read()" 2>/dev/null; then
    pass "the desk answers /health on 127.0.0.1:8744 straight out of provisioning"
else
    fail "the desk is not answering after provisioning"
    tail -5 /var/log/caverly-desk.log 2>/dev/null | sed 's/^/       desk| /'
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

echo "=== [4/6] submitting the untouched starter, immediately ==="
T1=$SECONDS
S="$(grade "untouched starter")"
echo "  whole submission took $((SECONDS - T1))s"
[ "$S" = "0" ] && pass "score ${S}/50 as expected" \
               || fail "score ${S}/50, expected 0/50"
check_wording "untouched starter"
check_parseable

echo "=== [5/6] the learner writes the solution, then submits again ==="
cp "$PACK/reference-solution/harden.py" /home/user/caverly-trust/
cp "$PACK/reference-solution/guards"/*.py /home/user/caverly-trust/guards/
chown -R user:user /home/user/caverly-trust
su - user -c 'cd ~/caverly-trust && python3 check_local.py' >/tmp/e2e-gate.log 2>&1 \
    && pass "the learner's own gate runs green in their project" \
    || fail "check_local.py failed for the learner (see /tmp/e2e-gate.log)"
# A sentinel goes into the learner's own scorecard before grading, because
# ownership alone cannot see the defect this pack shipped. Every check chowns the
# whole project back to `user` from its EXIT trap, and provisioning pre-creates
# reports/scorecard.json as the learner with mode 664, so a graded run that
# writes there as root overwrites the file in place and leaves the ownership
# looking perfectly correct. What is left of the defect, and what no repair can
# hide, is that the learner's file was touched at all: the fingerprint recorded
# here has to come back unchanged in step 6.
su - user -c 'printf "%s\n" "{\"sentinel\": \"vm-e2e: grading must not write here\"}" > ~/caverly-trust/reports/scorecard.json'
fingerprint() {
    local f=/home/user/caverly-trust/reports/scorecard.json
    [ -e "$f" ] || { echo "absent"; return 0; }
    printf '%s %s\n' "$(stat -c '%i %U %s' "$f" 2>/dev/null)" \
        "$(md5sum "$f" 2>/dev/null | cut -d' ' -f1)"
}
SENTINEL_BEFORE="$(fingerprint)"
T2=$SECONDS
S="$(grade)"
echo "  whole submission took $((SECONDS - T2))s"
[ "$S" = "50" ] && pass "score ${S}/50 with the shipped defaults" \
                || fail "score ${S}/50, expected 50/50"
check_parseable

echo "=== [6/6] the learner still owns their project, and grading stayed out of it ==="
ROOTED="$(find /home/user -user root 2>/dev/null | wc -l | tr -d ' ')"
if [ "${ROOTED:-0}" -eq 0 ]; then
    pass "nothing under /home/user is root-owned after two grading runs"
else
    fail "${ROOTED} root-owned paths under /home/user"
    find /home/user -user root 2>/dev/null | head -5 | sed 's/^/       /'
fi
# reports/ gets its own assertion rather than relying on the sweep above,
# because this is the exact path the pack got wrong: a check ran harden.py as
# root with a relative --out, so reports/scorecard.json came back root-owned and
# the learner's own run could never rewrite it. The graded run now writes into
# the check's private work directory instead, and the file below must still
# belong to the learner after two full submissions.
REPORTS_ROOTED="$(find /home/user/caverly-trust/reports -user root 2>/dev/null | wc -l | tr -d ' ')"
if [ ! -d /home/user/caverly-trust/reports ]; then
    fail "the learner's reports/ directory is gone after grading"
elif [ "${REPORTS_ROOTED:-0}" -eq 0 ]; then
    pass "the learner's reports/ and everything in it still belongs to user"
else
    fail "${REPORTS_ROOTED} root-owned path(s) in the learner's reports/ - a graded run wrote its scorecard into the learner project, so their own harden.py can never replace it"
    find /home/user/caverly-trust/reports -user root 2>/dev/null \
        | head -5 | xargs -r ls -l 2>/dev/null | sed 's/^/       /'
fi
# The trap-proof half of the same assertion, and the one that actually fails
# when a check points --out at a relative path inside the project.
SENTINEL_AFTER="$(fingerprint)"
if [ "$SENTINEL_AFTER" = "$SENTINEL_BEFORE" ]; then
    pass "grading never touched the learner's own reports/scorecard.json"
else
    fail "a graded run wrote into the learner's own reports/scorecard.json: '${SENTINEL_BEFORE}' became '${SENTINEL_AFTER}'"
    fail "that run is root, so the learner is locked out of their own scorecard on any VM where the file is not already theirs; only the EXIT-trap chown is hiding it here"
fi
# And the case the pre-created file hides completely: a learner who deleted
# their scorecard before submitting. Grading has to score the same and must not
# put the file back, because a file root creates from scratch in there is
# root-owned and the learner's own program can never replace it again.
rm -f /home/user/caverly-trust/reports/scorecard.json
T3=$SECONDS
S="$(grade)"
echo "  regrade with the learner's scorecard deleted took $((SECONDS - T3))s"
[ "$S" = "50" ] && pass "score ${S}/50 with the learner's scorecard deleted" \
                || fail "score ${S}/50 with the learner's scorecard deleted, expected 50/50"
check_parseable
[ -e /home/user/caverly-trust/reports/scorecard.json ] \
    && fail "grading put the deleted scorecard back, so a check is writing inside the learner project: $(ls -l /home/user/caverly-trust/reports/scorecard.json) - root created that file and only the EXIT-trap chown makes it read as the learner's" \
    || pass "grading did not recreate the deleted scorecard, so it writes its own copy elsewhere"
su - user -c 'cd ~/caverly-trust && CAVERLY_DESK_URL=http://127.0.0.1:8744 python3 harden.py --attacks campaigns/sample.json --out reports/scorecard.json >/dev/null' \
    && pass "the learner can still run their own gate afterwards" \
    || fail "the learner cannot rewrite their own scorecard after grading"

echo
echo "================================================================"
echo "failures: ${BAD}   (setup ${SETUP_SECS}s foreground)"
echo "================================================================"
[ "$BAD" -eq 0 ]
