# `orenford-newsroom` — Multi-Agent Systems: Patterns & Orchestration (M3-L6)

A VM lab whose deliverable is a **long-running HTTP service**. The learner writes
`serve.py`, starts it, and the grader commissions briefings from it over the
network — then checks every figure in the answer against what the newsroom wire
actually saw.

- **Target image:** *systemd Ubuntu*, really **Ubuntu 25.04 / Python 3.13.3** —
  no pip, no `ensurepip`, PEP 668, password-gated `sudo`, no Docker.
- **Max Score 50 = 5 checks × 10.**
- **Project:** `/home/user/orenford-newsroom`. Wire on `127.0.0.1:8317`, the
  learner service on `127.0.0.1:8300`.

## Why a service

The HTTP plumbing is provided (`kit.run_service(handler)` answers `/health` and
routes `POST /brief`), so none of the learner's effort goes on `http.server`
boilerplate. What the shape buys is real:

- **The grader is a client, not a caller.** It cannot reach inside the run; it
  sees the response body and the wire trace. Every assertion is therefore about
  observable behaviour rather than about internal structure.
- **One process, many commissions.** Five checks commission seven briefings from
  one long-lived process, which is what makes the per-role accounting worth
  grading — the figures have to be per run, not per process.
- **Failure is visible the way it would be in production.** A handler that
  raises comes back as a 500 with the exception text, and `serve.log` has the
  traceback.

## The five themes

1. **The research pass** — all three desks consulted, their findings merged into
   one list, the plan's three sub-questions reported in order, and a unique
   sorted source list.
2. **A desk that fails** — one assignment's people desk answers 503. The
   briefing still goes out on the other two desks, records the unavailable desk
   with a reason, and the wire confirms the desk was actually asked.
3. **The night editor loop** — one assignment accepted first time, one never
   accepted: revisions stop at `MAX_REVISIONS`, status becomes
   `published_with_reservations`, the reservations are the editor's own issues,
   and the writer and critic call counts match the cap exactly.
4. **Traceability** — a source the desk may not cite is dropped from the claims
   and the source list, recorded as excluded, and *its desk was still consulted*.
   Every remaining claim traces to a listed source.
5. **The accounting** — two assignments, one of which takes a round of rework, so
   a block of numbers written out in advance is wrong for one of them. Every
   per-role figure and the total match the wire.

## What is and is not graded

Graded: which desks were consulted, that their findings merged, that a failure
was contained and recorded, that the loop stopped at its cap, that claims trace
to sources, and that the accounting matches the wire.

**Not** graded: the topology. A fan-out subgraph, three top-level nodes, a
supervisor walking the desks, or plain Python that never imports LangGraph at all
each score 50/50 — six alternative shapes graded, `alt6_no_graph` among them.
Grading the topology would be grading shape, and the statement says which
outcomes matter instead. The instructor guide spells out what that means for
marking.

Also not graded, and so no longer stated as rules: where the duplicate-source
check happens (reducer or on the way out), and whether the plan schema pins its
list length. Both are in the statement as design instruction, not as
requirements. Every remaining *must* in the statement has a check behind it —
`VALIDATION.md` §6 lists the two that did not and what was done about them.

One probe worth knowing about: giving the findings key **no reducer at all**
makes LangGraph refuse the fan-out outright, so the service 500s and the run
scores 0/50. That is the framework being helpful — the silent
last-writer-wins bug is not available to a learner using a fan-out.

## Pack layout

```
app/                    everything provided, plus serve_stub.py
service/wired.py        the newsroom wire (root-only, outside the project)
setup/                  setup_script.template.sh -> scripts/setup_script.sh
reference-solution/     the model answer, 5 alternative shapes, 7 defect probes,
                        1 fabrication probe
test-cases/scripts/     script_01..05.sh (shipped) + common.sh, run-all.sh
validation/             the ordering matrix
dist/                   Setup.zip + TestCase.zip
```

## Authoring commands

```bash
./gen_tests.sh
./build.sh
PY=/path/to/venv/bin/python ./test-cases/scripts/run-all.sh
PY=... ./sweep.sh                      # every candidate, on its own port pair
PY=... ./validation/permutations.sh    # ordering matrix (as root on the VM once)
```

`VALIDATION.md` records the observed numbers and what a non-VM host cannot
settle.
