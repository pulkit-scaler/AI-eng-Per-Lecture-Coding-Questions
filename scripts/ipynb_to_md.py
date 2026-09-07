#!/usr/bin/env python3
"""Convert Jupyter notebooks (.ipynb) to Markdown (.md).

Dependency-free: parses the notebook JSON directly, so it works without
jupyter/nbconvert installed.

Usage:
    python3 ipynb_to_md.py                 # convert every .ipynb in this dir
    python3 ipynb_to_md.py nb1.ipynb ...   # convert specific notebooks
    python3 ipynb_to_md.py -o out_dir      # write .md files into out_dir
"""
import argparse
import glob
import json
import os
import sys


import re

# Matches embedded base64 image payloads (data URIs) that bloat notebooks.
_DATA_URI_RE = re.compile(r"data:image/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=\n\r]+")


def join(source):
    """ipynb source is either a string or a list of strings."""
    if isinstance(source, list):
        return "".join(source)
    return source or ""


def strip_base64_images(text):
    """Remove embedded base64 image data to keep the Markdown compact.

    Handles both Markdown images `![alt](data:image/...;base64,...)` and HTML
    `<img ... src="data:image/...;base64,...">`. The alt text / tag is kept as a
    placeholder so the document still reads sensibly; only the heavy payload goes.
    """
    if "base64," not in text:
        return text
    # Markdown: ![alt](data:image...) -> *(image omitted: alt)*
    text = re.sub(
        r"!\[([^\]]*)\]\(data:image/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=\n\r]+\)",
        lambda m: f"*(image omitted{': ' + m.group(1) if m.group(1) else ''})*",
        text,
    )
    # HTML <img ...> with a base64 src -> *(image omitted: alt)*
    text = re.sub(
        r'<img\b[^>]*\bsrc="data:image/[a-zA-Z0-9.+-]+;base64,[A-Za-z0-9+/=\n\r]+"[^>]*/?>',
        lambda m: (
            "*(image omitted"
            + (
                ": " + re.search(r'alt="([^"]*)"', m.group(0)).group(1)
                if re.search(r'alt="([^"]*)"', m.group(0))
                else ""
            )
            + ")*"
        ),
        text,
    )
    # Any remaining stray data URIs (e.g. inside other attributes) -> placeholder
    text = _DATA_URI_RE.sub("(image omitted)", text)
    return text


def render_outputs(outputs):
    parts = []
    for out in outputs:
        otype = out.get("output_type")
        if otype == "stream":
            text = join(out.get("text", ""))
            if text.strip():
                parts.append("```\n" + text.rstrip("\n") + "\n```")
        elif otype in ("execute_result", "display_data"):
            data = out.get("data", {})
            if "text/markdown" in data:
                parts.append(join(data["text/markdown"]).rstrip("\n"))
            elif "image/png" in data:
                parts.append("*(image output omitted)*")
            elif "text/plain" in data:
                text = join(data["text/plain"])
                if text.strip():
                    parts.append("```\n" + text.rstrip("\n") + "\n```")
        elif otype == "error":
            tb = "\n".join(out.get("traceback", []))
            # strip ANSI escape codes
            import re
            tb = re.sub(r"\x1b\[[0-9;]*m", "", tb)
            if tb.strip():
                parts.append("```\n" + tb.rstrip("\n") + "\n```")
    return parts


def convert(nb_path):
    with open(nb_path, "r", encoding="utf-8") as f:
        nb = json.load(f)

    lang = (
        nb.get("metadata", {})
        .get("language_info", {})
        .get("name", "python")
    )

    blocks = []
    for cell in nb.get("cells", []):
        ctype = cell.get("cell_type")
        src = join(cell.get("source", "")).rstrip("\n")
        if ctype == "markdown":
            if src:
                blocks.append(strip_base64_images(src))
        elif ctype == "code":
            if src:
                blocks.append(f"```{lang}\n{src}\n```")
            for out in render_outputs(cell.get("outputs", [])):
                blocks.append(out)
        elif ctype == "raw":
            if src:
                blocks.append(src)

    return "\n\n".join(blocks) + "\n"


def main(argv=None):
    parser = argparse.ArgumentParser(description="Convert .ipynb files to .md")
    parser.add_argument("notebooks", nargs="*", help="Notebook files (default: all *.ipynb in cwd)")
    parser.add_argument("-o", "--output-dir", help="Directory to write .md files (default: alongside source)")
    args = parser.parse_args(argv)

    paths = args.notebooks or sorted(glob.glob("*.ipynb"))
    if not paths:
        print("No .ipynb files found.", file=sys.stderr)
        return 1

    if args.output_dir:
        os.makedirs(args.output_dir, exist_ok=True)

    failures = 0
    for path in paths:
        try:
            md = convert(path)
        except Exception as e:  # noqa: BLE001
            print(f"FAILED {path}: {e}", file=sys.stderr)
            failures += 1
            continue
        base = os.path.splitext(os.path.basename(path))[0] + ".md"
        out_path = os.path.join(args.output_dir, base) if args.output_dir else \
            os.path.splitext(path)[0] + ".md"
        with open(out_path, "w", encoding="utf-8") as f:
            f.write(md)
        print(f"Converted {path} -> {out_path}")

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
