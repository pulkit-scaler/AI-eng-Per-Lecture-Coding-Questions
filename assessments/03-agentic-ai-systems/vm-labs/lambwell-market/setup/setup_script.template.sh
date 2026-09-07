#!/bin/bash
# Lambwell Market lab - VM provisioning script.
# Runs once, as root, before the learner starts.
# TEMPLATE: build.sh replaces every FILE marker below with that file's contents.
# No `set -e`: a failing step must be recorded and provisioning must continue,
# so a single hiccup cannot leave the learner with a half-built project or
# root-owned files.
set -uo pipefail

LOG_DIR="/var/log/lambwell-lab"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp/lambwell-lab"
mkdir -p "$LOG_DIR" 2>/dev/null || LOG_DIR="/tmp"
LOG="${LOG_DIR}/setup.log"
STATUS_FILE="${LOG_DIR}/setup-status"
: > "$STATUS_FILE" 2>/dev/null || true

exec > >(tee -a "$LOG") 2>&1

WARNINGS=0
stamp() { date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "-"; }
note()  { echo "[$(stamp)] $*"; }
ok()    { echo "[$(stamp)] OK   $*"; printf 'OK   %s\n'   "$*" >>"$STATUS_FILE" 2>/dev/null || true; }
warn()  { WARNINGS=$((WARNINGS + 1)); echo "[$(stamp)] WARN $*"; printf 'WARN %s\n' "$*" >>"$STATUS_FILE" 2>/dev/null || true; }
run()   { local label="$1"; shift; if "$@"; then ok "$label"; else warn "$label (exit $?)"; fi; return 0; }

# cap <seconds> <cmd...> : never let one command block provisioning
# indefinitely. Pure bash rather than coreutils timeout(1), because a silently
# absent timeout binary turns a bound into a no-op. The command is waited for in
# one-second steps: bash dispatches a trap only between commands, so blocking in
# the foreground would defer the deadline watchdog below.
cap() {
    local secs="$1"; shift
    "$@" &
    local pid=$! waited=0
    while kill -0 "$pid" 2>/dev/null; do
        sleep 1
        waited=$((waited + 1))
        if [ "$waited" -ge "$secs" ]; then
            kill -TERM "$pid" 2>/dev/null
            sleep 2
            kill -KILL "$pid" 2>/dev/null
            break
        fi
    done
    wait "$pid" 2>/dev/null
    return $?
}

detach() {
    local logfile="$1"; shift
    if command -v setsid >/dev/null 2>&1; then
        setsid nohup "$@" >"$logfile" 2>&1 </dev/null &
    else
        nohup "$@" >"$logfile" 2>&1 </dev/null &
    fi
    disown 2>/dev/null || true
    return 0
}

LAB_USER="user"
LAB_HOME="/home/${LAB_USER}"
PROJ="${LAB_HOME}/lambwell-market"
KIT="${PROJ}/market_kit"
PKG="${PROJ}/harvest"
SVC="/opt/lambwell-svc"
PORT=8711

svc_healthy() {
    python3 - "$PORT" <<'PROBE' >/dev/null 2>&1
import sys, urllib.request
urllib.request.urlopen("http://127.0.0.1:%s/health" % sys.argv[1], timeout=2).read()
PROBE
}

note "Lambwell Market setup starting; full log at ${LOG}"

SETUP_BUDGET="${SETUP_BUDGET:-95}"
DEADLINE_HIT=0
on_deadline() {
    DEADLINE_HIT=1
    warn "setup hit its internal ${SETUP_BUDGET}s deadline at t+${SECONDS}s and is finishing early so provisioning reports a result instead of being killed"
    if type finish_summary >/dev/null 2>&1; then finish_summary; fi
    exit 0
}
trap on_deadline USR1
( sleep "$SETUP_BUDGET"; kill -USR1 $$ 2>/dev/null ) >/dev/null 2>&1 &
WATCHDOG_PID=$!

echo "=== [1/8] Base packages ==="
export DEBIAN_FRONTEND=noninteractive
if ! id -u "$LAB_USER" >/dev/null 2>&1; then
    cap 20 useradd -m -s /bin/bash "$LAB_USER" || true
