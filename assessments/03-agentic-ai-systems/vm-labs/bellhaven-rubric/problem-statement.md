# Bellhaven — an evaluation you can actually ship on

## Overview

Bellhaven Learning runs a quantitative-reasoning tutor. It works a problem step
by step with a calculator and states a final answer. Last quarter the team put a
number on a slide: **"92% accurate."**

The number came from one grading model, scoring one run, on fifty problems
somebody picked by hand. Nobody wrote down which metric it was, nobody checked
whether a second grader would have agreed, and the sample happened to contain
none of the cases the tutor is known to struggle with.

You are going to replace it with an evaluation that survives being questioned: a
stratified golden set, cheap checks before expensive ones, a grading model with a
written rubric, a second grader from a different family, a measured level of
agreement between them, and a gate that refuses to pass a build when the graders
themselves cannot agree.

## Learning objectives

- Build a stratified sample that keeps the known failure cases instead of
  averaging them away.
- Reach for a cheap correct answer before an expensive one: string equality,
  then symbolic equivalence, then a model.
- Write a grading rubric that produces a machine-readable score, and parse a
  reply from a model that does not promise to return only JSON.
- Measure agreement between two graders, and know when that measurement is not
  defined.
- Escalate disagreement to a person rather than settling it with a vote of two.
- Turn all of it into a gate that can sit in a pipeline.

## What is provided

Everything below is in `/home/user/bellhaven-rubric` and already works. Do not
modify anything under `eval_kit/`.

- `eval_kit.ask_judge(family, prompt)` — sends one grading prompt to one model
  and returns its reply **as text**. Two families are available, `"nyx"` and
  `"vale"`, listed in `eval_kit.FAMILIES`. They format their replies
  differently, and neither promises to return only JSON.
- `eval_kit.load_pool(path)` — reads a prediction pool. Each record has `id`,
  `subject`, `level`, `problem`, `gold_answer`, `predicted_answer`,
  `is_stress_test` and `trace`. A trace is a list of steps, each of which may
  carry `thought`, `action`, `action_input`, `observation` or `final_answer`.
- `eval_kit.bucket_of(record)` — the stratum a record belongs to: its subject
  and its level.
- `data/pool_sample.json` — a small pool to develop against.
- `check_local.py` — runs your gate over that pool and prints the report.
- `reports/` — where your report goes.

The review desk answers on `http://127.0.0.1:8755`. Leave it running. The
symbolic algebra package `sympy` is installed for you; `numpy`, `pandas` and
`scikit-learn` are **not**, so the arithmetic here is yours and the standard
library.

## Interface contract

Five files, with exactly these paths, names and signatures.

- `harness/dataset.py` — `build_golden(pool, size, per_bucket, seed=0)` returns
  a list of records drawn from `pool`.
- `harness/metrics.py` — `exact_match(prediction, gold)` and
  `symbolic_match(prediction, gold)`, each returning `1.0` or `0.0`.
- `harness/judge.py` — `build_judge_prompt(record)` returns a string;
  `parse_judge_response(text)` returns a dict; `judge_prediction(record, family)`
  returns a dict.
- `harness/ensemble.py` — `observed_agreement(first, second)` returns a float;
  `cohen_kappa(first, second)` returns a float **or `None`**;
  `ensemble(first, second)` returns the pair `(resolved, review)`.
- `gate.py` — the command line:

      python3 gate.py --pool <pool.json> --out reports/eval.json

  also accepting `--size`, `--per-bucket`, `--seed`, `--baseline` and
  `--min-kappa`.

Every judgment dict uses the same four fields: `correct` (1 or 0),
`reasoning_quality` (1 to 5), `used_tool_appropriately` (1 or 0) and
`explanation` (a sentence). Helper functions, classes and extra modules are all
fine; extra files are ignored.

## Task 1 — Build the golden set

Write `build_golden(pool, size, per_bucket, seed=0)`.

1. Stratify by `eval_kit.bucket_of(record)`, which is the `(subject, level)`
   pair, and take **at most `per_bucket`** records from any one stratum.
2. Spread across the strata before taking a second record from any of them, so
   a sample of twelve over eight strata touches at least six of them rather than
   emptying two.
3. Keep **every** record with `is_stress_test` set to true, whatever the caps
   say. Those are the failure modes somebody wrote down on purpose; a sample
   that drops them measures the easy half of the problem.
4. Return exactly `size` records when the pool can supply them, with no record
   appearing twice and nothing in the result that was not in the pool.
