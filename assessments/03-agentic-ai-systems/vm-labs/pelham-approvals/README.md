# `pelham-approvals` — Human-in-the-Loop & BDI Architecture (M3-L16)

A VM lab. The learner builds an expense-approval agent that knows when to stop:
it decides what a person has to see, **pauses mid-flight** while it waits, and
resumes days later when a webhook delivers the decision.

**Max Score 50 = 5 checks × 10.**

## The deliverable shape

Not another `solution.py`. The artefact is **a service that waits** — the only
shape in which a durable pause is a real thing rather than a demo.

    bdi/nodes.py    perceive / deliberate / human_review / finalize / route_decision
    bdi/graph.py    build_graph() -> a compiled graph with a checkpointer
    server.py       127.0.0.1:8767 - POST /claims, GET /claims/<id>,
                    POST /webhook/approval

Every check drives it over HTTP. Nothing is asserted about the graph's internals;
what is asserted is that a claim really is still waiting when a **separate**
request asks, that starting a second claim does not disturb it, and that reading
it back does not re-run the agent.

## Why BDI is graded, not just mentioned

The state carries `beliefs`, `desires`, `intentions` and an `audit_log` as
first-class fields, readable through `GET /claims/<thread_id>`. Check 1 reads
them the way a compliance reviewer would eighteen months later — and it asserts
the **desires are identical across two different claims**, because business goals
are set by the people who own the process and only the intention responds to the
claim in front of you. A solution that lets the model write the desires loses
that check.

## What each check grades

1. **BDI state** — beliefs carry the claim *and* the policy it was measured
   against; desires are stable across two claims; intentions name actions; the
   audit log records every stage in order; and the analyst was really consulted.
2. **Routing** — five claims: below, at and above the threshold, an invalid
   category, and a small claim in a valid category whose description the analyst
   flags. That last one is the point: routing on the amount alone gets it wrong.
3. **The pause** — the payload carries the claim, the reasoning and both
   options; `final_status` and `human_decision` stay empty while it waits; the
   pause survives separate requests; a second thread leaves it alone; and
   reading it back puts no more work through the analyst.
4. **The resume** — the right thread resumes, the outcome names both the
   decision and that a person made it, the audit log grew **without being
   rewritten**, the intentions grew, and the other thread is untouched.
5. **A safe callback** — replay, unknown thread, unrecognised decision and a
   malformed body are each refused as client errors and change nothing, and the
   service still works afterwards.

## Layout

    app/                      what the learner is given (kit, stubs)
    service/expensesvc.py     the analysis model; root-only at /opt/pelham-svc
    setup/                    template + generated setup_script.sh
    test-cases/scripts/       script_01..05 (shipped) + common.sh, run-all.sh (local)
    reference-solution/       the model answer, 5 alternatives, 7 defects, 1 cheat
    validation/permutations.sh  the ordering matrix
    dist/                     Setup.zip and TestCase.zip

## Working on it

    ./gen_tests.sh                     # regenerate the five checks
    ./build.sh                         # invariants, then stage both zips
    bash test-cases/scripts/run-all.sh # grade the reference
    ./sweep.sh                         # grade every candidate
    ./validation/permutations.sh       # the ordering matrix

LangGraph is required, so a local run needs an interpreter that has it:
`PY=/path/to/venv/bin/python bash test-cases/scripts/run-all.sh`.

## Target image

*systemd Ubuntu* (really Ubuntu 25.04 / Python 3.13). Two pip wheels —
`langgraph==1.2.11` and `langchain-core==1.6.0` — installed by the detached
setup job alongside `curl` and `jq`.
