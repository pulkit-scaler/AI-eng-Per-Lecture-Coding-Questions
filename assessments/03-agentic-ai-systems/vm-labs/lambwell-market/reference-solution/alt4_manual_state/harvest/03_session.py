#!/usr/bin/env python3
"""ALTERNATIVE: the session state written out by hand.

Sign in once, save the session, then reuse it in a fresh context."""
from playwright.sync_api import sync_playwright

import market_kit as kit

STATE = kit.OUT_DIR / "state.json"


def sign_in(context):
    page = context.new_page()
    page.goto("%s/login" % kit.SITE_URL)
    page.get_by_label("Username").fill(kit.LOGIN_USER)
    page.get_by_label("Password").fill(kit.LOGIN_PASSWORD)
    page.get_by_role("button", name="Sign in").click()
    page.wait_for_selector("#orderstatus", timeout=kit.SETTLE_MS)
    page.close()


def read_orders(context):
    page = context.new_page()
    page.goto("%s/orders" % kit.SITE_URL)
    page.wait_for_selector("#orders tbody tr", timeout=kit.SETTLE_MS)
    token = page.get_attribute("body", "data-token")
    orders = []
    for row in page.locator("#orders tbody tr").all():
        cells = row.locator("td").all_inner_texts()
        orders.append({"order": cells[0].strip(), "stall": cells[1].strip(),
                       "crates": int(cells[2].strip())})
    page.close()
    return token, orders


def main():
    kit.OUT_DIR.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as play:
        browser = play.chromium.launch()

        # Sign in once, in its own context, and keep what the session left
        # behind.
        first = browser.new_context()
        sign_in(first)
        # The same thing by hand: take the cookies off the context and write
        # them in the shape a context will accept back.
        import json as _json
        STATE.write_text(_json.dumps({"cookies": first.cookies(),
                                      "origins": []}))
        first.close()

        # A brand new context: no history, no cookies of its own, only the
        # saved state. If the session did not survive, /orders answers 401 and
        # the wait below fails.
        second = browser.new_context(storage_state=str(STATE))
        token, orders = read_orders(second)
        second.close()
        browser.close()

    kit.write_artifact("orders", {
        "token": token,
        "state_file": str(STATE),
        "count": len(orders),
        "order_ids": [order["order"] for order in orders],
        "orders": orders,
        "signed_in_again": False,
    })
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