fi
# Only python3 is needed to hand over a usable lab: it runs the market site and
# the learner program. pip, curl and jq are consumers that come later, so they
# are installed by the detached job rather than on the path the portal is
# waiting on. The health probe below is python3 for the same reason.
if ! command -v python3 >/dev/null 2>&1; then
    note "installing python3 (the only package provisioning itself needs)"
    for u in apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service apt-daily.service; do
        cap 5 systemctl stop "$u" >/dev/null 2>&1 || true
        cap 5 systemctl disable "$u" >/dev/null 2>&1 || true
    done
    APT_OPTS="-o DPkg::Lock::Timeout=30"
    apt_ok=0
    for attempt in 1 2; do
        # shellcheck disable=SC2086
        if cap 60 apt-get install -y -qq $APT_OPTS python3; then apt_ok=1; break; fi
        # shellcheck disable=SC2086
        cap 45 apt-get update -qq $APT_OPTS || note "apt-get update attempt ${attempt} failed (t+${SECONDS}s)"
        # shellcheck disable=SC2086
        if cap 60 apt-get install -y -qq $APT_OPTS python3; then apt_ok=1; break; fi
        [ "$attempt" -eq 1 ] && sleep 5
    done
    [ "$apt_ok" -eq 1 ] || warn "could not install python3 (t+${SECONDS}s) - the lab will not work"
fi
command -v python3 >/dev/null 2>&1 && ok "have python3 ($(python3 -V 2>&1))" || warn "missing python3"
PYBIN="$(command -v python3 || echo /usr/bin/python3)"

if command -v python3 >/dev/null 2>&1 && ! command -v python >/dev/null 2>&1; then
    ln -sf "$(command -v python3)" /usr/local/bin/python 2>/dev/null \
        && ok "python -> python3" || warn "could not link python"
fi

# The image marks its interpreter externally managed, so a plain pip install
# refuses under PEP 668. Written before anything runs pip, the learner included.
if [ ! -f /etc/pip.conf ]; then
    printf '[global]\nbreak-system-packages = true\ndisable-pip-version-check = true\n' \
        > /etc/pip.conf 2>/dev/null && ok "wrote /etc/pip.conf" || warn "could not write /etc/pip.conf"
fi

# Two directories have to be importable that otherwise are not.
#
# 1. sudo needs a password on this image, so anything the learner installs
#    themselves lands in ~/.local, which root cannot import from.
#
# 2. `python3 harvest/01_listings.py` puts harvest/ on sys.path - NOT the
#    directory it was launched from. So `import market_kit` fails from the
#    exact command the statement tells the learner to type, while
#    `python3 check_local.py` works, because that file sits in the project
#    root. Every harness in this pack injected PYTHONPATH and hid it.
#
# A .pth in each real site directory fixes both for every interpreter on the
# box. Note that .pth entries are APPENDED to sys.path, after the stdlib and
# site-packages, so putting the project there cannot shadow a module the
# checks import - which an exported PYTHONPATH, inserted ahead of the stdlib,
# would let the learner do.
mkdir -p "$PROJ" 2>/dev/null || true
PYVER="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null || echo "")"
if [ -n "$PYVER" ]; then
    if python3 - "$PROJ" "${LAB_HOME}/.local/lib/python${PYVER}/site-packages" <<'___LWPTH___'
import os
import site
import sys

wanted = "".join("%s\n" % arg for arg in sys.argv[1:])

candidates = []
for getter in ("getsitepackages", "getusersitepackages"):
    try:
        found = getattr(site, getter)()
    except Exception:
        continue
    candidates.extend([found] if isinstance(found, str) else list(found))
candidates.append("/usr/local/lib/python%d.%d/dist-packages" % sys.version_info[:2])
candidates.append("/usr/lib/python3/dist-packages")

written = 0
for directory in candidates:
    if not os.path.isdir(directory):
        continue
    # An older provisioning wrote half of this under another name; leaving it
    # behind would put the same directory on sys.path twice.
    try:
        os.unlink(os.path.join(directory, "lambwell-user-site.pth"))
    except OSError:
        pass
    target = os.path.join(directory, "lambwell-paths.pth")
    try:
        with open(target, "w") as handle:
            handle.write(wanted)
        os.chmod(target, 0o644)
    except OSError:
        continue
    written += 1
    print("path bootstrap -> %s" % target)

sys.exit(0 if written else 1)
___LWPTH___
    then
        ok "python path bootstrap written"
    else
        warn "no site directory accepted a .pth - market_kit will not import"
    fi
fi
note "base packages done (t+${SECONDS}s)"

echo "=== [2/8] Runtime dependencies (detached; the foreground never waits) ==="
PIPLOG="${LOG_DIR}/pip.log"
DEPS_STATE="${LOG_DIR}/deps.state"
DEPS_READY="${LOG_DIR}/deps.ready"
DEPS_JOB="${LOG_DIR}/install-deps.sh"
rm -f "$DEPS_STATE" "$DEPS_READY"

