#!/usr/bin/env python3
"""Generate the document corpus and the parse plans that go with it.

Run once at authoring time with an interpreter that has PyMuPDF:

    python3 tools/make_corpus.py

Writes app/data/inbox/*.pdf (the documents shipped with the project) and
service/corpus.py (every document as base64 plus the elements the intake API
returns for it, for both the shipped set and the graded set).
"""
import base64
import hashlib
import io
import json
import pathlib
import pprint

import fitz

HERE = pathlib.Path(__file__).resolve().parent.parent
INBOX = HERE / "app" / "data" / "inbox"

# Each page is a list of (kind, lines). kind is one of title, narrative, table,
# list. The elements the intake API returns are derived from exactly this, so
# the plan and the document can never drift apart.
DOCUMENTS = {
    # ---------------- shipped with the project ----------------
    "sample": {
        "orchard-invoice.pdf": {
            "flavor": "digital",
            "pages": [[
                ("title", ["Orchard Supplies Ltd"]),
                ("narrative", ["Invoice OS-2211  Date 2026-03-04",
                               "Buyer Ashcombe Works, Bristol"]),
                ("table", ["SKU     Description            Qty   Unit    Total",
                           "K101    Bench clamp            12    9.50    114.00",
                           "K102    Feeler gauge set        6    14.20    85.20",
                           "K103    Bore brush             20     3.15    63.00"]),
                ("narrative", ["Subtotal 262.20  Tax 52.44  Grand total 314.64",
                               "Payment terms net 30 days from invoice date."]),
            ]],
        },
        "harlow-receipt.pdf": {
            "flavor": "scanned",
            "pages": [[
                ("title", ["Harlow Fasteners"]),
                ("narrative", ["Receipt HF-88 dated 2026-02-19",
                               "Cash sale, counter 3"]),
                ("table", ["Item              Qty    Total",
                           "M6 washer bag      4     11.60",
                           "Thread lock        1      7.85"]),
                ("narrative", ["Total paid 19.45 GBP"]),
            ]],
        },
        "vane-memo.pdf": {
            "flavor": "mixed",
            "pages": [
                [("title", ["Vane Engineering internal memo"]),
                 ("narrative", ["From the workshop lead to procurement.",
                                "Subject: bench clamp reorder for line two."]),
                 ("list", ["Reorder point reached on 2026-03-01",
                           "Preferred supplier remains Orchard Supplies",
                           "Budget code WK-221"])],
                [("title", ["Appendix A, signed authorisation"]),
                 ("narrative", ["Authorised by the workshop lead.",
                                "Countersigned by procurement on 2026-03-02."])],
            ],
        },
    },
    # ---------------- graded, never shipped ----------------
    "graded": {
        "cadwell-invoice.pdf": {
            "flavor": "digital",
            "pages": [[
                ("title", ["Cadwell Bearings PLC"]),
                ("narrative", ["Invoice CB-4417  Date 2026-04-11",
                               "Buyer Ashcombe Works, Bristol"]),
                ("table", ["SKU     Description            Qty   Unit    Total",
                           "B220    Taper roller            8    31.40   251.20",
                           "B221    Sealed race            15    12.05   180.75",
                           "B222    Shim pack              40     1.85    74.00"]),
                ("narrative", ["Subtotal 505.95  Tax 101.19  Grand total 607.14",
                               "Payment terms net 45 days."]),
            ]],
        },
        "penhale-order.pdf": {
            "flavor": "digital",
            "pages": [
                [("title", ["Penhale Tooling purchase order"]),
                 ("narrative", ["Order PT-9003 raised 2026-04-02."]),
                 ("table", ["Line  Part        Qty   Unit",
                            "1     PH-14A       25    6.40",
                            "2     PH-14B       25    6.40"])],
                [("title", ["Delivery instructions"]),
                 ("narrative", ["Deliver to gate two before 10:00.",
                                "Contact the goods-in office on arrival."])],
            ],
        },
        "tarrow-receipt.pdf": {
            "flavor": "scanned",
            "pages": [[
                ("title", ["Tarrow Abrasives"]),
                ("narrative", ["Receipt TA-451 dated 2026-03-28",
                               "Counter sale, till 1"]),
                ("table", ["Item              Qty    Total",
                           "Flap disc 60g      10     42.50",
                           "Wire cup brush      2     19.90"]),
                ("narrative", ["Total paid 62.40 GBP"]),
            ]],
        },
        "millgate-note.pdf": {
            "flavor": "scanned",
            "pages": [[
                ("title", ["Millgate Haulage delivery note"]),
                ("narrative", ["Note MG-77, three pallets received.",
                               "Signed at the gate on 2026-04-09."]),
            ]],
        },
        "sowerby-report.pdf": {
            "flavor": "mixed",
            "pages": [
                [("title", ["Sowerby Metrology calibration report"]),
                 ("narrative", ["Instrument CM-18 calibrated 2026-04-05."]),
                 ("table", ["Check          Nominal   Measured   Deviation",
                            "Zero              0.000      0.001      0.001",
                            "Mid span         25.000     24.998     -0.002",
                            "Full span        50.000     50.003      0.003"])],
                [("title", ["Certificate scan"]),
                 ("narrative", ["Issued by the calibration house.",
                                "Valid for twelve months from the date above."])],
            ],
        },
    },
}


