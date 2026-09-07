"""The Larkspur operations database: where it lives and how to open it.

Provided, do not modify.

Every read of the operations database goes through :func:`connect`. The path
comes from the ``LARKSPUR_DB`` environment variable when it is set, and
otherwise from the copy bundled with the project, so the same code works
wherever the database is mounted.
"""
import os
import pathlib
import sqlite3

_BUNDLED = pathlib.Path(__file__).resolve().parent.parent / "data" / "transit.db"

DB_PATH = str(pathlib.Path(os.environ.get("LARKSPUR_DB") or _BUNDLED))


def connect() -> sqlite3.Connection:
    """Return a new connection to the operations database.

    A fresh connection per call keeps state, threading and connection lifetime
    simple. Raises :class:`FileNotFoundError` with the path when the database is
    not where it is expected to be.
    """
    if not pathlib.Path(DB_PATH).exists():
        raise FileNotFoundError(
            "operations database not found at %s - set LARKSPUR_DB or restore "
            "the bundled copy" % DB_PATH
        )
    return sqlite3.connect(DB_PATH)