{
    echo '#!/bin/bash'
    echo '# GENERATED by the setup script - installs what the lab needs after'
    echo '# provisioning has already returned, then publishes a readiness file.'
    echo "DEPS_STATE=\"${DEPS_STATE}\""
    echo "DEPS_READY=\"${DEPS_READY}\""
    echo "PROJ=\"${PROJ}\""
    echo "PORT=\"${PORT}\""
    # LAB_HOME and LAB_USER were referenced by the body below but never defined
    # here. The heredoc is quoted, so they stayed literal and expanded to
    # nothing at run time: the browser was copied to /.cache/ms-playwright at
    # the filesystem root and never reached the learner, who was then told to
    # run `playwright install`. build.sh now fails if this list drifts again.
    echo "LAB_HOME=\"${LAB_HOME}\""
    echo "LAB_USER=\"${LAB_USER}\""
    cat <<'DEPSJOB'
# An empty path variable here is not a warning, it is a wrong directory: every
# path below is absolute, so "${LAB_HOME}/.cache" becomes "/.cache" and the
# work silently lands at the filesystem root. Refuse instead.
for required in DEPS_STATE DEPS_READY PROJ PORT LAB_HOME LAB_USER; do
    if [ -z "${!required}" ]; then
        echo "FATAL: ${required} is empty - refusing to write to an absolute path built from nothing" \
            >> "${DEPS_STATE:-/var/log/lambwell-lab/deps.state}"
        exit 1
    fi
done

# Keeps this from dropping root-owned __pycache__ into the learner project
# after phase 8 has already handed it over.
export PYTHONDONTWRITEBYTECODE=1
export DEBIAN_FRONTEND=noninteractive
APT_OPTS="-o DPkg::Lock::Timeout=60"

# pip for the wheels below; curl and jq because the check scripts use them.
for attempt in 1 2; do
    # shellcheck disable=SC2086
    apt-get install -y -qq --no-install-recommends $APT_OPTS python3-pip curl jq && break
    # shellcheck disable=SC2086
    apt-get update -qq $APT_OPTS
    # shellcheck disable=SC2086
    apt-get install -y -qq --no-install-recommends $APT_OPTS python3-pip curl jq && break
    sleep 5
done

PIPFLAGS="--quiet --disable-pip-version-check --only-binary=:all:"
if python3 -m pip install --help 2>/dev/null | grep -q break-system-packages; then
    PIPFLAGS="$PIPFLAGS --break-system-packages"
fi

# The one dependency in this module that cannot be pre-baked: a browser. The
# wheel is small, the browser build is not, and `install-deps` is an apt
# transaction of its own - which is exactly why all of it is here, after
# provisioning has already returned.
# shellcheck disable=SC2086
if python3 -m pip install $PIPFLAGS "playwright==1.49.0"; then
    echo wheel > "$DEPS_STATE"
# shellcheck disable=SC2086
elif python3 -m pip install $PIPFLAGS "playwright<2"; then
    echo series > "$DEPS_STATE"
else
    echo failed > "$DEPS_STATE"
fi

if [ "$(cat "$DEPS_STATE" 2>/dev/null)" != "failed" ]; then
    # The system libraries first, then the browser itself. Both are bounded:
    # apt on a freshly booted VM can sit on the dpkg lock indefinitely, and a
    # hang here is what turns a slow lab into a broken one.
    # System libraries need root. The browser itself must NOT be downloaded by
    # root: it lands in /root/.cache keyed to the playwright version ROOT
    # resolves, and the learner then runs their own interpreter, resolves a
    # possibly different playwright, finds no matching build, and is told to
    # "run playwright install". Download it AS the learner instead - their
    # interpreter, their default cache. No copy, no chown, and no way for the
    # two resolutions to disagree about which chromium build is wanted.
    python3 -m playwright install-deps chromium || \
        echo "install-deps did not finish" >> "$DEPS_STATE"

    BROWSERS="${LAB_HOME}/.cache/ms-playwright"
    mkdir -p "${LAB_HOME}/.cache" 2>/dev/null || true
    chown "${LAB_USER}:${LAB_USER}" "${LAB_HOME}/.cache" 2>/dev/null || true

    BROWSER_OK=0
    if id -u "$LAB_USER" >/dev/null 2>&1 && su - "$LAB_USER" -c \
        "PLAYWRIGHT_BROWSERS_PATH='${BROWSERS}' python3 -m playwright install chromium"; then
        BROWSER_OK=1
        echo "browser installed as ${LAB_USER}" >> "$DEPS_STATE"
    elif python3 -m playwright install chromium && [ -d /root/.cache/ms-playwright ]; then
        # Fallback for an image where su will not run: better a copied browser
        # than none. Version drift is possible here, which is why it is second.
        echo "installed as root - falling back to a copy" >> "$DEPS_STATE"
        cp -R /root/.cache/ms-playwright "${LAB_HOME}/.cache/" 2>/dev/null || true
        BROWSER_OK=1
    fi
    chown -R "${LAB_USER}:${LAB_USER}" "${LAB_HOME}/.cache" 2>/dev/null || true

    if [ "$BROWSER_OK" -eq 1 ]; then
        echo browser >> "$DEPS_STATE"
    else
        echo "browser install failed" >> "$DEPS_STATE"
    fi
fi

# Pay the first-launch cost, and - the point of running it at all - PROVE the
# learner can start a browser. Root having a working browser said nothing about
# the person who has to use it, which is how a lab with no usable chromium
# reported itself ready. Deliberately does not import market_kit or require the
# site: this job is detached at phase 2 and both arrive later, and conflating
# "no browser" with "not built yet" is what made the old message useless.
cat > /tmp/lambwell_warm.py <<'WARM'
import sys

try:
    from playwright.sync_api import sync_playwright
except Exception as exc:
    print("warm-up FAILED: playwright will not import: %s" % exc)
    sys.exit(1)

url = "http://127.0.0.1:%s/" % (sys.argv[1] if len(sys.argv) > 1 else "8711")
try:
    with sync_playwright() as play:
        browser = play.chromium.launch()
        page = browser.new_page()
        try:
            page.goto(url, timeout=20000)
            print("warm-up complete: opened %r" % page.title())
        except Exception as exc:
            print("browser launched; the site was not up yet (%s)"
                  % type(exc).__name__)
        browser.close()
except Exception as exc:
    print("warm-up FAILED: the browser will not launch: %s: %s"
          % (type(exc).__name__, exc))
    sys.exit(1)
WARM
chmod 644 /tmp/lambwell_warm.py
if su - "$LAB_USER" -c \
    "PLAYWRIGHT_BROWSERS_PATH='${LAB_HOME}/.cache/ms-playwright' python3 /tmp/lambwell_warm.py '${PORT}'"; then
    echo browser-verified >> "$DEPS_STATE"
else
    echo browser-unverified >> "$DEPS_STATE"
fi
rm -f /tmp/lambwell_warm.py

# Written last, and only once the install has resolved, so its presence means
# the state file is final and pip, curl and jq are all present.
touch "$DEPS_READY"
DEPSJOB
} > "$DEPS_JOB"
chmod 700 "$DEPS_JOB"
detach "$PIPLOG" "$DEPS_JOB"
note "runtime dependency install detached (job ${DEPS_JOB}, log ${PIPLOG})"

