"""Marlow Depot parts adviser.

    GET  /health    is the service up, and how big is the index it loaded
    GET  /whoami    which user the process runs as, and which credential it got
    POST /match     {"need": "..."} -> the part that answers it, plus a note

Everything is read from the environment, never hardcoded:

    DEPOT_INDEX_DIR   where the index lives      (default /index)
    DEPOT_LLM_URL     adviser backend base URL   (default http://llm:9000/v1)
    DEPOT_API_KEY     credential for the backend (must be supplied at run time)
    DEPOT_PORT        port to listen on          (default 8000)
"""

import hashlib
import json
import os
import pathlib
import sys

INDEX_DIR = pathlib.Path(os.environ.get("DEPOT_INDEX_DIR", "/index"))
MANIFEST = INDEX_DIR / "manifest.json"

# Checked before anything heavy is imported, so a container started ahead of
# the index build fails immediately and loudly instead of serving an empty
# catalogue.
if not MANIFEST.is_file():
    sys.stderr.write(
        "depot-api: no part index at %s - the index build has to finish "
        "before this service starts\n" % MANIFEST)
    raise SystemExit(3)

import getpass  # noqa: E402

import httpx  # noqa: E402
import pandas as pd  # noqa: E402
from fastapi import FastAPI  # noqa: E402
from pydantic import BaseModel  # noqa: E402

import depot_hash  # noqa: E402
import matching  # noqa: E402

VERSION = pathlib.Path(
    os.environ.get("DEPOT_VERSION_FILE", "version.txt")).read_text().strip()
LLM_URL = os.environ.get("DEPOT_LLM_URL", "http://llm:9000/v1")
API_KEY = os.environ.get("DEPOT_API_KEY", "")

MANIFEST_DATA = json.loads(MANIFEST.read_text())
PARTS_FRAME = pd.read_csv(INDEX_DIR / "parts_index.csv")
PARTS = [
    {
        "part_no": row["part_no"],
        "name": row["name"],
        "bin": row["bin"],
        "stock": int(row["stock"]),
        "price": float(row["price"]),
        "keywords": str(row["keywords"]).split(),
    }
    for row in PARTS_FRAME.to_dict("records")
]

ADVISER_SYSTEM = "You are the Marlow Depot parts adviser. Reply with one short line."

app = FastAPI(title="Marlow Depot parts adviser", version=VERSION)


class MatchRequest(BaseModel):
    need: str


def whoami_name():
    try:
        return getpass.getuser()
    except Exception:
        return "uid-%d" % os.getuid()


def key_fingerprint():
    if not API_KEY:
        return None
    return hashlib.sha256(API_KEY.encode("utf-8")).hexdigest()[:12]


def ask_adviser(need, part):
    prompt = ("Need: %s\nPart: %s %s\nBin: %s\nOn hand: %d"
              % (need, part["part_no"], part["name"], part["bin"],
                 part["stock"]))
    headers = {"Authorization": "Bearer %s" % (API_KEY or "none")}
    body = {
        "model": "depot-adviser",
        "messages": [
            {"role": "system", "content": ADVISER_SYSTEM},
            {"role": "user", "content": prompt},
        ],
    }
    reply = httpx.post("%s/chat/completions" % LLM_URL.rstrip("/"),
                       json=body, headers=headers, timeout=10.0)
    reply.raise_for_status()
    return reply.json()["choices"][0]["message"]["content"].strip()


@app.get("/health")
def health():
    return {
        "status": "ok",
        "version": VERSION,
        "indexed_parts": len(PARTS),
        "indexed_tokens": MANIFEST_DATA.get("tokens", 0),
        "catalog_fp": MANIFEST_DATA.get("catalog_fp"),
    }


@app.get("/whoami")
def whoami():
    return {
        "version": VERSION,
        "uid": os.getuid(),
        "user": whoami_name(),
        "key_fp": key_fingerprint(),
        "hash_fp": depot_hash.fingerprint(VERSION),
        "llm_url": LLM_URL,
    }


@app.post("/match")
def match(request: MatchRequest):
    part, score = matching.best_match(request.need, PARTS)
    if part is None:
        return {"part_no": None, "score": 0, "note": None,
                "need": request.need}
    note = ask_adviser(request.need, part)
    return {
        "part_no": part["part_no"],
        "name": part["name"],
        "bin": part["bin"],
        "stock": part["stock"],
        "score": score,
        "note": note,
        "need": request.need,
    }
