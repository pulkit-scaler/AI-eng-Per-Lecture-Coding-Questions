"""The foundry operations database.

Provided, do not modify.
"""
import os
import sqlite3

_HERE = os.path.dirname(os.path.abspath(__file__))
_DEFAULT = os.path.join(os.path.dirname(_HERE), "data", "foundry.db")

# Absolute path of the SQLite file holding the foundry operations data.
DB_PATH = os.environ.get("KILN_DB", _DEFAULT)


def connect():
    """Open the foundry operations database.

    Returns:
        sqlite3.Connection: a connection to ``DB_PATH``. Close it when you are
        finished with it, or use it as a context manager.
    """
    return sqlite3.connect(DB_PATH)
