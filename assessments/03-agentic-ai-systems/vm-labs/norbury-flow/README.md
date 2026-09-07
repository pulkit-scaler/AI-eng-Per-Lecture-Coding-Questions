# `norbury-flow` — Rapid Prototyping & Low-Code Tools (M3-L18)

A VM lab. The learner is handed a visual builder's flow export and writes the
production Python that runs it: read the node graph, refuse what cannot run,
resolve the build order, carry the configuration across, and write out the agent
loop the builder drew as a single box.

**Max Score 50 = 5 checks × 10.**

## The deliverable shape

Not another `solution.py`. The artefact is a **flow compiler and runtime** —
the thing that stands between a demo and a deployment.

    flow/spec.py      FlowError; load_flow / validate / plan
    flow/runtime.py   build_runtime / run_turn
    flowctl.py        validate <flow> | run <flow> --message M --session S

Checks 1 and 2 call `spec` directly with eight broken flows the project never
shows. Checks 3 to 5 drive the command line and then read what the model
endpoint was actually sent.

## What makes it gradeable

The endpoint records, per run, the model and temperature it was handed, the
system prompt it saw, the tool list it was offered, whether the export's
placeholder was presented as a credential, and whether a wrap-up was ever
requested. So "the configuration reached the runtime" is a fact, not a claim —
and a `flowctl.py` that answers from a canned string scores **20/50**.

## What each check grades

1. **Refusals** — eight broken flows (unknown component, dangling edge, two
   outputs, no input, a tool that does not exist, a model with no model named, a
   circle, an unreachable output), each refused with the offending node named;
   two runnable flows accepted; a missing file refused as a `FlowError` too.
2. **The plan** — every node once, never before what feeds it, starting at the
   `ChatInput` and ending at the `ChatOutput`, and a circle refused. Several
   orders are valid and all of them pass.
3. **Configuration and the credential** — declared model, temperature, prompt
   text and exactly the wired tools all reach the endpoint; the `***` from the
   export never does; and a missing `NORBURY_API_KEY` fails with a message
   naming the variable.
4. **The loop** — the three wired tools run in the order the model asks for,
   with their node `max_results`; their findings appear in the answer; and a
   flow capped at two steps makes exactly two tool calls, asks for a wrap-up,
   and records that it stopped early.
5. **Sessions and the log** — a second turn in the same session recalls the
   first; a different session does not; a flow with **no** `Memory` node does
   not; and `runs/<session>.json` carries both turns with their tool calls.

## Layout

    app/                      what the learner is given (kit, stubs, 2 exports)
    service/flowsvc.py        the model endpoint; root-only at /opt/norbury-svc
    setup/                    template + generated setup_script.sh
    test-cases/scripts/       script_01..05 (shipped) + common.sh, run-all.sh (local)
    reference-solution/       the model answer, 5 alternatives, 8 defects, 1 cheat
    validation/permutations.sh  the ordering matrix
    dist/                     Setup.zip and TestCase.zip

## Working on it

    ./gen_tests.sh                     # regenerate the five checks
    ./build.sh                         # invariants, then stage both zips
    bash test-cases/scripts/run-all.sh # grade the reference
    ./sweep.sh                         # grade every candidate
    ./validation/permutations.sh       # the ordering matrix

Standard library only, so the system `python3` runs everything.

## Target image

*systemd Ubuntu* (really Ubuntu 25.04 / Python 3.13). **No pip package at all** —
the detached setup job installs only `curl` and `jq` for the check scripts, and
writes `NORBURY_API_KEY` into `/etc/profile.d` so the learner's shell has a
credential. The checks set that variable themselves rather than relying on
`profile.d`, because the judge is a non-login root shell that never reads it.
