#!/usr/bin/env python3
"""Harvest the stall register into out/listings.json."""
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

    stalls = []
    for row in page.locator("#stalls tbody tr").all():
        cells = row.locator("td").all_inner_texts()
        stalls.append({
            "stall": cells[0].strip(),
            "trader": cells[1].strip(),
            "goods": cells[2].strip(),
            "since": int(cells[3].strip()),
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
