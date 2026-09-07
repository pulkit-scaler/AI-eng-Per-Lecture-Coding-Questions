# Ashcombe — a document spool that keeps its own accounts

## Overview

Ashcombe Works receives about six hundred supplier documents a month, and they
arrive in every state a document can arrive in. Some are native PDFs generated
by a supplier's accounting system. Some are phone photographs of a paper
receipt, dropped into a PDF wrapper. Some are both at once: a typed report with
a scanned certificate stapled on the end.

They all land in the same folder, and something has to turn them into text a
retrieval system can use.

The pipeline that does this today parses everything the same way. That is two
separate problems. Character recognition on a native PDF costs eight times what
reading its text layer costs, and buys nothing. Reading the text layer of a scan
costs almost nothing and returns **nothing at all**, silently — the document
goes through, the ledger says it worked, and the text is simply missing.

You are going to build the worker that looks before it pays.

## Learning objectives

- Measure a document cheaply, before committing to an expensive way of reading
  it.
- Route each document to the parsing strategy its shape actually needs, and know
  what the wrong choice costs.
- Chunk parsed elements so that what the parser recovered survives into
  retrieval.
- Make a spool idempotent, by content rather than by filename.
- Let one unreadable document be a recorded failure rather than a failed run.

## What is provided

Everything below is in `/home/user/ashcombe-intake` and already works. Do not
modify anything under `intake_kit/`.

- `intake_kit.parse_document(path, strategy)` — sends one document to the intake
  API and returns a dict with `elements`, `pages`, `strategy` and `cost_units`.
  Each element is `{"type": ..., "text": ..., "page": ...}`, where the type is
  one of `Title`, `NarrativeText`, `Table` or `ListItem`. Raises
  `intake_kit.DeskError` if the API refuses the document.
- `intake_kit.STRATEGIES` and `intake_kit.COST_PER_PAGE`.
- `inbox/` — three documents to develop against.
- `out/` — where your artefacts go.
- `check_local.py` — drains a scratch copy of the spool twice and prints the
  ledger and the chunks it produced.

**PyMuPDF** is installed. `import fitz` and `import pymupdf` are the same
package. The intake API answers on `http://127.0.0.1:8777`; leave it running.
There is no key to set.

### The three strategies, and what they cost

Cost is per page, and the account is billed for it, so this is not a free
choice.

- **`fast`** reads the text layer. **1 unit per page.** A page with no text
  layer comes back with nothing at all — not an error, just nothing.
- **`hi_res`** reads every page and recognises structure, so a table comes back
  as one `Table` element. **5 units per page.**
- **`ocr_only`** reads every page by recognising characters. It recovers the
  words but not the layout, so a table comes back as running text. **8 units per
  page.**

## Interface contract

Three files, with exactly these paths and names.

- `intake/triage.py` — `classify(path)` returns a dict.
- `intake/chunk.py` — `layout_aware_chunks(elements, source, max_chars=400)`
  returns a list of strings.
- `intake/worker.py` — `strategy_for(flavor)` returns a strategy name, and the
  module is runnable:

      python3 -m intake.worker --once
      python3 -m intake.worker --once --inbox DIR --out DIR --ledger FILE

  `--inbox` defaults to `inbox`, `--out` to `out`, and `--ledger` to
  `ledger.jsonl`. All three are relative to where the command is run.

Helper functions and extra modules are fine; extra files are ignored.

## Task 1 — Triage: what kind of document is this?

The cheapest thing you can know about a PDF is whether it has a text layer at
all, and PyMuPDF will tell you in milliseconds without the intake API being
involved.

1. Write `classify(path)`. Open the document with PyMuPDF and, for each page,
   measure how much text the page carries — `page.get_text()` gives you the
   text layer.
2. A page counts as carrying text when it has **at least 20 non-whitespace
   characters**. Below that, treat it as having no usable text layer: a stray
   watermark must not make a scan look like a native document.
3. Return a dict with:
   - `flavor` — `"digital"` when **every** page carries text, `"scanned"` when
     **no** page does, `"mixed"` when some do and some do not;
   - `pages` — how many pages the document has;
   - `text_pages` — the **1-based** page numbers that carry text;
   - `chars` — the count you measured, per page.
4. Do not call the intake API here. Triage is the look you take *before* you pay
   to parse anything.

**Requirements.** A document PyMuPDF cannot open may raise; Task 5 says what the
worker does about that.

**Example.** A two-page report whose first page is typed and whose second is a
scanned certificate:

    classify("sowerby-report.pdf")
    -> {"flavor": "mixed", "pages": 2, "text_pages": [1], "chars": [268, 0]}

## Task 2 — Route each document to the strategy it needs

1. Write `strategy_for(flavor)`, mapping what triage found to how the document
   should be parsed:
   - `digital` → **`fast`**. The text is already there; reading it costs 1 a
     page.
   - `scanned` → **`ocr_only`**. There is no text layer, so the characters have
     to be recognised. It costs 8 a page and it is the only thing that works.
   - `mixed` → **`hi_res`**. Some pages need more than the text layer, and this
     is the one strategy that reads every page *and* keeps the structure.
2. In the worker, triage each document, pick the strategy, and call
   `intake_kit.parse_document(path, strategy)` **once**.
3. Do not parse the same document more than once in a single drain. Every parse
   is billed.

**Requirements.** The routing decision comes from the flavor, not from the
filename and not from a fixed list of documents.

**Example.** Over a spool of two native invoices (1 and 2 pages), two scans (1
page each) and one mixed report (2 pages), the whole drain costs
`1 + 2 + 8 + 8 + 10 = 29` units. Sending all five to `ocr_only` would cost 56
and gain nothing; sending all five to `fast` would cost 7 and lose the text of
three of them.

## Task 3 — Chunk without destroying what the parser recovered