echo "=== [3/8] Project skeleton ==="
mkdir -p "$KIT" "$PKG" "${PROJ}/out"

cat > "${KIT}/__init__.py" <<'___LWFILE___'
@@FILE:app/market_kit/__init__.py@@
___LWFILE___

cat > "${KIT}/site.py" <<'___LWFILE___'
@@FILE:app/market_kit/site.py@@
___LWFILE___

cat > "${PROJ}/check_local.py" <<'___LWFILE___'
@@FILE:app/check_local.py@@
___LWFILE___

cat > "/tmp/.lw_01.py" <<'___LWFILE___'
@@FILE:app/harvest/01_listings_stub.py@@
___LWFILE___

cat > "/tmp/.lw_02.py" <<'___LWFILE___'
@@FILE:app/harvest/02_feed_stub.py@@
___LWFILE___

cat > "/tmp/.lw_03.py" <<'___LWFILE___'
@@FILE:app/harvest/03_session_stub.py@@
___LWFILE___

cat > "/tmp/.lw_04.py" <<'___LWFILE___'
@@FILE:app/harvest/04_audit_stub.py@@
___LWFILE___

# Never clobber work in progress: the starters are only installed on a fresh
# project.
for pair in "01_listings.py:/tmp/.lw_01.py" "02_feed.py:/tmp/.lw_02.py" \
            "03_session.py:/tmp/.lw_03.py" "04_audit.py:/tmp/.lw_04.py"; do
    name="${pair%%:*}"; from="${pair#*:}"
    if [ ! -f "${PKG}/${name}" ]; then
        cp "$from" "${PKG}/${name}"
        echo "installed harvest/${name} starter"
    else
        echo "harvest/${name} already exists - left untouched"
    fi
