#!/usr/bin/env python3
"""ALTERNATIVE: the async Playwright API.

Harvest the stall register into out/listings.json.
"""
import asyncio

from playwright.async_api import async_playwright

import market_kit as kit


async def harvest(page):
    await page.goto("%s/stalls" % kit.SITE_URL)
    await page.wait_for_selector("#stalls[data-complete='yes']",
                                 timeout=kit.SETTLE_MS)
    token = await page.get_attribute("body", "data-token")
    stalls = []
    rows = await page.locator("#stalls tbody tr").all()
    for row in rows:
        cells = await row.locator("td").all_inner_texts()
        stalls.append({"stall": cells[0].strip(), "trader": cells[1].strip(),
                       "goods": cells[2].strip(), "since": int(cells[3].strip())})
    return token, stalls


async def run():
    async with async_playwright() as play:
        browser = await play.chromium.launch()
        page = await browser.new_page()
        try:
            token, stalls = await harvest(page)
        finally:
            await browser.close()
    kit.write_artifact("listings", {"token": token, "count": len(stalls),
                                    "stalls": stalls})


if __name__ == "__main__":
    asyncio.run(run())
