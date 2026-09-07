# `ashcombe-intake` — Parsing Complex Documents (M3-L13)

A VM lab. The learner builds the ingestion worker that drains a spool of mixed
supplier documents — native PDFs, scans, and documents that are both — routing
each one to the parsing strategy its shape actually needs.

**Max Score 50 = 5 checks × 10.**

## The deliverable shape

Not another `solution.py`, and not a fixed pipeline of scripts either: the unit
of work is **discovered**, not declared. The artefact is a **spool worker**.

    intake/triage.py    classify(path) -> flavor, pages, text_pages, chars
    intake/chunk.py     layout_aware_chunks(elements, source, max_chars)
    intake/worker.py    strategy_for(flavor); python3 -m intake.worker --once

The checks drop their own documents into a spool of their own, drain it with the
learner's worker, and then read three independent things: the artefacts, the
ledger, and **what the intake API was actually asked to do**.

## Why the routing is real

The corpus is genuine PDFs, generated at authoring time with PyMuPDF. The
scanned documents are image-only pages with **no text layer at all** — they were
rendered to a grayscale JPEG and re-wrapped, which is what a scan is. So:

- `page.get_text()` on a scan returns nothing, and triage can measure that.
- `fast` on a scan returns **zero elements**, silently. Not an error — nothing.
- `ocr_only` on a native PDF costs 8× and returns the same words with the table
  structure thrown away.

Routing is therefore not a style preference. A drain over the graded set costs
**29 units** routed correctly, 56 sent all to `ocr_only`, and 7 sent all to
`fast` while losing three documents' text entirely.

## What each check grades

1. **Triage** — five documents across all three flavors classified correctly,
   with the right page counts and text pages, and **zero** calls to the parsing
   API while doing it.
2. **Routing** — every document to the strategy its flavor calls for, parsed
   exactly once, inside the 29-unit budget, each leaving an artefact.
3. **Chunking** — the table survives as one labelled chunk carrying its section;
   every chunk names its source; the section follows the document; long
   narrative splits at the limit; empty elements are dropped.
4. **Idempotency** — a second drain parses nothing and adds no ledger rows; a
   copy of a finished document **under a different filename** is recognised as
   the same document.
5. **Failure isolation** — two unreadable files recorded as failed with reasons
   and no artefacts, every readable document still through, none of the bad
   files sent to the API, and the run exits 0.

## Layout

    tools/make_corpus.py      regenerates the PDFs and the parse plans
    app/                      what the learner is given (kit, stubs, 3 documents)
    service/intakesvc.py      the parsing API; root-only at /opt/ashcombe-svc
    service/corpus.py         GENERATED - documents plus their plans
    setup/                    template + generated setup_script.sh
    test-cases/scripts/       script_01..05 (shipped) + common.sh, run-all.sh (local)
    reference-solution/       the model answer, 5 alternatives, 8 defects, 1 cheat
    validation/permutations.sh  the ordering matrix
    dist/                     Setup.zip and TestCase.zip

## Working on it

    python3 tools/make_corpus.py       # only if the corpus needs changing
    ./gen_tests.sh                     # regenerate the five checks
    ./build.sh                         # invariants, then stage both zips
    bash test-cases/scripts/run-all.sh # grade the reference
    ./sweep.sh                         # grade every candidate
    ./validation/permutations.sh       # the ordering matrix

PyMuPDF is required, so a local run needs an interpreter that has it:
`PY=/path/to/venv/bin/python bash test-cases/scripts/run-all.sh`.

**If you regenerate the corpus, the hashes change.** `build.sh` checks that the
documents in `app/data/inbox/` match the plans byte for byte and will refuse the
build if they drift.

## Target image

*systemd Ubuntu* (really Ubuntu 25.04 / Python 3.13). One pip wheel —
`pymupdf==1.24.14`, pinned because later versions print a deprecation warning on
`import fitz` and learners follow that spelling. It is an abi3 wheel, so it
installs on any Python from 3.9 up.
