#!/usr/bin/env python3
"""Build the Ashford grid-operations SQLite database.

INSTRUCTOR-ONLY FILE. Installed to /opt/ashford-svc (root:root, 0700) and run once
during provisioning. The database it writes is the only artefact the learner sees.

Every row is a literal below, so the file is byte-identical on every VM and every
aggregate the checks rely on is hand-verifiable.

Usage:  python3 seed_db.py <path-to-db>
"""
import os
import sqlite3
import sys

SCHEMA = """
CREATE TABLE substations (
    substation_id     INTEGER PRIMARY KEY,
    name              TEXT    NOT NULL,
    region            TEXT    NOT NULL,
    voltage_kv        INTEGER NOT NULL,
    commissioned_year INTEGER NOT NULL
);
CREATE TABLE feeders (
    feeder_id     INTEGER PRIMARY KEY,
    substation_id INTEGER NOT NULL,
    feeder_code   TEXT    NOT NULL,
    capacity_mw   REAL    NOT NULL,
    status        TEXT    NOT NULL
);
CREATE TABLE outages (
    outage_id          INTEGER PRIMARY KEY,
    feeder_id          INTEGER NOT NULL,
    cause              TEXT    NOT NULL,
    started_at         TEXT    NOT NULL,
    duration_min       INTEGER NOT NULL,
    customers_affected INTEGER NOT NULL
);
CREATE TABLE load_readings (
    reading_id INTEGER PRIMARY KEY,
    feeder_id  INTEGER NOT NULL,
    taken_at   TEXT    NOT NULL,
    load_mw    REAL    NOT NULL
);
"""

SUBSTATIONS = [
    (1, "Ashford Central", "North", 132, 1998),
    (2, "Kelvin Row", "North", 66, 2004),
    (3, "Marlow Bridge", "East", 132, 1987),
    (4, "Dunhaven", "East", 33, 2011),
    (5, "Peverel Hill", "South", 66, 1995),
    (6, "Tarrant Quay", "South", 132, 2016),
    (7, "Bexley Fen", "West", 33, 2002),
    (8, "Ockham Vale", "West", 66, 2019),
]

FEEDERS = [
    (1, 1, "ASH-F1", 24.5, "active"),
    (2, 1, "ASH-F2", 18.0, "active"),
    (3, 1, "ASH-F3", 12.5, "maintenance"),
    (4, 2, "KEL-F1", 15.0, "active"),
    (5, 2, "KEL-F2", 9.5, "active"),
    (6, 3, "MAR-F1", 27.0, "active"),
    (7, 3, "MAR-F2", 21.5, "retired"),
    (8, 4, "DUN-F1", 8.0, "active"),
    (9, 5, "PEV-F1", 16.5, "active"),
    (10, 5, "PEV-F2", 11.0, "maintenance"),
    (11, 6, "TAR-F1", 30.0, "active"),
    (12, 6, "TAR-F2", 25.5, "active"),
    (13, 7, "BEX-F1", 7.5, "active"),
    (14, 8, "OCK-F1", 19.0, "active"),
]

OUTAGES = [
    (1, 1, "storm", "2026-01-04 09:12", 145, 2400),
    (2, 2, "equipment", "2026-01-11 22:40", 85, 940),
    (3, 4, "storm", "2026-01-18 05:05", 210, 3180),
    (4, 6, "vegetation", "2026-02-02 14:30", 60, 510),
    (5, 9, "equipment", "2026-02-09 03:55", 125, 1650),
    (6, 11, "storm", "2026-02-14 18:20", 330, 5120),
    (7, 1, "vegetation", "2026-02-21 11:00", 45, 380),
    (8, 12, "equipment", "2026-03-01 07:45", 150, 1980),
    (9, 5, "animal", "2026-03-06 16:10", 30, 210),
    (10, 8, "storm", "2026-03-12 20:35", 275, 2760),
    (11, 6, "equipment", "2026-03-19 09:50", 95, 1120),
    (12, 13, "vegetation", "2026-03-25 13:15", 70, 640),
    (13, 14, "storm", "2026-04-02 04:20", 190, 2050),
    (14, 2, "animal", "2026-04-08 19:05", 25, 170),
    (15, 11, "vegetation", "2026-04-15 12:40", 110, 1340),
    (16, 4, "equipment", "2026-04-22 06:30", 165, 1870),
    (17, 9, "storm", "2026-04-29 23:55", 240, 2980),
    (18, 12, "animal", "2026-05-05 08:25", 35, 290),
]

LOAD_READINGS = [
    (1, 1, "2026-05-01 08:00", 18.2),
    (2, 1, "2026-05-01 12:00", 22.4),
    (3, 1, "2026-05-01 18:00", 20.1),
    (4, 2, "2026-05-01 08:00", 14.0),
    (5, 2, "2026-05-01 12:00", 16.5),
    (6, 2, "2026-05-01 18:00", 15.2),
    (7, 4, "2026-05-01 08:00", 11.5),
    (8, 4, "2026-05-01 12:00", 13.8),
    (9, 4, "2026-05-01 18:00", 12.9),
    (10, 6, "2026-05-01 08:00", 22.0),
    (11, 6, "2026-05-01 12:00", 25.6),
    (12, 6, "2026-05-01 18:00", 24.1),
    (13, 9, "2026-05-01 08:00", 12.4),
    (14, 9, "2026-05-01 12:00", 15.0),
    (15, 9, "2026-05-01 18:00", 13.7),
    (16, 11, "2026-05-01 08:00", 26.5),
    (17, 11, "2026-05-01 12:00", 29.2),
    (18, 11, "2026-05-01 18:00", 27.8),
    (19, 12, "2026-05-01 08:00", 20.0),
    (20, 12, "2026-05-01 12:00", 23.4),
    (21, 12, "2026-05-01 18:00", 21.9),
    (22, 14, "2026-05-01 08:00", 15.5),
    (23, 14, "2026-05-01 12:00", 17.8),
    (24, 14, "2026-05-01 18:00", 16.4),
]


def build(path):
    parent = os.path.dirname(os.path.abspath(path))
    if parent:
        os.makedirs(parent, exist_ok=True)
    if os.path.exists(path):
        os.remove(path)
    conn = sqlite3.connect(path)
    try:
        conn.executescript(SCHEMA)
        conn.executemany("INSERT INTO substations VALUES (?,?,?,?,?)", SUBSTATIONS)
        conn.executemany("INSERT INTO feeders VALUES (?,?,?,?,?)", FEEDERS)
        conn.executemany("INSERT INTO outages VALUES (?,?,?,?,?,?)", OUTAGES)
        conn.executemany("INSERT INTO load_readings VALUES (?,?,?,?)", LOAD_READINGS)
        conn.commit()
    finally:
        conn.close()
    return path


if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else "grid_ops.db"
    build(target)
    print("wrote %s" % target)