def _render_text_page(document, blocks):
    page = document.new_page(width=595, height=842)
    y = 80
    for kind, lines in blocks:
        size = 16 if kind == "title" else 10
        for line in lines:
            prefix = "- " if kind == "list" else ""
            page.insert_text((60, y), prefix + line, fontsize=size,
                             fontname="cour" if kind == "table" else "helv")
            y += size + 8
        y += 10
    return page


def _flatten(document):
    """Turn a page of text into an image-only page: what a scan really is.

    Grayscale JPEG at office-scanner resolution, because a full-colour PNG of a
    mostly white page is several megabytes and these documents have to travel
    inside a setup script.
    """
    scanned = fitz.open()
    for page in document:
        pixmap = page.get_pixmap(dpi=72, colorspace=fitz.csGRAY)
        target = scanned.new_page(width=page.rect.width,
                                  height=page.rect.height)
        target.insert_image(target.rect,
                            stream=pixmap.tobytes("jpg", jpg_quality=55))
    return scanned


def build(name, spec):
    """Return (pdf bytes, per-page text-layer flag)."""
    flavor = spec["flavor"]
    pages = spec["pages"]

    if flavor == "digital":
        document = fitz.open()
        for blocks in pages:
            _render_text_page(document, blocks)
        return document.tobytes(), [True] * len(pages)

    if flavor == "scanned":
        document = fitz.open()
        for blocks in pages:
            _render_text_page(document, blocks)
        flat = _flatten(document)
        return flat.tobytes(), [False] * len(pages)

    # mixed: the first page is native, the rest are scans of their own text
    document = fitz.open()
    _render_text_page(document, pages[0])
    for blocks in pages[1:]:
        scratch = fitz.open()
        _render_text_page(scratch, blocks)
        flat = _flatten(scratch)
        document.insert_pdf(flat)
    return document.tobytes(), [True] + [False] * (len(pages) - 1)


TYPE_OF = {"title": "Title", "narrative": "NarrativeText",
           "table": "Table", "list": "ListItem"}


def elements_for(spec, has_text, strategy):
    """What the intake API returns for one document under one strategy."""
    out = []
    for index, blocks in enumerate(spec["pages"]):
        if strategy == "fast" and not has_text[index]:
            # No text layer to read, so the fast path comes back empty for
            # that page. This is the whole reason routing matters.
            continue
        for kind, lines in blocks:
            text = "\n".join(lines)
            if strategy == "ocr_only":
                # Character recognition gives you the words back. It does not
                # give you the layout, so a table arrives as running text.
                out.append({"type": "NarrativeText",
                            "text": " ".join(lines), "page": index + 1})
            else:
                out.append({"type": TYPE_OF[kind], "text": text,
                            "page": index + 1})
    return out


COST_PER_PAGE = {"fast": 1, "hi_res": 5, "ocr_only": 8}


def main():
    INBOX.mkdir(parents=True, exist_ok=True)
    corpus = {}
    shipped = []
    graded = []

    for group, documents in DOCUMENTS.items():
        for name, spec in documents.items():
            pdf, has_text = build(name, spec)
            digest = hashlib.sha256(pdf).hexdigest()
            entry = {
                "name": name,
                "group": group,
                "pages": len(spec["pages"]),
                "text_pages": [i + 1 for i, flag in enumerate(has_text) if flag],
                "b64": base64.b64encode(pdf).decode(),
                "plans": {strategy: elements_for(spec, has_text, strategy)
                          for strategy in COST_PER_PAGE},
            }
            corpus[digest] = entry
            if group == "sample":
                (INBOX / name).write_bytes(pdf)
                shipped.append(name)
            else:
                graded.append(name)
            print("%-24s %-8s pages=%d text_pages=%s sha=%s"
                  % (name, spec["flavor"], entry["pages"],
                     entry["text_pages"], digest[:12]))

    target = HERE / "service" / "corpus.py"
    with target.open("w") as handle:
        handle.write('"""GENERATED by tools/make_corpus.py - do not hand-edit."""\n')
        handle.write("COST_PER_PAGE = %s\n\n" % pprint.pformat(COST_PER_PAGE))
        handle.write("CORPUS = ")
        handle.write(json.dumps(corpus, indent=1))
        handle.write("\n")
    print("\nwrote %s (%d documents, %d shipped, %d graded)"
          % (target, len(corpus), len(shipped), len(graded)))


if __name__ == "__main__":
    main()
