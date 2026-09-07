#!/usr/bin/env python3
"""Convert the test Markdown files (.md) to Jupyter notebooks (.ipynb).

Each `---`-delimited block in the source becomes its own Markdown cell, so the
title/instructions, every question, and the consolidated review land in
separate, individually-runnable cells.

Usage:
    python3 md_to_ipynb.py                       # convert every tests/*.md
    python3 md_to_ipynb.py tests/Module_Test_1.md
    python3 md_to_ipynb.py -o out_dir file.md
"""
import argparse
import glob
import json
import os
import sys


def to_source_lines(text):
    """nbformat stores source as a list of strings, each ending in \\n
    except the last."""
    text = text.strip("\n")
    if not text:
        return []
    lines = text.split("\n")
    return [line + "\n" for line in lines[:-1]] + [lines[-1]]


def convert(md_path):
    with open(md_path, "r", encoding="utf-8") as f:
        content = f.read()

    # Split on horizontal-rule separators (--- on their own line).
    blocks = [b.strip("\n") for b in content.split("\n---\n")]
    blocks = [b for b in blocks if b.strip()]

    cells = []
    for block in blocks:
        cells.append({
            "cell_type": "markdown",
            "metadata": {},
            "source": to_source_lines(block),
        })

    return {
        "cells": cells,
        "metadata": {
            "kernelspec": {
                "display_name": "Python 3",
                "language": "python",
                "name": "python3",
            },
            "language_info": {"name": "python"},
        },
        "nbformat": 4,
        "nbformat_minor": 5,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description="Convert test .md files to .ipynb")
    parser.add_argument("files", nargs="*", help="Markdown files (default: tests/*.md)")
    parser.add_argument("-o", "--output-dir", help="Directory to write .ipynb files (default: alongside source)")
    args = parser.parse_args(argv)

    paths = args.files or sorted(glob.glob("tests/*.md"))
    if not paths:
        print("No .md files found.", file=sys.stderr)
        return 1

    if args.output_dir:
        os.makedirs(args.output_dir, exist_ok=True)

    failures = 0
    for path in paths:
        try:
            nb = convert(path)
        except Exception as e:  # noqa: BLE001
            print(f"FAILED {path}: {e}", file=sys.stderr)
            failures += 1
            continue
        base = os.path.splitext(os.path.basename(path))[0] + ".ipynb"
        out_path = os.path.join(args.output_dir, base) if args.output_dir else \
            os.path.splitext(path)[0] + ".ipynb"
        with open(out_path, "w", encoding="utf-8") as f:
            json.dump(nb, f, indent=1, ensure_ascii=False)
            f.write("\n")
        print(f"Converted {path} -> {out_path} ({len(nb['cells'])} cells)")

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
