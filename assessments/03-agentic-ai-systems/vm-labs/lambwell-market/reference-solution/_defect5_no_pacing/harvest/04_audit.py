#!/usr/bin/env python3
"""DEFECT: no pacing between requests.

Walk the pages robots.txt allows, at the pace it asks for, under a trace."""
import time
import urllib.request

from playwright.sync_api import sync_playwright

import market_kit as kit

TRACE = kit.OUT_DIR / "trace.zip"
# Everything the audit would like to look at. Whether it may is robots.txt to
# say, not this list.
WANTED = ["/", "/stalls", "/feed", "/login", "/private/ledger"]


def read_robots():
    with urllib.request.urlopen("%s/robots.txt" % kit.SITE_URL, timeout=10) as r:
        text = r.read().decode("utf-8")
    disallowed = []
    delay = kit.MIN_INTERVAL
    for line in text.splitlines():
        line = line.strip()
        if line.lower().startswith("disallow:"):
            value = line.split(":", 1)[1].strip()
            if value:
                disallowed.append(value)
        elif line.lower().startswith("crawl-delay:"):
            try:
                delay = float(line.split(":", 1)[1].strip())
            except ValueError:
                pass
    return text, disallowed, delay


def allowed(path, disallowed):
    return not any(path.startswith(rule) for rule in disallowed)


def main():
    kit.OUT_DIR.mkdir(parents=True, exist_ok=True)
    robots, disallowed, delay = read_robots()
    interval = max(delay, kit.MIN_INTERVAL)

    visited = []
    skipped = []
    with sync_playwright() as play:
        browser = play.chromium.launch()
        context = browser.new_context()
        # The trace is the thing to reach for first when a harvest goes wrong:
        # it records every action, with the DOM as it was at the time.
        context.tracing.start(screenshots=True, snapshots=True, sources=False)
        page = context.new_page()

        last = 0.0
        for index, path in enumerate(WANTED, start=1):
            if not allowed(path, disallowed):
                skipped.append({"path": path, "reason": "disallowed by robots.txt"})
                continue
            # The pace is kept before the request, not after it, so the gap the
            # site sees is the gap that was asked for.
            # No wait at all.
            target = "%s%s?audit=%d" % (kit.SITE_URL, path, index)
            response = page.goto(target, timeout=kit.SETTLE_MS)
            last = time.monotonic()
            visited.append({"path": path, "tag": "audit=%d" % index,
                            "status": response.status if response else None})

        context.tracing.stop(path=str(TRACE))
        context.close()
        browser.close()

    kit.write_artifact("audit", {
        "robots_disallow": disallowed,
        "crawl_delay": delay,
        "interval_used": interval,
        "visited": visited,
        "skipped": skipped,
        "trace_file": str(TRACE),
    })
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
