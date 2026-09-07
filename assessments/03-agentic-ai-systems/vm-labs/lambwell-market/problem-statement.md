# Lambwell Market — Harvest the Market

## Overview

Lambwell Market publishes its stall register, its lot feed and its traders'
standing orders on a small website. None of it is available as a download, all of
it is rendered in the browser, and one part of it is behind a sign-in.

You build the harvest: **four scripts, run in order, each leaving an artefact
behind**. That is what a real scrape looks like — not one long session, but steps
that can be re-run, checked and handed on.

## Learning objectives

- Point a browser at a page and wait for **the thing you need**, not for a
  guessed number of seconds.
- Locate elements by what they are — roles, labels, attributes — rather than by
  position.
- Harvest a page that grows as it is **scrolled**, and stop because it ran out
  rather than because a counter did.
- Sign in **once**, save what the session left behind, and reuse it in a fresh
  context.
- Read **robots.txt** and do what it says, including the pace it asks for.
- Record a **trace** of a run, so a failure can be looked at afterwards instead
  of reproduced.

## Environment

The VM is already provisioned, but **one thing arrives late**: Playwright and a
Chromium build are installed in the background and take a few minutes. Check
with:

```bash
python3 -c 'from playwright.sync_api import sync_playwright; print("ready")'
```

- The market is running at `http://127.0.0.1:8711`. Leave it running.
- Work in `/home/user/lambwell-market` and run everything from that directory,
  so `import market_kit` resolves and `out/` is where you expect.
- The browser was installed for you and `PLAYWRIGHT_BROWSERS_PATH` already
  points at it. If you open a new shell and the browser cannot be found, that
  variable is the thing to check.
- Use the **sync** Playwright API — these are standalone scripts, not notebook
  cells, so there is no event loop already running to fight with. The async API
  works too if you prefer it.

## What is provided

Under `/home/user/lambwell-market/`:

```
market_kit/site.py   where the market is, and where artefacts go
harvest/
  01_listings.py     the starter - you write this
  02_feed.py         the starter - you write this
  03_session.py      the starter - you write this
  04_audit.py        the starter - you write this
out/                 where your artefacts belong
check_local.py       runs all four steps and summarises each artefact
```

```python
import market_kit as kit

kit.SITE_URL        # http://127.0.0.1:8711
kit.SETTLE_MS       # 8000 - how long to allow one page to settle
kit.MIN_INTERVAL    # 1.0 - the shortest gap the market asks for between requests
kit.LOGIN_USER      # harvester
kit.LOGIN_PASSWORD  # market-day
kit.OUT_DIR         # where out/ is
kit.write_artifact(name, payload)   # writes out/<name>.json
kit.read_artifact(name)
```

The market publishes that trader account for exactly this purpose. There is no
other credential and nothing to obtain.

**Every page that carries data also carries a token**, on the `<body>` element
as `data-token`. Record it in the artefact for that page: it is how the market
tells a harvest of its own pages from a file somebody typed out.

## Interface contract

- Four scripts, run as `python3 harvest/01_listings.py` and so on, from the
  project directory.
- Each writes its artefact with `kit.write_artifact`:
  - `01_listings.py` → `out/listings.json`
  - `02_feed.py` → `out/feed.json`
  - `03_session.py` → `out/orders.json`, and the saved session at
    `out/state.json`
  - `04_audit.py` → `out/audit.json`, and the trace at `out/trace.zip`
- The keys each artefact must carry are in the tasks below.

---

### Task 1 — `01_listings.py`: the stall register

1. Open `/stalls`. The table is **filled in a row at a time** by the page, and
   the last row lands well over a second after the page loads.
2. Wait for the table to be **finished**, not merely present. The page marks it:
   look at the `#stalls` element once it is done.
3. Read every row into a record with `stall`, `trader`, `goods` and `since`.
   `since` is a number.
4. Read the page token from `data-token` on the body.
5. Write `out/listings.json` with `token`, `count` and `stalls`.

**Requirements.** Waiting for a fixed number of seconds is a guess about
somebody else's timing; wait for the marker instead. `count` must equal the
number of stalls you actually recorded.

**Example.**

```
$ python3 harvest/01_listings.py
wrote /home/user/lambwell-market/out/listings.json
$ python3 -c 'import json;d=json.load(open("out/listings.json"));print(d["count"], d["stalls"][0])'
9 {'stall': 'A1', 'trader': 'Halloway Fruit', 'goods': 'apples, pears', 'since': 1968}
```

---

### Task 2 — `02_feed.py`: the lot feed

1. Open `/feed`. It shows a first batch of lots and fetches more each time the
   page is scrolled to the bottom.
2. Scroll, wait for either more lots or the page's own signal that there are
   none left, and repeat.
