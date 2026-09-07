# `bellhaven-rubric` — LLM-as-a-Judge & Advanced Evaluation (M3-L15)

A VM lab. The learner replaces a single "92% accurate" slide number with an
evaluation that survives being questioned: a stratified golden set, rule-based
metrics before expensive ones, a rubric-driven grading model, a second grader
from a different family, measured agreement, and a gate that refuses to pass a
build when the graders themselves cannot agree.

**Max Score 50 = 5 checks × 10.**

## The deliverable shape

Not another `solution.py`. The artefact is a **regression gate**: four harness
modules, one per stage, plus a command line that ends in an exit code.

    harness/dataset.py    build_golden(pool, size, per_bucket, seed)
    harness/metrics.py    exact_match / symbolic_match
    harness/judge.py      build_judge_prompt / parse_judge_response / judge_prediction
    harness/ensemble.py   observed_agreement / cohen_kappa / ensemble
    gate.py               --pool --out --size --per-bucket --seed --baseline --min-kappa

Checks 1 to 4 call those functions directly with inputs the project never shows.
Check 5 runs the command line twice and then reads what the review desk was
actually sent.

## What each check grades

1. **The golden set** — size, per-stratum cap, spread across strata, every
   stress test kept whatever the caps say, no duplicates, and the same sample on
   a second call with the same seed.
2. **The rule-based metrics** — thirteen prediction/reference pairs covering
   equivalent forms (`0.75` vs `3/4`, `\frac{19}{12}` vs `19/12`, `90^\circ` vs
   `90`), plain wrong answers, a missing answer and an unparseable one; plus the
   requirement that over the whole pool the symbolic metric recovers answers the
   string metric marks wrong.
3. **One grader** — the parser survives fenced JSON, JSON after prose, bare
   JSON, a reply with no JSON at all, a truncated object and an empty string,
   without raising and **without scoring an unreadable reply as correct**; and
   the desk confirms the prompt it received carried the problem, the reference
   answer, the submission, the working and the rubric.
4. **Two graders** — agreement and kappa on five vectors, two of which are
   degenerate and where kappa must come back `None` rather than `1.0`; and the
   single disagreement escalated rather than voted on.
5. **The gate** — a clean pool passes and exits 0; raising `--min-kappa` fails
   the build with a reason that names agreement; the review queue holds exactly
   the disagreement; the report carries both metrics and both agreement figures;
   and the desk confirms every selected record really went to both graders.

## Layout

    app/                      what the learner is given (kit, stubs, sample pool)
    service/judgesvc.py       the review desk; root-only at /opt/bellhaven-svc
    setup/                    template + generated setup_script.sh
    test-cases/scripts/       script_01..05 (shipped) + common.sh, run-all.sh (local)
    reference-solution/       the model answer, 5 alternatives, 7 defects, 1 cheat
    validation/permutations.sh  the ordering matrix
    dist/                     Setup.zip and TestCase.zip

## Working on it

    ./gen_tests.sh                     # regenerate the five checks from one preamble
    ./build.sh                         # invariants, then stage both zips
    bash test-cases/scripts/run-all.sh # grade the reference
    ./sweep.sh                         # grade every candidate
    ./validation/permutations.sh       # the ordering matrix

`sympy` is required, so a local run needs an interpreter that has it:
`PY=/path/to/venv/bin/python bash test-cases/scripts/run-all.sh`.

## Target image

*systemd Ubuntu* (really Ubuntu 25.04 / Python 3.13). One pip wheel — `sympy` —
installed by the detached setup job alongside `curl` and `jq`. No `numpy`, no
`scikit-learn`: the kappa arithmetic is the learner's, which is the point.