5. Return the **same** sample when called again with the same pool, size, caps
   and seed. An evaluation you cannot reproduce is not a measurement.

**Requirements.** Return a list of the record dicts themselves. Random selection
is fine as long as it is seeded; a stable ordering with no randomness at all is
equally acceptable.

**Example.**

    pool has 8 strata of 5 records each, plus 3 stress tests
    build_golden(pool, size=12, per_bucket=2, seed=7)
    -> 12 records: the 3 stress tests plus 9 more, no stratum contributing
       more than 2 of the ordinary records, at least 6 strata represented

## Task 2 — The cheap checks, before anybody pays a model

Write the two rule-based metrics. Try these before reaching for a grading
model: they are free, they never drift, and between them they settle most of
what a grader would otherwise be asked.

1. `exact_match(prediction, gold)` compares the two as **strings after
   normalisation**: strip surrounding whitespace, lowercase, remove the wrappers
   maths answers arrive in (`$`, `\left`, `\right`, `\!`, `\,`, stray
   backslashes and whitespace), and collapse a value like `48.0` to `48`.
2. `symbolic_match(prediction, gold)` decides **mathematical** equivalence.
   `0.5` and `1/2` are the same answer. So are `\frac{19}{12}` and `19/12`,
   `25\pi` and `25*pi`, `90^\circ` and `90`, `sqrt(144)` and `12`.
3. `symbolic_match` must **never raise**. An answer of `None`, or one that no
   parser can make sense of, is simply wrong.
4. Both return `1.0` or `0.0`, so a list of them averages into an accuracy.

**Requirements.** `sympy` is installed and is the intended tool for the second
metric; converting the LaTeX-ish answer forms into something its parser accepts
is part of the job. The second metric must be strictly kinder than the first on
equivalent forms without becoming kinder on wrong answers.

**Example.**

    exact_match("48", "48.0")            -> 1.0
    exact_match("0.75", "3/4")           -> 0.0
    symbolic_match("0.75", "3/4")        -> 1.0
    symbolic_match("19/12", "\frac{19}{12}") -> 1.0
    symbolic_match(None, "9")            -> 0.0

## Task 3 — One grader, one prediction

Write the three functions that turn a record into a machine-readable grade.

1. `build_judge_prompt(record)` returns the prompt. It must carry **all four** of
   the problem, the reference answer, the submitted answer and the working from
   the record's `trace`, plus a rubric naming the four fields you want back:
   `correct`, `reasoning_quality`, `used_tool_appropriately` and `explanation`.
   A grader cannot score what it was not shown.
2. `parse_judge_response(text)` pulls the judgment out of the reply. It has to
   cope with JSON inside a fenced code block, JSON after a sentence or two of
   preamble, and bare JSON.
3. It must also survive a reply with **no JSON in it at all**, a truncated
   object, and an empty string. In those cases return a record in the same four
   fields with `correct` set to `0` and an `explanation` that says parsing
   failed. One unreadable reply must not take the run down — and a reply nobody
   could read is not evidence that the answer was right.
4. `judge_prediction(record, family)` builds the prompt, calls
   `eval_kit.ask_judge` with that family, parses the reply and returns the
   judgment dict.

**Requirements.** `correct` and `used_tool_appropriately` come back as `0` or
`1`, `reasoning_quality` as an integer. Never raise out of these three.

