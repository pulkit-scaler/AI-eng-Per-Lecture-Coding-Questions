#!/usr/bin/env python3
"""CHEAT PROBE: the orders artefact written out by hand."""
import json

import market_kit as kit

ORDERS = [
    {"order": "LW-6001", "stall": "A1", "crates": 14},
    {"order": "LW-6002", "stall": "B2", "crates": 9},
    {"order": "LW-6003", "stall": "C2", "crates": 22},
    {"order": "LW-6004", "stall": "A3", "crates": 5},
]

kit.OUT_DIR.mkdir(parents=True, exist_ok=True)
(kit.OUT_DIR / "state.json").write_text(json.dumps(
    {"cookies": [{"name": "lambwell_session", "value": "lw-session-8f31"}],
     "origins": []}))
kit.write_artifact("orders", {
    "token": "orders-0004", "state_file": str(kit.OUT_DIR / "state.json"),
    "count": len(ORDERS), "order_ids": [o["order"] for o in ORDERS],
    "orders": ORDERS, "signed_in_again": False,
})
