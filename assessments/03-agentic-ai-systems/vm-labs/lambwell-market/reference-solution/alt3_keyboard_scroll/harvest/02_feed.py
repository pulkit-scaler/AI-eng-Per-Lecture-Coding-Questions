#!/usr/bin/env python3
"""ALTERNATIVE: the feed scrolled from the keyboard.

Harvest the whole lot feed into out/feed.json."""
from playwright.sync_api import sync_playwright

import market_kit as kit

MAX_SCROLLS = 40


def read_lots(page):
    lots = []
    for lot in page.locator("#feed .lot").all():
        text = lot.inner_text().strip()
        parts = [part.strip() for part in text.split("|")]
        lots.append({
            "id": int(lot.get_attribute("data-id")),
            "lot": parts[0],
            "stall": parts[1],
            "weight_kg": int(parts[2].replace("kg", "")),
        })
    return lots


def harvest(page):
    page.goto("%s/feed" % kit.SITE_URL)
    page.wait_for_selector("#feed .lot", timeout=kit.SETTLE_MS)

    scrolls = 0
    seen = 0
    stop_reason = "hit the scroll limit"
    while scrolls < MAX_SCROLLS:
        page.keyboard.press("End")
        scrolls += 1
        # Either more arrive, or the page says there are none left. Both are
        # answers; a fixed number of scrolls is not.
        try:
            page.wait_for_function(
                "count => document.querySelectorAll('#feed .lot').length > count"
                " || document.body.getAttribute('data-feed') === 'exhausted'",
                arg=seen, timeout=3000)
        except Exception:
            stop_reason = "no new lots arrived after a scroll"
            break
        if page.get_attribute("body", "data-feed") == "exhausted":
            stop_reason = "the feed reported no new lots"
            break
        seen = page.locator("#feed .lot").count()

    token = page.get_attribute("body", "data-token")
    return token, read_lots(page), scrolls, stop_reason


def main():
    with sync_playwright() as play:
        browser = play.chromium.launch()
        page = browser.new_page(viewport={"width": 1280, "height": 800})
        try:
            token, lots, scrolls, stop_reason = harvest(page)
        finally:
            browser.close()

    ids = [lot["id"] for lot in lots]
    kit.write_artifact("feed", {
        "token": token,
        "count": len(lots),
        "first_id": ids[0] if ids else None,
        "last_id": ids[-1] if ids else None,
        "duplicate_ids": len(ids) - len(set(ids)),
        "monotonic": all(b > a for a, b in zip(ids, ids[1:])),
        "scrolls": scrolls,
        "stop_reason": stop_reason,
        "lots": lots,
    })
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
