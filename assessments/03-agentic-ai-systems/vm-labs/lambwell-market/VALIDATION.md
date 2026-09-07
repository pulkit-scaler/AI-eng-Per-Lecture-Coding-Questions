# `lambwell-market` — validation record

Everything below was **run** against a real Chromium. Authoring host: macOS,
CPython 3.13 with `playwright==1.49.0` and a chromium build.
Target VM: *systemd Ubuntu*, Ubuntu 25.04 / Python 3.13.3.

## 1. Reference solution

`PY=<playwright venv> ./test-cases/scripts/run-all.sh`

```
01_listings      3s  exit 0
02_feed          0s  exit 0
03_session       1s  exit 0
04_audit         3s  exit 0

SCORE: 50/50   (passed 5, failed 0)
slowest test case: 1s   (portal limit is about 120s)
```

The four artefacts, checked by hand before any check existed:

- `listings.json` — 9 stalls, first `A1 / Halloway Fruit / apples, pears / 1968`,
  last `C3 / Wend Coffee / beans, cups / 2014`, token `stalls-0001`.
- `feed.json` — 47 lots, ids 1 to 47, 0 duplicates, monotonic, **6 scrolls**,
  stopped because *the feed reported no new lots*.
- `orders.json` — all four order ids, token `orders-0004`.
- `audit.json` — `/private/` skipped by robots rule, four pages visited;
  `trace.zip` 83 KB.

And from the site's own log for that run:

```
POST /login accepted : 1
/orders with session : 2
/orders 401          : 0
/private/ requests   : 0
audit-tagged gaps    : 1.020, 1.017, 1.018  -> min 1.017 (asked: 1.0)
```

## 2. Alternative shapes — all 50/50

- `alt1_async` — the async Playwright API.
- `alt2_row_locators` — rows by attribute, cells through `nth()`.
- `alt3_keyboard_scroll` — the feed scrolled with the End key.
- `alt4_manual_state` — session state written out by hand from
  `context.cookies()`.
- `alt5_browser_robots` — robots.txt fetched through the browser client.

## 3. Defect probes — each loses exactly its own theme

- `_defect1_early_read` — waits for the table to exist, not to finish. **40/50,
  `script_01`.**
- `_defect2_fixed_scrolls` — three scrolls and stop. **40/50, `script_02`.**
- `_defect3_login_each_time` — signs in again instead of reusing the state.
  **40/50, `script_03`.**
- `_defect4_ignores_robots` — reads robots.txt and visits the disallowed path
  anyway. **40/50, `script_04`.**
- `_defect5_no_pacing` — no wait between requests. **40/50, `script_04`**
  (closest gap 0.0048 s against 1 s).
- `_defect6_no_trace` — records no trace. **40/50, `script_05`.**

## 4. Fabrication probe

`_cheat_fabricated` writes all four artefacts from hardcoded data — the right
stalls, the right 47 lots, the right order ids, the right robots verdict — and
assembles a `trace.zip` by hand with a `trace.trace` containing the audit tags.
No browser is involved.

**0/50.** Every check is anchored in something the site recorded: the page tokens
it issued, the requests it served, and the timestamps of those requests. The
trace check is anchored in the size of the network log, which a hand-made archive
cannot fake.

That last assertion took two attempts. The first version required a real JPEG
among the trace resources, which closed the probe but **also failed
`_defect5_no_pacing`**: a run with no waiting at all is fast enough that
Playwright captures no screenshots. Asserting on the network log instead closes
the probe and leaves the pacing defect losing only its own theme.

## 5. Ordering matrix

`./validation/permutations.sh` — **7 rows, 0 failures**:

1. starters untouched, nothing run → 0/50.
2. written but never run → 0/50, each check naming the artefact it wanted and
   the script that makes it.
3. only the first two steps run → **20/50** — the two that ran are the two that
   scored.
4. the whole harvest run, then graded → 50/50.
5. grading killed after three checks → 30/50.
6. graded a second time → 50/50.
7. the harvest re-run after grading, then graded again → 50/50.

Rows 3, 4 and 6 each re-ran the learner's own harvest afterwards and it
succeeded.

## 6. The bug the matrix found

Row 7 originally scored **40/50**. Check 3 asserted *exactly one* successful
sign-in, and the site log outlives any single harvest — so a learner who simply
ran their own harvest twice was failed for it.

The check now asserts the **ratio**: every sign-in has to be worth at least two
signed-in page loads. One clean run is 1 and 2; two clean runs are 2 and 4; and
signing in for each page is 2 and 2 either way, which still fails. Re-verified
afterwards: the reference and `alt4_manual_state` at 50/50,
`_defect3_login_each_time` at 40/50 losing only check 3, and row 7 at 50/50.

This is exactly the class of failure the matrix exists for. The happy path was
green throughout.

## 7. The bug production found

A learner following the statement exactly hit this on their first command:

```
$ python3 harvest/01_listings.py
ModuleNotFoundError: No module named 'market_kit'
```

Nothing about their solution was wrong. `python3 harvest/01_listings.py` puts
`harvest/` on `sys.path`, **not** the directory it was launched from, so
`import market_kit` could never resolve — for anyone. `python3 check_local.py`
worked, because that file sits in the project root, which is why the failure
looked intermittent to the learner rather than total.

