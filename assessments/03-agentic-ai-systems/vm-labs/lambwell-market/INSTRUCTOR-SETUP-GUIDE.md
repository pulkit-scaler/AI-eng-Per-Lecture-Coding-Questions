# Instructor setup — `lambwell-market`

## Portal configuration

- **Lab image:** *systemd Ubuntu*.
- **Setup script:** `dist/Setup.zip`. **Test cases:** `dist/TestCase.zip`.
- **Max Score: 50.** Five test cases, **10 points each**.
- **Problem statement:** `problem-statement.md`, pasted as-is. No tables.

## Read this before you schedule it

**This is the one lab in the module with a dependency that cannot be pre-baked.**
Playwright's wheel is small; a Chromium build is not, and `playwright
install-deps` is an apt transaction of its own. All of it runs in the detached
setup job, so provisioning still returns in seconds — but there is a window of a
few minutes at the start of the lab where no browser exists.

What that means in practice:

- The statement opens by telling the learner to check with
  `python3 -c 'from playwright.sync_api import sync_playwright; print("ready")'`.
- **The checks do not need the browser at all.** They read the artefacts the
  harvest left and the site's request log. So a slow browser install delays the
  learner, never the grading.
- Setup copies the browser out of the root cache into `~user/.cache` and points
  `PLAYWRIGHT_BROWSERS_PATH` at it in `/etc/profile.d/lambwell.sh`. A browser
  installed as root is invisible to the learner otherwise. If a learner reports
  *Executable doesn't exist*, that variable is the first thing to check.

## What provisioning does

Foreground: python3 if missing, `/etc/pip.conf`, the project (`market_kit/`,
`check_local.py`, the four starters, `out/`) **chowned to `user` immediately**,
the market site installed to `/opt/lambwell-svc` (`root:root 0700`) and started
under systemd on 8711, and `/etc/profile.d/lambwell.sh`.

Detached: `python3-pip curl jq`, `playwright==1.49.0`,
`playwright install-deps chromium`, `playwright install chromium`, the copy into
the learner cache, then a warm-up that opens the market front page in a real
browser.

## Time budgets

Each check: 12 (site) + a 90 s ceiling that in practice is never approached —
every check is a handful of local HTTP calls and some `jq`, and the observed
slowest is **1 s**. Each check appends its wall time to
`/tmp/lambwell_timing.log`.

## What the checks touch

Nothing. They read `out/` and the site log. Ownership is still handed back from
an `EXIT` trap so that a future check which does write cannot lock the learner
out.

## Marking notes

- **A learner who re-runs the harvest is not penalised.** The site log outlives
  any single run, so check 3 asserts the *ratio* of signed-in page loads to
  sign-ins rather than a count of sign-ins. This was found by the ordering
  matrix: an earlier version failed a learner who simply ran their own harvest
  twice.
- **Only the steps that ran can score.** Running two of the four scores 20/50,
  and each unrun step is reported as a missing artefact naming the script to
  run. That is by design: the checks do not run the harvest.
- Five structurally different correct shapes all score 50/50 — see `README.md`.
- Six defect probes each lose exactly one theme.
- Hand-written artefacts, including a hand-assembled `trace.zip`, score
  **0/50**.

## Before the first cohort

Run `validation/permutations.sh` **as root on a provisioned VM** once. Seven rows
covering starters untouched, written-but-never-run, a partial harvest, a full
harvest, a killed grading run, a repeat, and a re-harvest after grading. On a
real VM its ownership assertions stop being vacuous. `VALIDATION.md` records what
is and is not proven.
