# `caverly-trust` — Advanced Security & Production Readiness (M3-L17)

A VM lab. The learner is handed a working, undefended support agent for a
multi-tenant private bank and writes the **defence layer** around it: four rails
at four hook points, plus a release gate that runs an attack campaign and
records the result.

**Max Score 50 = 5 checks × 10.**

## The deliverable shape

Not another `solution.py`. The artefact is a **policy layer plus an audit
artefact**, exercised the way a real one would be — by a red-team campaign run
through the unmodified agent:

- `guards/input_rail.py`, `guards/retrieval_rail.py`, `guards/tool_rail.py`,
  `guards/output_rail.py` — one rail per file, each a plain callable.
- `harden.py` — a `HOOKS` dict and a command line that writes
  `reports/scorecard.json` and exits non-zero on a dirty campaign.

Three of the five checks call the learner's rails directly with inputs they have
never seen; the other two drive the whole agent and read what the support desk
was actually shown.

## What each check grades

1. **Input rail** — six manipulative requests refused with a reason (including
   one Base64-encoded and one written in full-width lookalike characters), six
   ordinary banking requests passed, and **zero model calls** recorded for a
   request the rail refused. The two authorisation-abuse requests are in the
   *passed* list on purpose: an input filter that starts deciding permissions has
   begun refusing real customers.
2. **Retrieval rail** — the tampered knowledge-base article stops driving the
   agent, the desk confirms the text arrived marked off, and a clean article is
   still answerable. Both halves matter: a rail that deletes the article is an
   outage, not a defence.
3. **Tool rail** — twelve permission cases across customer/support/admin, self
   and tenant scope, and the tenant boundary; then end to end, the cross-tenant
   read and the unauthorised transfer are refused **before the tool runs**, proved
   by the desk never being shown the protected figure.
4. **Output rail** — a worst-case reply loses the operator secret, the other
   tenant's balance, an email, a phone number and a tax id while keeping its
   answer; the caller's own balance survives; and a secret the assistant really
   did emit never reaches the customer.
5. **The gate** — the whole layer drives attack success to zero while every
   legitimate request is still answered, the scorecard is written, the command
   exits 0, and three campaign entries re-run against the learner's `HOOKS` agree.

## Layout

    app/                      what the learner is given (kit, stubs, sample campaign)
    service/trustsvc.py       the support desk; root-only at /opt/caverly-svc
    setup/                    template + generated setup_script.sh
    test-cases/scripts/       script_01..05 (shipped) + common.sh, run-all.sh (local)
    reference-solution/       the model answer, 5 alternatives, 7 defects, 2 cheats
    validation/permutations.sh  the ordering matrix
    dist/                     Setup.zip and TestCase.zip

## Working on it

    ./gen_tests.sh                     # regenerate the five checks from one preamble
    ./build.sh                         # invariants, then stage both zips
    bash test-cases/scripts/run-all.sh # grade the reference
    ./sweep.sh                         # grade every candidate
    ./validation/permutations.sh       # the ordering matrix

## Target image

*systemd Ubuntu* (really Ubuntu 25.04 / Python 3.13). Standard library only —
no pip package is needed for the lab itself, and the detached setup job installs
only `curl` and `jq` for the check scripts.
