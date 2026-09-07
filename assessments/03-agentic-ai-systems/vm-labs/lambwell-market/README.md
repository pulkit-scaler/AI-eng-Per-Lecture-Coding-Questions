# `lambwell-market` — Browser Automation & Web Agents (M3-L9)

A VM lab whose deliverable is **four scripts in a pipeline, each leaving an
artefact behind**. The learner drives a real Chromium against a real site; the
checks read the artefacts and the site's own record of what it was asked for.

- **Target image:** *systemd Ubuntu* (Ubuntu 25.04 / Python 3.13.3).
- **Max Score 50 = 5 checks × 10.**
- **Project:** `/home/user/lambwell-market`. Market site on `127.0.0.1:8711`.
  Artefacts in `out/`.

## The design decision that matters

**The checks never drive a browser.** They read `out/*.json`, `out/trace.zip`
and the site's request log. Three things follow:

- **Grading is fast and cannot flake on the browser.** Every check finishes in
  about a second. The one dependency on this image that cannot be pre-baked — a
  Chromium build — is the learner's concern only.
- **The learner must run the harvest before submitting**, and the statement says
  so. A step that was never run has nothing to grade, and the check says exactly
  that rather than starting a browser as root.
- **Fabrication is closed off by the site, not by re-running.** Every page
  carrying data also carries a `data-token`, and the site records which tokens it
  has issued. An artefact quoting a token the site never issued did not come from
  the site. The request log then supplies everything else: how many sign-ins
  happened, whether the disallowed path was ever asked for, and the timestamps
  the pace is measured from.

## The five themes

1. **The stall register** — a table the page fills in a row at a time over
   1.5 s. Graded on every stall matching field for field, plus a token the site
   really issued. Reading it as soon as it has a row is short by several rows.
2. **The feed** — 47 lots in pages of 8. Graded on the count, strict ordering,
   no repeats, and a `stop_reason` that is not "hit my own limit".
3. **The session** — sign in, save the state, reuse it in a fresh context.
   Graded on all four orders coming back, a session cookie in `out/state.json`,
   never being turned away with a 401, and **each sign-in being worth at least
   two signed-in page loads**.
4. **Robots and pace** — the disallowed path never requested at all, the
   disallow list read from the file rather than assumed, and the minimum gap
   between requests measured *at the site*.
5. **The trace** — a readable archive with the run's events, a real network log,
   and the pages the audit visited named inside it.

## Marking notes

All 50/50: the async Playwright API; rows located by attribute with cells read
through `nth()`; the feed scrolled from the keyboard instead of the mouse; the
session state written out by hand from `context.cookies()`; robots.txt fetched
through the browser client instead of urllib.

Six defect probes, each losing exactly one theme: reading the table as soon as it
has a row; a fixed number of scrolls; signing in for every page; visiting the
disallowed path anyway; no pacing; no trace.

The fabrication probe — all four artefacts written out by hand, plus a
hand-assembled `trace.zip` — scores **0/50**.

## Pack layout

```
app/                    market_kit, check_local.py, the four starters
service/marketsite.py   the market site and its request log (root-only)
setup/                  setup_script.template.sh -> scripts/setup_script.sh
reference-solution/     the model answer, 5 alternative shapes, 6 defect probes,
                        1 fabrication probe
test-cases/scripts/     script_01..05.sh (shipped) + common.sh, run-all.sh
validation/             the ordering matrix
dist/                   Setup.zip + TestCase.zip
```

## Authoring commands

```bash
./gen_tests.sh
./build.sh
PY=/path/to/playwright-venv/bin/python ./test-cases/scripts/run-all.sh
PY=... ./sweep.sh
PY=... ./validation/permutations.sh
```

`run-all.sh` plays the learner: it starts the site, resets its log, runs all four
harvest steps, and only then runs the checks.
