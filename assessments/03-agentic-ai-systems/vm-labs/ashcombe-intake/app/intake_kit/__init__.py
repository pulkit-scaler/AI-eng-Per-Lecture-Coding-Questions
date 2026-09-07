"""The Ashcombe intake stack. Provided, do not modify."""
import base64
import os

from .client import DeskError, post_json

# The three strategies the intake API offers, and what a page costs under each.
# Cost is what the account is billed, so routing is not a free choice.
STRATEGIES = ("fast", "hi_res", "ocr_only")
COST_PER_PAGE = {"fast": 1, "hi_res": 5, "ocr_only": 8}


def parse_document(path, strategy):
    """Send one document to the intake API and get typed elements back.

    Returns a dict with `elements` (each `{"type": ..., "text": ..., "page":
    ...}`), `pages`, `strategy` and `cost_units`.

    Element types are `Title`, `NarrativeText`, `Table` and `ListItem`.

    The three strategies differ in what they can see and what they cost:

    * `fast` reads the text layer. A page that has no text layer comes back
      with nothing at all.
    * `hi_res` reads every page and recognises structure, so a table comes back
      as one `Table` element.
    * `ocr_only` reads every page by recognising characters. It recovers the
      words but not the layout, so a table comes back as running text.

    Raises `DeskError` if the API refuses the document.
    """
    if strategy not in STRATEGIES:
        raise ValueError("unknown strategy %r, expected one of %s"
                         % (strategy, ", ".join(STRATEGIES)))
    with open(path, "rb") as handle:
        raw = handle.read()
    return post_json("/v1/parse", {
        "filename": os.path.basename(path),
        "content_b64": base64.b64encode(raw).decode(),
        "strategy": strategy,
        "run_id": os.environ.get("ASHCOMBE_RUN_ID", "default"),
    })


__all__ = ["parse_document", "STRATEGIES", "COST_PER_PAGE", "DeskError",
           "post_json"]
