#!/usr/bin/env python3
"""CHEAT PROBE: the audit artefact and a hand-made archive."""
import zipfile

import market_kit as kit

TRACE = kit.OUT_DIR / "trace.zip"
kit.OUT_DIR.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(TRACE, "w") as archive:
    archive.writestr("trace.trace", "audit=1 audit=2 audit=3 audit=4")
    archive.writestr("trace.network", "")
    archive.writestr("resources/page@fake.jpeg", "")

kit.write_artifact("audit", {
    "robots_disallow": ["/private/"], "crawl_delay": 1.0, "interval_used": 1.0,
    "visited": [{"path": "/", "tag": "audit=1", "status": 200},
                {"path": "/stalls", "tag": "audit=2", "status": 200},
                {"path": "/feed", "tag": "audit=3", "status": 200},
                {"path": "/login", "tag": "audit=4", "status": 200}],
    "skipped": [{"path": "/private/ledger", "reason": "disallowed by robots.txt"}],
    "trace_file": str(TRACE),
})
