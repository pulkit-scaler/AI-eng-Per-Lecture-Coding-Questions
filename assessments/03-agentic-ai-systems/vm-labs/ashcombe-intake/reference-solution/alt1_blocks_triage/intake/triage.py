"""Triage by counting the text blocks the page reports rather than characters."""
import fitz

MIN_BLOCKS = 1
MIN_CHARS = 20


def _page_has_text(page):
    blocks = page.get_text("blocks") or []
    words = 0
    for block in blocks:
        body = block[4] if len(block) > 4 else ""
        words += len("".join(str(body).split()))
    return len(blocks) >= MIN_BLOCKS and words >= MIN_CHARS, words


def classify(path):
    document = fitz.open(path)
    try:
        flags = []
        chars = []
        for page in document:
            has_text, words = _page_has_text(page)
            flags.append(has_text)
            chars.append(words)
    finally:
        document.close()

    text_pages = [i + 1 for i, flag in enumerate(flags) if flag]
    pages = len(flags)
    if pages and all(flags):
        flavor = "digital"
    elif not any(flags):
        flavor = "scanned"
    else:
        flavor = "mixed"
    return {"flavor": flavor, "pages": pages, "text_pages": text_pages,
            "chars": chars}
