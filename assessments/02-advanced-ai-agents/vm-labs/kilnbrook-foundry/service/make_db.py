#!/usr/bin/env python3
"""Create the Kilnbrook foundry operations database.

INSTRUCTOR-ONLY FILE. Run once during provisioning; the file it writes is the
learner-visible database. Every column is INTEGER or TEXT, so every value has one
unambiguous string form no matter how a solution renders it.

    python3 make_db.py /home/user/kilnbrook-foundry/data/foundry.db
"""
import os
import sqlite3
import sys

ALLOYS = [
    (1, "KB-101", "bronze", 950, 310),
    (2, "KB-104", "bronze", 985, 345),
    (3, "KB-112", "bronze", 1010, 372),
    (4, "KB-118", "bronze", 964, 298),
    (5, "KB-203", "grey_iron", 1180, 245),
    (6, "KB-207", "grey_iron", 1205, 262),
    (7, "KB-214", "grey_iron", 1168, 231),
    (8, "KB-305", "steel", 1425, 540),
    (9, "KB-311", "steel", 1462, 585),
    (10, "KB-317", "steel", 1495, 610),
    (11, "KB-402", "aluminium", 660, 190),
    (12, "KB-409", "aluminium", 672, 205),
]

MOULDS = [
    (1, "MD-01", 2, "green_sand", 180),
    (2, "MD-02", 1, "green_sand", 420),
    (3, "MD-03", 4, "resin_shell", 95),
    (4, "MD-04", 1, "resin_shell", 650),
    (5, "MD-05", 2, "co2_silicate", 310),
    (6, "MD-06", 6, "green_sand", 60),
    (7, "MD-07", 1, "co2_silicate", 880),
    (8, "MD-08", 3, "resin_shell", 140),
    (9, "MD-09", 2, "green_sand", 250),
    (10, "MD-10", 1, "co2_silicate", 520),
]

POURS = [
    (1, 1, 2, 400, "day", 18),
    (2, 3, 4, 620, "day", 31),
    (3, 10, 7, 850, "night", 44),
    (4, 5, 9, 240, "swing", 12),
    (5, 2, 1, 170, "day", 9),
    (6, 10, 10, 500, "night", 26),
    (7, 8, 4, 610, "day", 27),
    (8, 11, 3, 90, "swing", 6),
    (9, 6, 5, 300, "night", 15),
    (10, 9, 7, 870, "day", 41),
    (11, 4, 6, 55, "day", 4),
    (12, 12, 8, 135, "swing", 8),
    (13, 7, 9, 245, "night", 11),
    (14, 10, 2, 415, "day", 20),
    (15, 1, 1, 175, "swing", 10),
    (16, 3, 10, 515, "night", 25),
    (17, 8, 5, 305, "day", 14),
    (18, 2, 6, 58, "night", 5),
    (19, 9, 4, 640, "swing", 33),
    (20, 11, 8, 130, "day", 7),
]

SCHEMA = """
CREATE TABLE alloys (
    alloy_id      INTEGER PRIMARY KEY,
    alloy_code    TEXT NOT NULL,
    base_metal    TEXT NOT NULL,
    melt_point_c  INTEGER NOT NULL,
    tensile_mpa   INTEGER NOT NULL
);
CREATE TABLE moulds (
    mould_id      INTEGER PRIMARY KEY,
    mould_code    TEXT NOT NULL,
    cavity_count  INTEGER NOT NULL,
    sand_type     TEXT NOT NULL,
    max_kg        INTEGER NOT NULL
);
CREATE TABLE pours (
    pour_id       INTEGER PRIMARY KEY,
    alloy_id      INTEGER NOT NULL,
    mould_id      INTEGER NOT NULL,
    poured_kg     INTEGER NOT NULL,
    shift         TEXT NOT NULL,
    scrap_kg      INTEGER NOT NULL
);
"""


def build(path):
    parent = os.path.dirname(os.path.abspath(path))
    if parent:
        os.makedirs(parent, exist_ok=True)
    if os.path.exists(path):
        os.remove(path)
    conn = sqlite3.connect(path)
    try:
        conn.executescript(SCHEMA)
        conn.executemany("INSERT INTO alloys VALUES (?,?,?,?,?)", ALLOYS)
        conn.executemany("INSERT INTO moulds VALUES (?,?,?,?,?)", MOULDS)
        conn.executemany("INSERT INTO pours VALUES (?,?,?,?,?,?)", POURS)
        conn.commit()
        # Keep the on-disk layout in the classic rollback-journal mode: a reader
        # then never creates a sidecar file next to the database.
        conn.execute("PRAGMA journal_mode=DELETE")
        conn.execute("VACUUM")
        conn.commit()
    finally:
        conn.close()
    return path


if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else "foundry.db"
    print("wrote %s (%d alloys, %d moulds, %d pours)"
          % (build(target), len(ALLOYS), len(MOULDS), len(POURS)))