**Example.**

    parse_judge_response('```json\n{"correct": 1, "reasoning_quality": 4,
      "used_tool_appropriately": 1, "explanation": "equivalent form"}\n```')
    -> {"correct": 1, "reasoning_quality": 4,
        "used_tool_appropriately": 1, "explanation": "equivalent form"}

    parse_judge_response("The work here is hard to follow.")
    -> {"correct": 0, ..., "explanation": "PARSE_ERROR: ..."}

## Task 4 — Two graders, and what to do when they disagree

A single grader's accuracy figure is worth exactly as much as its agreement with
an independent one. Write the three functions that measure that.

1. `observed_agreement(first, second)` is the plain proportion of positions where
   the two lists hold the same label.
2. `cohen_kappa(first, second)` is that agreement corrected for chance:

       kappa = (po - pe) / (1 - pe)

   where `po` is the observed agreement and `pe` is the agreement you would
   expect from the two graders' label frequencies alone.
3. `cohen_kappa` returns **`None`** when it is not computable — which is what
   happens whenever either grader used only one label. There is no variance to
   correct against, and returning a number there is exactly how a run in which
   everything scored the same gets reported as perfect agreement.
4. `ensemble(first, second)` returns `(resolved, review)`. `resolved[i]` is the
   agreed label where both graders said the same thing and **`None`** where they
   did not; `review` is the list of positions where they disagreed.
5. A disagreement is not settled by a majority of two. It goes to a person.

**Requirements.** Pure Python — `scikit-learn` is not installed. Report kappa
**and** observed agreement; high observed agreement with a low kappa is the
ordinary case and quoting either alone hides it.

**Example.**

    first  = [1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 0, 1]
    second = [1, 1, 1, 0, 1, 1, 1, 0, 1, 1, 0, 1]
    observed_agreement(first, second) -> 0.9166...
    cohen_kappa(first, second)        -> 0.75
    ensemble(first, second)           -> ([1, 1, 1, None, 1, ...], [3])
    cohen_kappa([1, 1, 1, 1], [1, 0, 1, 1]) -> None

## Task 5 — The gate

Write `gate.py` so the whole thing runs as one command and ends in a decision.

1. Read the pool from `--pool`, build the golden set with `--size`,
   `--per-bucket` and `--seed`, and score it with both rule-based metrics.
2. Grade every record with **both** families in `eval_kit.FAMILIES`, then
   combine them with your ensemble.
3. Write a JSON report to `--out`, creating the directory if needed, containing:
   - `dataset` — at least `size` and the list of `ids` selected;
   - `metrics` — `exact_match`, `symbolic_match` and `ensemble_strict`, the
     proportion of the golden set both graders agreed was correct;
   - `agreement` — `kappa` (which may be `null`) **and** `observed`;
   - `review_queue` — the **ids** of the records the graders disagreed on;
   - `gate` — `passed` (a boolean) and `reasons` (a list of strings).
4. Fail the build when `ensemble_strict` is below `--baseline` (default `0.5`),
   and when kappa is below `--min-kappa` (default `0.6`) **or is not computable
   at all**. Each reason must name which of the two gates fired.
5. Print one line to stdout of the form `LABJSON:<summary as JSON>` carrying at
   least `size`, `exact_match`, `symbolic_match`, `ensemble_strict`, `kappa`,
   `observed`, `review`, `passed` and `reasons`.
6. Exit `0` when the gate passed and non-zero when it did not.

**Requirements.** The report must describe grading that actually happened — every
selected record goes to both graders.

**Example.**

    $ python3 gate.py --pool data/pool_sample.json --size 8 --out reports/eval.json
    LABJSON:{"size": 8, "exact_match": 0.25, "symbolic_match": 0.625,
             "ensemble_strict": 0.625, "kappa": 0.714, "observed": 0.875,
             "review": ["sm-205"], "passed": true, "reasons": []}
    $ echo $?
    0

    $ python3 gate.py --pool data/pool_sample.json --size 8 --min-kappa 0.95
    LABJSON:{..., "passed": false,
             "reasons": ["agreement kappa 0.714 is below the floor of 0.950"]}
    $ echo $?
    1

## Run and verify locally

    cd /home/user/bellhaven-rubric
    python3 check_local.py

That runs your gate over `data/pool_sample.json` and prints the report it wrote.
Then exercise the failing arm, which is the half people forget:

    python3 gate.py --pool data/pool_sample.json --size 8 --min-kappa 0.95 ; echo $?

Run both before submitting. The pool used to score your work is a larger one of
its own, with problems you have not seen, so a clean sample run is a good sign
rather than a guarantee.

## How you are graded

Five checks, ten points each, fifty in total.

1. **The golden set.** Size, per-stratum cap, spread across strata, every stress
   test kept, no duplicates, and the same sample on a second call.
2. **The cheap metrics.** A table of prediction and reference pairs including
   equivalent forms, wrong answers, a missing answer and an unparseable one; and
   over the whole pool the symbolic metric recovers answers the string metric
   marks wrong.
3. **One grader.** The parser handles three reply shapes and three unreadable
   ones without raising and without scoring an unreadable reply as correct; and
   the prompt the model actually received carried the problem, the reference
   answer, the submission, the working and the rubric.
4. **Two graders.** Agreement and kappa on five vectors, including two where
   kappa is not computable; and the one disagreement escalated rather than voted
   on.
5. **The gate.** A clean pool passes and exits 0; raising the agreement floor
   fails the build with a reason that names agreement; the review queue holds
   exactly the disagreement; the report carries both metrics and both agreement
   figures; and every selected record was really sent to both graders.
