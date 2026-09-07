"""Create the mill database. Run once by provisioning; not part of the lab."""
import pathlib
import sqlite3
import sys

YARN = [
    ("YN-WL14", "worsted wool 2/48", 26, 40, "A-11"),
    ("YN-CT08", "combed cotton 60s", 51, 30, "A-12"),
    ("YN-LN22", "wet-spun linen 40s", 9, 45, "B-03"),
    ("YN-SK03", "silk noil singles", 4, 60, "B-04"),
    ("YN-WL27", "lambswool 2/28", 18, 35, "A-14"),
    ("YN-CT19", "carded cotton 20s", 74, 25, "A-15"),
]
CLOTH = [
    ("worsted suiting", "YN-WL14", 1.15),
    ("poplin shirting", "YN-CT08", 1.05),
    ("linen twill", "YN-LN22", 1.20),
    ("silk noil", "YN-SK03", 1.10),
    ("cadet serge", "YN-ZZ99", 1.25),
    ("flannel", "YN-WL27", 1.18),
]
LOOMS = [
    ("L-01", "Dornier rapier", 1, "worsted suiting"),
    ("L-02", "Dornier rapier", 1, "poplin shirting"),
    ("L-03", "Sulzer projectile", 0, "linen twill"),
    ("L-04", "Somet air-jet", 1, "poplin shirting"),
    ("L-05", "hand dobby", 1, "silk noil"),
]


def main(path):
    target = pathlib.Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        target.unlink()
    con = sqlite3.connect(target)
    con.executescript(
        """
        CREATE TABLE yarn_stock (
            yarn_code TEXT PRIMARY KEY,
            description TEXT NOT NULL,
            cones_on_hand INTEGER NOT NULL,
            metres_per_cone INTEGER NOT NULL,
            bin TEXT NOT NULL
        );
        CREATE TABLE cloth_spec (
            cloth TEXT PRIMARY KEY,
            yarn_code TEXT NOT NULL,
            metres_of_yarn_per_metre_of_cloth REAL NOT NULL
        );
        CREATE TABLE looms (
            loom TEXT PRIMARY KEY,
            machine TEXT NOT NULL,
            available INTEGER NOT NULL,
            set_for TEXT NOT NULL
        );
        """
    )
    con.executemany("INSERT INTO yarn_stock VALUES (?,?,?,?,?)", YARN)
    con.executemany("INSERT INTO cloth_spec VALUES (?,?,?)", CLOTH)
    con.executemany("INSERT INTO looms VALUES (?,?,?,?)", LOOMS)
    con.commit()
    con.close()
    print("built %s with %d yarns, %d cloths, %d looms"
          % (target, len(YARN), len(CLOTH), len(LOOMS)))


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "data/mill.db")
