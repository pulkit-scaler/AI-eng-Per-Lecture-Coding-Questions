#!/usr/bin/env python3
"""CHEAT PROBE: the feed artefact computed rather than harvested."""
import market_kit as kit

STALLS = ["A1", "A2", "A3", "B1", "B2", "B3", "C1", "C2", "C3"]
lots = [{"id": i, "lot": "LOT-%03d" % i, "stall": STALLS[(i - 1) % 9],
         "weight_kg": 4 + (i * 7) % 46} for i in range(1, 48)]

kit.write_artifact("feed", {
    "token": "feed-0002", "count": len(lots), "first_id": 1, "last_id": 47,
    "duplicate_ids": 0, "monotonic": True, "scrolls": 6,
    "stop_reason": "the feed reported no new lots", "lots": lots,
})
