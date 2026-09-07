"""Stage 2: chunk the elements without destroying what the parser recovered.

Two rules do most of the work. Never split a table: the header is what makes
the rows mean anything. And prepend the source and the section to every chunk,
so a retrieved fragment still says where it came from.
"""


def layout_aware_chunks(elements, source, max_chars=400):
    """Chunk typed elements, keeping tables whole and titles as context."""
    chunks = []
    state = {"title": None, "buffer": ""}

    def prefix(table=False):
        parts = ["Source: %s" % source]
        if state["title"]:
            parts.append("Section: %s" % state["title"])
        if table:
            parts.append("TABLE")
        return "[" + " | ".join(parts) + "]\n"

    def flush():
        body = state["buffer"].strip()
        state["buffer"] = ""
        if body:
            chunks.append(prefix() + body)

    for element in elements or []:
        kind = (element.get("type") or "").strip()
        text = (element.get("text") or "").strip()
        if not text:
            continue
        if kind == "Title":
            flush()
            state["title"] = text
        elif kind == "Table":
            flush()
            for row in text.splitlines():
                if row.strip():
                    chunks.append(prefix(table=True) + row)
        else:
            if state["buffer"] and \
                    len(state["buffer"]) + 1 + len(text) >= max_chars:
                flush()
            state["buffer"] = (state["buffer"] + " " + text).strip()
    flush()
    return chunks
