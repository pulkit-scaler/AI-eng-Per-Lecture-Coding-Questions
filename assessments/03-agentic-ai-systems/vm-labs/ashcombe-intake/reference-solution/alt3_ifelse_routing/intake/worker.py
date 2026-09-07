#!/usr/bin/env python3
"""Stage 3: drain the spool.

One document failing is not the pipeline failing. Every document is attempted,
every failure is recorded with its reason, and work already done is not paid
for twice.
"""
import argparse
import hashlib
import json
import os
import sys

from intake_kit import DeskError, parse_document

from .chunk import layout_aware_chunks
from .triage import classify

# Which strategy each flavor needs. The cheap one where it is enough, the
# expensive one only where the text layer is missing.
def strategy_for(flavor):
    """The strategy a document of this flavor should be parsed with."""
    if flavor == "digital":
        return "fast"
    if flavor == "scanned":
        return "ocr_only"
    return "hi_res"


def digest_of(path):
    hasher = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(65536), b""):
            hasher.update(block)
    return hasher.hexdigest()


def already_done(ledger_path):
    """Every document hash the ledger already holds a successful row for."""
    seen = set()
    if not os.path.exists(ledger_path):
        return seen
    with open(ledger_path) as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except ValueError:
                continue
            if row.get("status") == "ok" and row.get("sha256"):
                seen.add(row["sha256"])
    return seen


def append_row(ledger_path, row):
    directory = os.path.dirname(ledger_path)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(ledger_path, "a") as handle:
        handle.write(json.dumps(row, sort_keys=True) + "\n")


def process(path, out_dir, ledger_path):
    """Take one document as far as it will go. Returns the ledger row."""
    name = os.path.basename(path)
    row = {"source": name, "status": "failed", "reason": "", "sha256": None,
           "flavor": None, "strategy": None, "pages": 0, "elements": 0,
           "chunks": 0}
    try:
        row["sha256"] = digest_of(path)
    except OSError as exc:
        row["reason"] = "could not read the file: %s" % exc
        return row

    try:
        triage = classify(path)
    except Exception as exc:
        # A document PyMuPDF cannot open is a bad document, not a bad run.
        row["reason"] = "could not be opened: %s: %s" % (type(exc).__name__,
                                                         exc)
        return row

    row["flavor"] = triage["flavor"]
    row["pages"] = triage["pages"]
    strategy = strategy_for(triage["flavor"])
    row["strategy"] = strategy

    try:
        parsed = parse_document(path, strategy)
    except DeskError as exc:
        row["reason"] = "the intake API could not parse it: %s" % exc
        return row
    except Exception as exc:
        row["reason"] = "parsing failed: %s: %s" % (type(exc).__name__, exc)
        return row

    elements = parsed.get("elements") or []
    chunks = layout_aware_chunks(elements, name)
    row["elements"] = len(elements)
    row["chunks"] = len(chunks)
    row["status"] = "ok"

    os.makedirs(out_dir, exist_ok=True)
    target = os.path.join(out_dir, os.path.splitext(name)[0] + ".json")
    with open(target, "w") as handle:
        json.dump({
            "source": name,
            "sha256": row["sha256"],
            "flavor": row["flavor"],
            "strategy": strategy,
            "pages": parsed.get("pages", row["pages"]),
            "elements": elements,
            "chunks": chunks,
        }, handle, indent=2)
    return row


def drain(inbox, out_dir, ledger_path):
    seen = already_done(ledger_path)
    summary = {"processed": 0, "skipped": 0, "failed": 0}
    if not os.path.isdir(inbox):
        return summary

    for name in sorted(os.listdir(inbox)):
        path = os.path.join(inbox, name)
        if not os.path.isfile(path):
            continue
        try:
            digest = digest_of(path)
        except OSError:
            digest = None
        if digest and digest in seen:
            # The same bytes under a different name is still the same document.
            summary["skipped"] += 1
            continue
        row = process(path, out_dir, ledger_path)
        append_row(ledger_path, row)
        if row["status"] == "ok":
            summary["processed"] += 1
            if row["sha256"]:
                seen.add(row["sha256"])
        else:
            summary["failed"] += 1
    return summary


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--inbox", default="inbox")
    parser.add_argument("--out", default="out")
    parser.add_argument("--ledger", default="ledger.jsonl")
    parser.add_argument("--once", action="store_true")
    options = parser.parse_args(argv)

    summary = drain(options.inbox, options.out, options.ledger)
    print("LABJSON:" + json.dumps(summary))
    # A document that could not be read is recorded, not fatal: the run itself
    # succeeded in doing everything it could.
    return 0


if __name__ == "__main__":
    sys.exit(main())