done
rm -f /tmp/.lw_01.py /tmp/.lw_02.py /tmp/.lw_03.py /tmp/.lw_04.py

# Hand the project over immediately, before any step that could fail and leave
# these files root-owned - and therefore read-only for the learner.
run "early chown of ${PROJ}" chown -R "${LAB_USER}:${LAB_USER}" "$PROJ"
chmod -R u+rw "$PROJ" 2>/dev/null || warn "early chmod failed"
find "$PROJ" -type d -exec chmod u+x {} + 2>/dev/null || true
[ -s "${PKG}/04_audit.py" ] && ok "harvest starters in place" || warn "harvest starters missing"
[ -s "${KIT}/site.py" ] && ok "market_kit in place" || warn "market_kit missing"

# In place is not the same as importable. Prove the statement's own command
# works, the way the learner issues it: from the project directory, as the
# learner rather than as root, and from a script whose own directory is NOT
# the project - which is the whole reason a bare `import market_kit` can fail
# while check_local.py, sitting in the project root, succeeds.
printf 'import market_kit\n' > /tmp/lambwell_pathcheck.py 2>/dev/null || true
chmod 644 /tmp/lambwell_pathcheck.py 2>/dev/null || true
if ! id -u "$LAB_USER" >/dev/null 2>&1; then
    warn "no ${LAB_USER} account yet - could not verify that market_kit imports"
elif su - "$LAB_USER" -c "cd '${PROJ}' && python3 /tmp/lambwell_pathcheck.py" >/dev/null 2>&1; then
    ok "import market_kit works from ${PROJ} with no PYTHONPATH"
else
    warn "import market_kit FAILS from ${PROJ} - the learner cannot run harvest/01_listings.py"
fi
rm -f /tmp/lambwell_pathcheck.py
note "project skeleton done (t+${SECONDS}s)"

echo "=== [4/8] Market site files ==="
mkdir -p "$SVC"

cat > "${SVC}/marketsite.py" <<'___LWFILE___'
@@FILE:service/marketsite.py@@
___LWFILE___

chown -R root:root "$SVC"
chmod 700 "$SVC"
chmod 700 "${SVC}/marketsite.py"
note "market site files written (t+${SECONDS}s)"

echo "=== [5/8] Learner state and environment ==="
# The harvest writes into out/, and grading runs as root, so the directory is
# created here as the learner. Every check also chowns the project back from an
# EXIT trap.
mkdir -p "${PROJ}/out" 2>/dev/null || true
run "chown out directory to ${LAB_USER}" chown -R "${LAB_USER}:${LAB_USER}" "${PROJ}/out"

# A browser installed as root lands in the root cache. Point the learner shell
# at the copy made for them, so their scripts find a browser at all.
cat > /etc/profile.d/lambwell.sh <<PROFILE
export LAMBWELL_SITE_URL=http://127.0.0.1:${PORT}
export PLAYWRIGHT_BROWSERS_PATH=${LAB_HOME}/.cache/ms-playwright
PROFILE
chmod 644 /etc/profile.d/lambwell.sh 2>/dev/null || true
ok "browser cache location written to /etc/profile.d/lambwell.sh"
note "learner state done (t+${SECONDS}s)"

echo "=== [6/8] Starting the market site ==="
start_with_systemd() {
    command -v systemctl >/dev/null 2>&1 || return 1
    cat > /etc/systemd/system/lambwell-site.service <<UNIT
[Unit]
Description=Lambwell market site
After=network.target

[Service]
Type=simple
Environment=LAMBWELL_PORT=${PORT}
ExecStart=${PYBIN} ${SVC}/marketsite.py
Restart=always
RestartSec=2
User=root

[Install]
WantedBy=multi-user.target
UNIT
    cap 15 systemctl daemon-reload >/dev/null 2>&1 || return 1
    cap 25 systemctl enable --now lambwell-site >/dev/null 2>&1 || return 1
    return 0
}

start_with_nohup() {
    if command -v systemctl >/dev/null 2>&1; then
        cap 15 systemctl disable --now lambwell-site >/dev/null 2>&1 || true
    fi
    export LAMBWELL_PORT="$PORT"
    detach /var/log/lambwell-site.log "$PYBIN" "${SVC}/marketsite.py"
}