3. Stop when the feed says it is exhausted. Keep a **cap** on the number of
   scrolls as a backstop, but a run that ends on the cap has not finished the
   job.
4. Read every lot into a record with `id`, `lot`, `stall` and `weight_kg`.
   `id` is the lot's own number, which the page carries on each lot; it is not
   the same thing as `lot`, which is the printed label. `weight_kg` is a number.
5. Write `out/feed.json` with `token`, `count`, `scrolls`, `stop_reason` and
   `lots`.

**Requirements.** No lot may appear twice, and they must be in the order the
feed served them. `stop_reason` says in words why the loop ended — that sentence
is the difference between a harvest that finished and one that gave up.

**Example.**

```
$ python3 -c 'import json;d=json.load(open("out/feed.json"));print(d["count"], d["stop_reason"])'
47 the feed reported no new lots
$ python3 -c 'import json;d=json.load(open("out/feed.json"));print(d["lots"][0])'
{'id': 1, 'lot': 'LOT-001', 'stall': 'A1', 'weight_kg': 11}
```

---

### Task 3 — `03_session.py`: sign in once

1. Open `/login` and sign in with `kit.LOGIN_USER` and `kit.LOGIN_PASSWORD`.
   Find the fields by their labels and the button by its role, not by position.
2. Save what the session left behind to **`out/state.json`**.
3. Open a **fresh browser context** using that saved state — no history, no
   cookies of its own — and read `/orders`.
4. Read every row into a record with `order`, `stall` and `crates`, and take the
   page token.
5. Write `out/orders.json` with `token`, `count`, `order_ids` and `orders`.

**Requirements.** **Exactly one sign-in.** A harvest that signs in again for
every page is not reusing the session. `/orders` answers 401 without a session,
so if the state did not survive, the second context is turned away and you will
see it.

**Example.**

```
$ python3 -c 'import json;d=json.load(open("out/orders.json"));print(d["order_ids"])'
['LW-6001', 'LW-6002', 'LW-6003', 'LW-6004']
```

---

### Task 4 — `04_audit.py`: walk what you are allowed to, at the right pace

1. Fetch `/robots.txt` and parse it: the `Disallow:` rules and the
   `Crawl-delay:`.
2. Visit these paths in order: `/`, `/stalls`, `/feed`, `/login`,
   `/private/ledger`. Whether you may is robots.txt to say, not the list.
3. **Skip anything a Disallow rule covers** and record it as skipped, with the
   reason. Do not fetch it to see what is there.
4. Keep at least the crawl delay between two requests, and never less than
   `kit.MIN_INTERVAL`. Wait **before** the request, so the gap the site sees is
   the gap you meant.
5. Tag each visit with `?audit=<n>`, `n` being its position in the list, so the
   pace can be checked afterwards.
6. Record a Playwright **trace** of the whole walk to `out/trace.zip`, with
   screenshots and snapshots on.
7. Write `out/audit.json` with `robots_disallow`, `crawl_delay`,
   `interval_used`, `visited`, `skipped` and `trace_file`.

**Requirements.** The disallowed path must never be requested — not once, not to
check. The trace has to be a real recording: start tracing on the context before
the walk and stop it to a file afterwards.

**Example.**

```
$ python3 -c 'import json;d=json.load(open("out/audit.json"));print(d["robots_disallow"], [v["path"] for v in d["visited"]], d["skipped"])'
['/private/'] ['/', '/stalls', '/feed', '/login'] [{'path': '/private/ledger', 'reason': 'disallowed by robots.txt'}]
```

---

## Run and verify before you submit

```bash
cd /home/user/lambwell-market

python3 -c 'from playwright.sync_api import sync_playwright; print("ready")'
curl -s http://127.0.0.1:8711/health

python3 harvest/01_listings.py
python3 harvest/02_feed.py
python3 harvest/03_session.py
python3 harvest/04_audit.py

python3 check_local.py
ls -l out/
```

**Run all four before you submit.** The checks read the artefacts you left
behind and the market's own record of what it was asked for — they do not drive
a browser themselves, and a step that was never run has nothing to grade.

## How you are graded

Five checks, 10 points each, 50 in total. Each one compares your artefact against
what the market holds, and against the market's own log of what it was asked for.

1. **The stall register.** Every stall, field for field, from a page that fills
   in a row at a time — with a page token the market really issued.
2. **The feed.** Every lot, in order, no repeats, stopping because the feed ran
   out rather than because a counter did.
3. **The session.** One sign-in, a saved session with the cookie in it, all the
   standing orders read back in a fresh context, and never once turned away.
4. **Robots and pace.** The disallowed path never requested, the disallow list
   read from the file, and every request at least a crawl delay apart as
   measured at the market.
5. **The trace.** A readable archive with the run's events and real screenshots
   in it, mentioning the pages the audit visited.
