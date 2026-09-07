#!/usr/bin/env python3
"""ALTERNATIVE: rows located by attribute, cells read with nth().

Harvest the stall register into out/listings.json."""
from playwright.sync_api import sync_playwright

import market_kit as kit


def harvest(page):
    page.goto("%s/stalls" % kit.SITE_URL)
    # The table fills in a row at a time. Waiting for the marker the page sets
    # when it has finished is what makes this reliable - a fixed sleep is a
    # guess about somebody else's timing.
    page.wait_for_selector("#stalls[data-complete='yes']",
                           timeout=kit.SETTLE_MS)
    token = page.get_attribute("body", "data-token")

    # Rows found by the attribute the page puts on them, and each cell read
    # through nth() rather than by unpacking a list of texts.
    stalls = []
    rows = page.locator("#stalls tbody tr[data-stall]")
    for index in range(rows.count()):
        row = rows.nth(index)
        cells = row.locator("td")
        stalls.append({
            "stall": cells.nth(0).inner_text().strip(),
            "trader": cells.nth(1).inner_text().strip(),
            "goods": cells.nth(2).inner_text().strip(),
            "since": int(cells.nth(3).inner_text().strip()),
        })
    return token, stalls


def main():
    with sync_playwright() as play:
        browser = play.chromium.launch()
        page = browser.new_page()
        try:
            token, stalls = harvest(page)
        finally:
            browser.close()

    kit.write_artifact("listings", {
        "token": token,
        "count": len(stalls),
        "stalls": stalls,
    })
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
