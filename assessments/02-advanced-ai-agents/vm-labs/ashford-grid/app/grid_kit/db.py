"""Connection to the grid operations database.

Provided, do not modify.

The database is a SQLite file holding the Ashford network register: substations,
feeders, outages and load readings. It is opened **read-only**, so a statement
that would change data fails rather than doing damage.
"""
import os
import sqlite3

DB_PATH = os.environ.get(
    "ASHFORD_DB", "/home/user/ashford-grid/data/grid_ops.db")


def connect():
    """Open a read-only connection to the grid operations database."""
    return sqlite3.connect("file:%s?mode=ro" % DB_PATH, uri=True)
