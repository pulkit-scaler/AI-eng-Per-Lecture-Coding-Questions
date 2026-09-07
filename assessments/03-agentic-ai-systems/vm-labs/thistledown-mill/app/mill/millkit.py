"""What the mill provides.

Provided, do not modify.

    DB_PATH        the mill database
    OUT_DIR        where a planning run writes its note
    order_ids()    every order on the book
    load_order(id) the order record
    planning_llm() the planning model, already pointed at the mill
    read_only()    a read-only sqlite3 connection to the mill database
"""
import functools
import json
import os
import pathlib
import sqlite3

HERE = pathlib.Path(__file__).resolve().parent
ROOT = pathlib.Path(os.environ.get("THISTLEDOWN_ROOT", HERE.parent))

DB_PATH = pathlib.Path(os.environ.get("THISTLEDOWN_DB", ROOT / "data" / "mill.db"))
ORDERS_PATH = pathlib.Path(
    os.environ.get("THISTLEDOWN_ORDERS", ROOT / "data" / "orders.json"))
OUT_DIR = pathlib.Path(os.environ.get("THISTLEDOWN_OUT", ROOT / "out"))
CONFIG_DIR = pathlib.Path(
    os.environ.get("THISTLEDOWN_CONFIG", ROOT / "config"))

MODEL_URL = os.environ.get("THISTLEDOWN_MODEL_URL", "http://127.0.0.1:8433/v1")
MODEL_NAME = os.environ.get("THISTLEDOWN_MODEL", "openai/gpt-4o-mini")
# How many turns one agent may take before the mill stops it.
MAX_ITER = int(os.environ.get("THISTLEDOWN_MAX_ITER", "4"))
# How many rows a query may return to a planning agent.
ROW_CAP = int(os.environ.get("THISTLEDOWN_ROW_CAP", "50"))
# How long a query may run.
QUERY_TIMEOUT = float(os.environ.get("THISTLEDOWN_QUERY_TIMEOUT", "10"))


@functools.lru_cache(maxsize=1)
def _orders():
    return json.loads(ORDERS_PATH.read_text())


def order_ids():
    """Every order on the book, in wanted-date order."""
    return [o["order"] for o in _orders()["orders"]]


def load_order(order_id):
    """The order record: order, customer, cloth, metres, wanted.

    Raises KeyError when there is no such order.
    """
    for order in _orders()["orders"]:
        if order["order"] == order_id:
            return dict(order)
    raise KeyError("no order %s on the book" % order_id)


def read_only():
    """A connection that physically cannot write, whatever the statement says."""
    return sqlite3.connect("file:%s?mode=ro" % DB_PATH, uri=True,
                           timeout=QUERY_TIMEOUT)


def planning_llm():
    """The planning model, configured for the mill.

    Nothing here needs an account anywhere: the mill runs its own planning
    model on this machine, and this points at it.
    """
    from crewai import LLM

    os.environ.setdefault("OPENAI_API_KEY", "thistledown-local")
    os.environ.setdefault("OPENAI_API_BASE", MODEL_URL)
    os.environ.setdefault("OPENAI_BASE_URL", MODEL_URL)
    return LLM(model=MODEL_NAME, base_url=MODEL_URL,
               api_key=os.environ["OPENAI_API_KEY"], temperature=0)
