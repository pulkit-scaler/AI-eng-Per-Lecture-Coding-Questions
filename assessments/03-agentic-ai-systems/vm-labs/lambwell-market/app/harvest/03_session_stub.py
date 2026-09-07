#!/usr/bin/env python3
"""Harvest the standing orders into out/orders.json, reusing one sign-in.

YOU WRITE THIS FILE.

    python3 harvest/03_session.py

What the artefact has to contain is in the problem statement. What you have:

    import market_kit as kit

    kit.SITE_URL              where the market is
    kit.SETTLE_MS             how long to allow one page to settle
    kit.write_artifact(name, payload)
    kit.LOGIN_USER, kit.LOGIN_PASSWORD   the published trader test account
    kit.OUT_DIR               where out/state.json belongs

Use the sync Playwright API - these are standalone scripts, not notebook cells:

    from playwright.sync_api import sync_playwright
"""
import market_kit as kit  # noqa: F401


def main():
    raise NotImplementedError("the session harvest is not written yet")


if __name__ == "__main__":
    raise SystemExit(main())