wait_health() {
    local i
    for i in $(seq 1 20); do
        svc_healthy && return 0
        sleep 0.5
    done
    return 1
}

if svc_healthy; then
    ok "market site already running on ${PORT}"
elif start_with_systemd && wait_health; then
    ok "market site started under systemd"
else
    echo "systemd path unavailable, falling back to a background process"
    start_with_nohup
    wait_health || warn "the market site did not come up during setup; the check scripts start it on demand, so grading still works (see ${LOG})"
fi
if svc_healthy; then
    ok "market site healthy on 127.0.0.1:${PORT}"
else
    warn "market site not answering on 127.0.0.1:${PORT} at end of setup"
fi
note "market site up (t+${SECONDS}s)"

echo "=== [7/8] Dependency hand-off ==="
DEPS_GRACE="${DEPS_GRACE:-5}"
for _i in $(seq 1 "$DEPS_GRACE"); do
    [ -f "$DEPS_READY" ] && break
    sleep 1
done
if grep -q browser "$DEPS_STATE" 2>/dev/null; then
    ok "playwright and a chromium build are installed"
elif grep -q failed "$DEPS_STATE" 2>/dev/null; then
    warn "the playwright install FAILED - the lab cannot run until this is fixed (see ${PIPLOG})"
else
    note "playwright and the browser are still installing in the background (log ${PIPLOG}); this is the slow part of this lab and takes a few minutes. ${DEPS_READY} appears when it finishes."
fi
tail -n 5 "$PIPLOG" 2>/dev/null | sed 's/^/    pip| /'
note "dependencies handed off (t+${SECONDS}s)"

finish_summary() {
    [ "${SUMMARY_DONE:-0}" -eq 1 ] && return 0
    SUMMARY_DONE=1
    local blockers=""
    command -v python3 >/dev/null 2>&1 || blockers="${blockers} python3-missing"
    [ -s "${KIT}/site.py" ] || blockers="${blockers} project-missing"
    [ -s "${PKG}/01_listings.py" ] || blockers="${blockers} starters-missing"
    svc_healthy || blockers="${blockers} desk-down"
    if [ -n "$blockers" ]; then
        warn "LAB NOT READY -${blockers}"
        note "provisioning could not finish the essentials. Re-running setup on a fresh VM is"
        note "the fastest remedy; the phase timings above show which step ran out of time."
        note "total setup time: ${SECONDS}s"
        return 0
    fi
cat <<SUMMARY

--------------------------------------------------------------------
Lambwell Market lab is ready.

Project:   ${PROJ}
Provided:  market_kit/       where the market is, and where artefacts go
           check_local.py    runs all four steps and summarises each artefact
           out/              where your artefacts belong
You write: harvest/01_listings.py
           harvest/02_feed.py
           harvest/03_session.py
           harvest/04_audit.py

The market is at http://127.0.0.1:${PORT} and is running now. Leave it running.

Playwright and a chromium build are installing in the background - that is the
slow part of this lab. Check with:
    python3 -c 'from playwright.sync_api import sync_playwright; print("ready")'

Then run the harvest:
    cd ${PROJ}
    python3 harvest/01_listings.py
    python3 check_local.py

Setup log:    ${LOG}
Setup status: ${STATUS_FILE}
--------------------------------------------------------------------
SUMMARY

if [ "$WARNINGS" -gt 0 ]; then
    note "setup finished with ${WARNINGS} warning(s):"
    grep '^WARN' "$STATUS_FILE" 2>/dev/null | sed 's/^/    /'
else
    note "setup finished with no warnings"
fi
note "total setup time: ${SECONDS}s"
    if [ "$DEADLINE_HIT" -eq 1 ]; then
        note "finished early on the internal deadline; the project and the market site are in place"
    fi
}

echo "=== [8/8] Permissions and summary ==="
run "chown project to ${LAB_USER}" chown -R "${LAB_USER}:${LAB_USER}" "$PROJ"
run "make project writable" chmod -R u+rw "$PROJ"
find "$PROJ" -type d -exec chmod u+x {} + 2>/dev/null || warn "could not set directory execute bits"
rm -rf "${PROJ}/__pycache__" "${KIT}/__pycache__" "${PKG}/__pycache__" 2>/dev/null || true
[ -w "${PKG}/04_audit.py" ] || warn "harvest/04_audit.py is not writable - the learner will hit a read-only file"

finish_summary

kill "$WATCHDOG_PID" >/dev/null 2>&1 || true
sync 2>/dev/null || true
exit 0
