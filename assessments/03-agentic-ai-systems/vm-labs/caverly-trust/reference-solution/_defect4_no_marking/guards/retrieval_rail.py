"""Retrieved text is handed on untouched."""


def retrieval_rail(source, text, ctx):
    return text if text is not None else ""