It survived the whole matrix because **every harness in this pack supplied the
missing path itself**: `check_local.py` passes `PYTHONPATH` to each subprocess,
`run-all.sh` and the matrix rows export it before playing the learner, and the
provisioning warm-up does `sys.path.insert(0, ".")`. The one invocation nobody
ever ran unaided was the one the statement tells the learner to type.

Fixed in provisioning, which now writes `lambwell-paths.pth` into every real
site directory, carrying both the project and the learner's `~/.local`
site-packages. Setup then **proves** it: phase 3 runs `import market_kit` as
`user`, from the project, via a script whose own directory is not the project,
and warns loudly if it fails.

`.pth` rather than an exported `PYTHONPATH` on purpose. `.pth` entries are
appended after the stdlib and site-packages; `PYTHONPATH` is inserted ahead of
them. Measured both ways with a `json.py` planted in the project and a grader
run from outside it: with the `.pth`, `json` still resolved to the stdlib; with
`PYTHONPATH=$PROJ`, the planted file won. The export would have handed every
learner a way to hijack the checks.

Row 1 of the matrix now asserts the statement's bare command on a provisioned
VM, and `run-all.sh` says in a comment that its `PYTHONPATH` stands in for the
`.pth` and is not evidence the bare command works.

## 8. The second bug production found

With the path fixed, the same learner hit:

```
Please run the following command to download new browsers: playwright install
```

Also not their solution, and also total rather than intermittent. The detached
dependency job is written with a **quoted** heredoc (`cat <<'DEPSJOB'`), so
nothing in its body is expanded at build time; the body must instead close over
its variables through the prelude that precedes it. That prelude defined
`DEPS_STATE`, `DEPS_READY`, `PROJ` and `PORT` — and the body also used
`LAB_HOME`, which nothing defined.

So on every VM the browser handoff ran as:

```
mkdir -p "/.cache"                                    # ${LAB_HOME} -> ""
cp -R /root/.cache/ms-playwright "/.cache/"
```

Root-owned, at the filesystem root, and never at `/home/user/.cache/ms-playwright`
where the learner's playwright looks. Both commands succeed as root, and both
had `2>/dev/null || true`, so provisioning reported itself healthy throughout.

Three fixes, at three levels:

- **The variable**: `LAB_HOME` and `LAB_USER` are now echoed into the prelude.
- **The class**: `build.sh` step 2b parses the quoted heredoc, collects every
  variable its body names, and fails the build if one is neither in the prelude
  nor assigned in the body. Verified by re-introducing the exact bug — the build
  fails and names `LAB_HOME`.
- **The blast radius**: the job now refuses to start if any required path
  variable is empty, rather than building an absolute path out of nothing.

The browser is additionally no longer downloaded by root and copied. It is
installed **as the learner**, with their interpreter, into their own default
cache — which removes the copy, the `chown`, and the possibility that root's
playwright version and the learner's disagree about which chromium build is
wanted (a third, independent way to produce the identical error message). The
warm-up then runs as the learner too and records `browser-verified` or
`browser-unverified` in `deps.state`; matrix row 2 asserts the former.

`DEPS_READY_FILE` was declared in the check preamble and never read, so the
checks reported this as *"there is no out/listings.json — run
python3 harvest/01_listings.py"*: a broken VM described as a wrong answer, with
a remedy that could not work. `require_artifact` now appends a diagnosis naming
the real cause — dependencies still installing, browser install failed,
playwright not importable, or an empty browser cache — each on a single line, so
the judge still grades exactly one verdict.

## 9. Why the checks do not drive a browser

Deliberate, and it is what makes this pack cheap to grade: the checks read the
artefacts and the site log, so the slowest is **1 s** and nothing in grading can
flake on a browser. The cost is that the learner must run all four steps before
submitting, which the statement says twice and which row 2 of the matrix confirms
is reported clearly rather than confusingly.

## 10. Not settled on this host

- **Sections 7 and 8 are now confirmed on a real VM.** On a freshly provisioned
  box, `python3 harvest/01_listings.py` ran with no `PYTHONPATH` set (the `.pth`
  bootstrap works on the real image), all four scripts launched a browser (the
  `LAB_HOME` fix puts chromium in the learner cache), and checks 1-3 scored
  30/30 against the reference solution. Check 4 was not exercised on that run —
  the operator had placed the 03 body in `harvest/04_audit.py`, which is a
  copying slip and not a pack defect, but it means **check 4 has still never run
  green end to end on a VM**. Do that before the next cohort.
- **`sweep.sh` has not been re-run since either fix.** The authoring host has no
  playwright. The `.pth` mechanism was A/B'd against the writer lifted verbatim
  out of the generated `setup_script.sh`; the deps job was emitted the way the
  VM emits it and its paths inspected; the build invariant was verified by
  re-introducing the bug. None of that substitutes for a full sweep.
- **Root ownership**: vacuous with no `user` account. Run the matrix as root on a
  provisioned VM once.
- **The browser install on the real image.** `playwright install-deps chromium`
  plus the browser download is the slowest provisioning step in the module and
  was only exercised on the authoring host, where the browser was already
  present. The copy from the root cache into `~user/.cache` and the
  `PLAYWRIGHT_BROWSERS_PATH` export are the parts to watch on the first real
  provision: if a learner reports *Executable doesn't exist*, that is where to
  look.
- **Chromium version drift.** The pack pins `playwright==1.49.0`, which pins the
  browser build with it. The site uses ordinary DOM and `fetch`, so nothing here
  is version-sensitive, but re-run `sweep.sh` after any pin change.