1. Write `layout_aware_chunks(elements, source, max_chars=400)`.
2. **Never split a `Table`.** It becomes exactly one chunk. The header row is
   what makes the other rows mean anything, and a table cut in half is a set of
   numbers with no columns.
3. **Every chunk names where it came from.** Prefix each one with the `source`,
   and with the section — the text of the most recent `Title` above it. A
   retrieved fragment that cannot say which document and which section it came
   from is a fragment nobody can check.
4. A `Title` starts a new section: flush whatever narrative was accumulating,
   then remember it as the section for what follows.
5. Group `NarrativeText` and `ListItem` up to `max_chars`, then start a new
   chunk.
6. Skip elements whose text is empty or whitespace. An empty list of elements
   produces an empty list of chunks.

**Requirements.** Return a list of strings. The exact prefix format is yours;
what matters is that the source and the section are both in the chunk text.

**Example.**

    layout_aware_chunks([
        {"type": "Title", "text": "Rookhope Castings order"},
        {"type": "NarrativeText", "text": "Order RC-6120 raised on 2026-05-02."},
        {"type": "Table", "text": "Line  Part   Qty\n1     RK-90   12"},
    ], "rookhope-order.pdf")
    ->
    ["[Source: rookhope-order.pdf | Section: Rookhope Castings order]\n"
     "Order RC-6120 raised on 2026-05-02.",
     "[Source: rookhope-order.pdf | Section: Rookhope Castings order | TABLE]\n"
     "Line  Part   Qty\n1     RK-90   12"]

## Task 4 — Drain the spool, once per document, ever

1. The worker walks `--inbox`, and for each file: triages it, routes it, parses
   it, chunks the elements, and writes an artefact into `--out` — a JSON file
   named after the document, carrying at least the `source`, the `sha256`, the
   `flavor`, the `strategy`, the `pages`, the `elements` and the `chunks`.
2. It appends one row per **processed** document to the `--ledger`, a JSONL
   file. Each row carries at least `source`, `sha256`, `status` (`"ok"` or
   `"failed"`), `reason`, `flavor`, `strategy` and `chunks`.
3. On a later drain, a document the ledger already records as done is **skipped**
   — not parsed again, not written again, and **not given another ledger row**.
4. The key is the **content hash**, not the filename. The same bytes arriving
   again under a different name is the same document, and re-parsing it is
   money spent twice on work already done.
5. Print one line to stdout of the form `LABJSON:<summary as JSON>`, carrying
   `processed`, `skipped` and `failed`.

**Requirements.** Reading the ledger back is how a new process knows what an
earlier one did; two drains are two interpreters and nothing is remembered in
between except what was written down.

**Example.**

    $ python3 -m intake.worker --once
    LABJSON:{"processed": 3, "skipped": 0, "failed": 0}
    $ python3 -m intake.worker --once
    LABJSON:{"processed": 0, "skipped": 3, "failed": 0}
    $ cp inbox/orchard-invoice.pdf inbox/copy-of-invoice.pdf
    $ python3 -m intake.worker --once
    LABJSON:{"processed": 0, "skipped": 4, "failed": 0}

## Task 5 — One bad document is not a bad run

A spool is fed by other people's systems. Sooner or later something arrives that
is not a document at all: a scanner error page saved with a `.pdf` extension, a
zero-byte file from a transfer that died halfway.

1. Catch the failure around **each document**, not around the drain. Everything
   else in the spool was still there to be done.
2. Record the failure in the ledger with `status` set to `"failed"` and a
   `reason` that says what went wrong. The reason is what tells somebody whether
   to re-scan it or chase the sender.
3. Do not write an artefact for a document that could not be read.
4. Do not send it to the intake API either. Triage is what stops you paying to
   parse a file that is not a document.
5. The run itself **exits 0**. It did everything it could do, and it wrote down
   everything it could not. A pipeline that dies on one bad file is a pipeline
   somebody has to babysit.

**Requirements.** `failed` in the summary counts the documents that could not be
handled; `processed` still counts the ones that could.

**Example.**

    $ python3 -m intake.worker --once
    LABJSON:{"processed": 5, "skipped": 0, "failed": 2}
    $ echo $?
    0
    $ grep failed ledger.jsonl
    {"reason": "could not be opened: FileDataError: ...",
     "source": "scanner-error.pdf", "status": "failed", ...}

## Run and verify locally

    cd /home/user/ashcombe-intake
    python3 check_local.py

That drains a scratch copy of `inbox/` twice — so your own ledger is left alone —
and prints the ledger and the first chunks of each artefact. Look at what the
scanned receipt produced against what the native invoice produced: same
pipeline, very different chunks, and that is the point.

You can also drain the real spool yourself:

    python3 -m intake.worker --once
    cat ledger.jsonl

The documents used to score your work are not the ones in `inbox/`.

## How you are graded

Five checks, ten points each, fifty in total.

1. **Triage.** Five documents spanning all three flavors are classified
   correctly, with the right page counts and the right text pages — and none of
   them goes near the intake API to do it.
2. **Routing.** Every document goes to the strategy its flavor calls for, each
   is parsed exactly once, the drain stays inside the cost that routing implies,
   and every document leaves an artefact.
3. **Chunking.** The table survives as one labelled chunk with its section, every
   chunk names its source, the section follows the document, long narrative is
   split at the limit, empty elements are dropped and an empty input gives an
   empty output.
4. **Idempotency.** A second drain over an unchanged spool parses nothing, adds
   no ledger rows and reports everything skipped; a copy of a finished document
   under a new filename is recognised as the same document.
5. **Failure isolation.** Two unreadable files are recorded as failed with
   reasons and no artefacts, every readable document still comes through, none of
   the bad files reaches the intake API, and the run exits 0.
