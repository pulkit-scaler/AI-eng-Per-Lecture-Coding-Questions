"""Kilnbrook Foundry toolkit.

Provided, do not modify.

Exports the three pieces your agent is built on:

    make_client()  - a configured client for the local model endpoint
    connect()      - a sqlite3 connection to the foundry operations database
    PERSONA        - the analyst persona your system prompt is rendered from
"""
from .client import ENDPOINT, MODEL_NAME, make_client
from .db import DB_PATH, connect
from .persona import PERSONA

__all__ = [
    "ENDPOINT",
    "MODEL_NAME",
    "make_client",
    "DB_PATH",
    "connect",
    "PERSONA",
]
