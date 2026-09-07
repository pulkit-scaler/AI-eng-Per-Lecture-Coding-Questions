"""Where the market is, and where a harvest writes what it found.

Provided, do not modify.
"""
import json
import os
import pathlib

SITE_URL = os.environ.get("LAMBWELL_SITE_URL", "http://127.0.0.1:8711")
ROOT = pathlib.Path(os.environ.get("LAMBWELL_ROOT",
                                  pathlib.Path(__file__).resolve().parent.parent))
OUT_DIR = pathlib.Path(os.environ.get("LAMBWELL_OUT", ROOT / "out"))

# The trader credentials the market publishes for its own test account.
LOGIN_USER = "harvester"
LOGIN_PASSWORD = "market-day"

# The shortest gap the market asks for between two requests, in seconds. It says
# so in robots.txt as well; this is the same number.
MIN_INTERVAL = 1.0

# How long to allow one page to settle before giving up on it, in milliseconds.
SETTLE_MS = 8000


def artifact_path(name):
    """Where an artefact of this name belongs."""
    return OUT_DIR / ("%s.json" % name)


def write_artifact(name, payload):
    """Write one artefact and return where it went."""
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    path = artifact_path(name)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")
    print("wrote %s" % path)
    return path


def read_artifact(name):
    """Read an artefact an earlier step wrote."""
    return json.loads(artifact_path(name).read_text())
