#!/usr/bin/env python3
"""Build the Larkspur Transit operations database.

Run as:  python3 seed_db.py /path/to/transit.db

Standard library only. Rebuilds the file from scratch every time, so it is safe
to re-run. Twelve routes, sixteen vehicles and twenty-four trips - small enough
that every answer can be checked by hand.
"""
import pathlib
import sqlite3
import sys

ROUTES = [
    (1, "L1", "Larkspur Loop", "tram", "central", 8.4),
    (2, "L4", "Foundry Line", "tram", "central", 11.2),
    (3, "L7", "Riverside Link", "tram", "north", 6.9),
    (4, "B12", "Ashgrove Express", "bus", "north", 14.5),
    (5, "B18", "Kingsmere Shuttle", "bus", "east", 9.3),
    (6, "B22", "Harbour Circular", "bus", "south", 12.8),
    (7, "B31", "Quarry Road", "bus", "west", 17.6),
    (8, "M2", "Metro Cross-City", "metro", "central", 21.4),
    (9, "M5", "Northgate Metro", "metro", "north", 18.9),
    (10, "F1", "Harbour Ferry", "ferry", "south", 4.2),
    (11, "T3", "Hillcrest Trolley", "trolley", "west", 5.5),
    (12, "B44", "Eastfield Relief", "bus", "east", 10.1),
]

VEHICLES = [
    (1, "V-101", "Ashgrove", "Skyline-200", 72, 1),
    (2, "V-102", "Ashgrove", "Skyline-200", 72, 1),
    (3, "V-103", "Ashgrove", "Skyline-300", 96, 1),
    (4, "V-104", "Ashgrove", "Corvid-40", 44, 0),
    (5, "V-105", "Ashgrove", "Corvid-40", 44, 1),
    (6, "V-201", "Kingsmere", "Skyline-300", 96, 1),
    (7, "V-202", "Kingsmere", "Skyline-300", 96, 1),
    (8, "V-203", "Kingsmere", "Corvid-40", 44, 1),
    (9, "V-204", "Kingsmere", "Halton-90", 88, 1),
    (10, "V-205", "Kingsmere", "Halton-90", 88, 0),
    (11, "V-206", "Kingsmere", "Halton-90", 88, 1),
    (12, "V-301", "Harbourside", "Estuary-12", 30, 1),
    (13, "V-302", "Harbourside", "Estuary-12", 30, 1),
    (14, "V-303", "Harbourside", "Skyline-200", 72, 1),
    (15, "V-304", "Harbourside", "Corvid-40", 44, 1),
    (16, "V-305", "Harbourside", "Halton-90", 88, 0),
]

TRIPS = [
    (1, "L1", "V-101", "2026-03-02", 410, 1.5),
    (2, "L1", "V-102", "2026-03-02", 388, 0.0),
    (3, "L1", "V-103", "2026-03-03", 455, 2.5),
    (4, "L4", "V-201", "2026-03-02", 372, 3.0),
    (5, "L4", "V-202", "2026-03-03", 341, 1.0),
    (6, "L7", "V-303", "2026-03-02", 198, 0.5),
    (7, "B12", "V-104", "2026-03-02", 254, 4.5),
    (8, "B12", "V-105", "2026-03-03", 231, 2.0),
    (9, "B18", "V-203", "2026-03-02", 176, 0.0),
    (10, "B22", "V-301", "2026-03-02", 143, 1.5),
    (11, "B22", "V-302", "2026-03-03", 158, 3.5),
    (12, "B31", "V-204", "2026-03-02", 121, 6.0),
    (13, "M2", "V-206", "2026-03-02", 612, 1.0),
    (14, "M2", "V-206", "2026-03-03", 587, 0.5),
    (15, "M2", "V-205", "2026-03-04", 640, 2.0),
    (16, "M5", "V-304", "2026-03-02", 305, 1.5),
    (17, "M5", "V-305", "2026-03-03", 288, 0.0),
    (18, "F1", "V-302", "2026-03-04", 96, 0.0),
    (19, "T3", "V-103", "2026-03-04", 134, 2.5),
    (20, "B44", "V-105", "2026-03-04", 167, 1.0),
    (21, "L1", "V-101", "2026-03-04", 402, 0.5),
    (22, "L4", "V-202", "2026-03-04", 359, 4.0),
    (23, "B12", "V-104", "2026-03-04", 240, 3.0),
    (24, "M2", "V-201", "2026-03-05", 598, 1.5),
]

SCHEMA = """
CREATE TABLE routes (
    route_id   INTEGER PRIMARY KEY,
    code       TEXT    NOT NULL,
    name       TEXT    NOT NULL,
    mode       TEXT    NOT NULL,
    zone       TEXT    NOT NULL,
    length_km  REAL    NOT NULL
);
CREATE TABLE vehicles (
    vehicle_id INTEGER PRIMARY KEY,
    fleet_no   TEXT    NOT NULL,
    depot      TEXT    NOT NULL,
    model      TEXT    NOT NULL,
    capacity   INTEGER NOT NULL,
    in_service INTEGER NOT NULL
);
CREATE TABLE trips (
    trip_id     INTEGER PRIMARY KEY,
    route_code  TEXT    NOT NULL,
    fleet_no    TEXT    NOT NULL,
    service_day TEXT    NOT NULL,
    boardings   INTEGER NOT NULL,
    delay_min   REAL    NOT NULL,
    FOREIGN KEY (route_code) REFERENCES routes(code)
);
"""


def build(path):
    target = pathlib.Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        target.unlink()
    conn = sqlite3.connect(str(target))
    try:
        conn.executescript(SCHEMA)
        conn.executemany("INSERT INTO routes VALUES (?, ?, ?, ?, ?, ?)", ROUTES)
        conn.executemany("INSERT INTO vehicles VALUES (?, ?, ?, ?, ?, ?)", VEHICLES)
        conn.executemany("INSERT INTO trips VALUES (?, ?, ?, ?, ?, ?)", TRIPS)
        conn.commit()
    finally:
        conn.close()
    return len(ROUTES), len(VEHICLES), len(TRIPS)


if __name__ == "__main__":
    where = sys.argv[1] if len(sys.argv) > 1 else "data/transit.db"
    counts = build(where)
    print("built %s: routes=%d vehicles=%d trips=%d" % ((where,) + counts))
