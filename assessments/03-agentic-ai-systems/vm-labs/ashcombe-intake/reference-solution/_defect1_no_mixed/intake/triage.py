"""Stage 1: work out what kind of document this is, before paying to parse it.

The cheapest thing you can know about a PDF is whether it has a text layer at
all, and PyMuPDF will tell you in a few milliseconds. That one measurement is
what decides which parsing strategy the document needs.
"""
import fitz

# A page with fewer than this many non-whitespace characters has, for our
# purposes, no usable text layer. A stray watermark should not make a scan look
# like a native document.
MIN_CHARS = 20


def classify(path):
    """Return what is known about one document without parsing it properly.

    Keys: `flavor` (digital, scanned or mixed), `pages`, `text_pages` (the
    1-based page numbers that carry a text layer) and `chars` (the count per
    page).
    """
    document = fitz.open(path)
    try:
        chars = []
        for page in document:
            text = page.get_text() or ""
            chars.append(len("".join(text.split())))
    finally:
        document.close()

    pages = len(chars)
    text_pages = [index + 1 for index, count in enumerate(chars)
                  if count >= MIN_CHARS]

    if text_pages:
        flavor = "digital"
    else:
        flavor = "scanned"

    return {"flavor": flavor, "pages": pages, "text_pages": text_pages,
            "chars": chars}
