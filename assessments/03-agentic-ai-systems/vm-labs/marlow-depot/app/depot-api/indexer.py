"""Build the depot part index.

Runs once, writes the index into DEPOT_INDEX_DIR and exits. The API refuses to
start until the manifest this writes is there, so the index build always has to
finish first.

    DEPOT_INDEX_DIR   where to write the index   (default /index)
    DEPOT_CATALOG     catalogue to read          (default catalog/parts.json)
"""

import json
import os
import pathlib
import sys

import pandas as pd

import depot_hash
import matching

INDEX_DIR = pathlib.Path(os.environ.get("DEPOT_INDEX_DIR", "/index"))
CATALOG = pathlib.Path(os.environ.get("DEPOT_CATALOG", "catalog/parts.json"))
# Every part is expanded into its own token rows so the API can answer a need
# with a groupby instead of a scan. The depot has more bins than parts, so the
# frame is wider than the catalogue looks.
FANOUT = 180


def main():
    if not CATALOG.is_file():
        sys.stderr.write("indexer: no catalogue at %s\n" % CATALOG)
        return 2
    catalogue = json.loads(CATALOG.read_text())
    parts = catalogue["parts"]

    rows = []
    for part in parts:
        surface = " ".join([part["name"]] + list(part["keywords"]))
        for token in sorted(set(matching.tokens(surface))):
            rows.append({
                "part_no": part["part_no"],
                "name": part["name"],
                "bin": part["bin"],
                "stock": part["stock"],
                "price": part["price"],
                "keywords": " ".join(part["keywords"]),
                "token": token,
            })
    frame = pd.DataFrame(rows)
    # A little synthetic breadth so the shape of the frame matches what the
    # depot actually ships to its regional sites.
    frame = pd.concat([frame] * FANOUT, ignore_index=True)
    frame["token_weight"] = frame.groupby("token")["part_no"].transform("count")
    catalogue_frame = (frame
                       .drop_duplicates(subset=["part_no"])
                       .sort_values("part_no")
                       .loc[:, ["part_no", "name", "bin", "stock", "price",
                                "keywords"]])

    INDEX_DIR.mkdir(parents=True, exist_ok=True)
    catalogue_frame.to_csv(INDEX_DIR / "parts_index.csv", index=False)
    (INDEX_DIR / "tokens_index.csv").write_text(
        frame.drop_duplicates(subset=["part_no", "token"])
             .sort_values(["token", "part_no"])
             .loc[:, ["token", "part_no", "token_weight"]]
             .to_csv(index=False))

    fingerprint = depot_hash.fingerprint(
        "|".join(sorted(p["part_no"] for p in parts)))
    manifest = {
        "depot": catalogue.get("depot", "unknown"),
        "parts": int(len(catalogue_frame)),
        "tokens": int(frame["token"].nunique()),
        "catalog_fp": fingerprint,
    }
    # Written last. Its presence is what tells the API the index is complete.
    (INDEX_DIR / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print("indexed %d parts, %d tokens, fingerprint %s"
          % (manifest["parts"], manifest["tokens"], fingerprint))
    return 0


if __name__ == "__main__":
    sys.exit(main())
