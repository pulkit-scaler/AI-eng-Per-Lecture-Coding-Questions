"""Same two rules, accumulated as a list of parts instead of a string buffer."""


def _label(source, title, table=False):
    bits = ["Source: %s" % source]
    if title:
        bits.append("Section: %s" % title)
    if table:
        bits.append("TABLE")
    return "[%s]\n" % " | ".join(bits)


def layout_aware_chunks(elements, source, max_chars=400):
    chunks = []
    parts = []
    length = 0
    title = None

    def emit():
        nonlocal parts, length
        if parts:
            chunks.append(_label(source, title) + " ".join(parts))
        parts, length = [], 0

    for element in elements or []:
        kind = (element.get("type") or "").strip()
        text = (element.get("text") or "").strip()
        if not text:
            continue
        if kind == "Title":
            emit()
            title = text
        elif kind == "Table":
            emit()
            chunks.append(_label(source, title, table=True) + text)
        else:
            if parts and length + len(text) + 1 >= max_chars:
                emit()
            parts.append(text)
            length += len(text) + 1
    emit()
    return chunks
