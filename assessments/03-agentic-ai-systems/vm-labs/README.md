# Module 3 VM Labs — Agentic AI Systems

Lectures whose material is "build a working system" are assessed as **VM labs**
rather than ML Function Descriptor questions: the learner gets a fresh Linux VM,
writes real code, and is graded by **executing** it — never by matching strings
in a file.

Each lab is **Max Score 50 = 5 checks × 10**, because the platform accepts at
most five test scripts. Every script asserts one behavioural *theme* and names
the broken member of that theme in its failure message.

## The labs

**Class 2 — [`caldon-wire/`](caldon-wire/) — Asynchronous Programming & Concurrency**
The concurrency layer of a newsroom wire desk, graded against an endpoint that
counts every request in and out: peak in-flight, mid-flight cancellation, and
whether a reply was streamed.

**Class 4 — [`marlow-depot/`](marlow-depot/) — Containerization with Docker**
No Python at all. A multi-stage `Dockerfile`, a `.dockerignore`, a three-service
`docker-compose.yml` and a release script — graded by building, starting,
measuring and reloading images.

**Class 5 — [`westmere-claims/`](westmere-claims/) — LangChain & LangGraph**
A command-line program, `claimctl`, run as a separate process per graded case.
LCEL and structured output, a clamping reducer, routing on typed state, a bounded
retry, and thread state that outlives the process.

**Class 6 — [`orenford-newsroom/`](orenford-newsroom/) — Multi-Agent Systems**
A long-running HTTP service the grader talks to over the network. Three desks
fanned out and merged, a failing desk contained and recorded, a bounded reviewer
loop, traceable claims, and accounting that has to match what the wire saw.

**Class 7 — [`thistledown-mill/`](thistledown-mill/) — CrewAI & Autogen**
A configured project: `agents.yaml`, `tasks.yaml`, two tools and one
`build_crew()`. Three of the five checks never involve a model.

**Class 8 — [`redcliffe-signals/`](redcliffe-signals/) — ReAct, Reflection & Memory**
One module per pattern, plus a store that survives process exit. Standard library
only — the cosine arithmetic is the learner's.

**Class 9 — [`lambwell-market/`](lambwell-market/) — Browser Automation & Web Agents**
Four pipeline scripts driving a real Chromium against a real site, each leaving an
artefact. The checks read the artefacts and the site's own request log.

**Class 13 — [`ashcombe-intake/`](ashcombe-intake/) — Parsing Complex Documents**
A spool worker. Real PDFs, some of them genuinely image-only, triaged with
PyMuPDF and routed to the parsing strategy their shape needs — measured against
the cost that routing implies.

**Class 15 — [`bellhaven-rubric/`](bellhaven-rubric/) — LLM-as-a-Judge & Evaluation**
A regression gate. A stratified golden set, symbolic equivalence before an
expensive judge, two graders from different families, Cohen's kappa with its
degenerate case handled, and disagreement escalated rather than voted on.

**Class 16 — [`pelham-approvals/`](pelham-approvals/) — Human-in-the-Loop & BDI**
A service that waits. Beliefs, desires and intentions as first-class state; a
graph that pauses mid-flight and commits nothing; a webhook that resumes the
right thread days later; and a callback that is safe to press twice.

**Class 17 — [`caverly-trust/`](caverly-trust/) — Advanced Security & Production Readiness**
A defence layer around an agent the learner never edits: four rails at four hook
points, driven by a red-team campaign that has to end at zero without refusing a
single real customer.

**Class 18 — [`norbury-flow/`](norbury-flow/) — Rapid Prototyping & Low-Code Tools**
A flow compiler. Read a visual builder's export, refuse what cannot run, resolve
the build order, carry the configuration across without the placeholder
credential, and write out the agent loop the builder drew as one box.

**Class 13 — [`ashcombe-intake/`](ashcombe-intake/) — Parsing Complex Documents**
A spool worker. Real PDFs, some of them genuine image-only scans, triaged with
PyMuPDF and routed to the parsing strategy their shape needs — priced, so the
wrong choice costs something.

**Class 15 — [`bellhaven-rubric/`](bellhaven-rubric/) — LLM-as-a-Judge & Evaluation**
A regression gate. A stratified golden set, rule-based metrics before expensive
ones, two graders from different families, Cohen's kappa with its degenerate case
handled, and a command that exits non-zero when the graders disagree.

**Class 16 — [`pelham-approvals/`](pelham-approvals/) — Human-in-the-Loop & BDI**
An approval service that waits. BDI as first-class state, a graph that pauses
mid-flight, and a webhook that resumes the right thread days later.

**Class 17 — [`caverly-trust/`](caverly-trust/) — Advanced Security & Production Readiness**
A defence layer around an unmodified agent: four rails at four hook points, driven
by a red-team campaign that has to reach zero without refusing real customers.

**Class 18 — [`norbury-flow/`](norbury-flow/) — Rapid Prototyping & Low-Code Tools**
A flow compiler. A visual builder's export becomes production Python: refuse what
cannot run, resolve the build order, carry the config across, leave the
placeholder credential behind.

## Every lab has a different deliverable shape, on purpose

Twelve labs of "fill in `solution.py`" teaches the portal, not the subject. Each lab
produces the artefact that class would really produce, and is exercised the way
that artefact really would be: Dockerfiles; a CLI; an HTTP service; a configured
project; a module per pattern with a persistent store; a pipeline of scripts
writing artefacts.

That is not decoration. The CLI shape is what makes `westmere-claims`' persistence
check real — two invocations are two interpreters, so an in-memory checkpointer
*fails* where in-process grading would have passed it. The same lever makes
`redcliffe-signals`' memory check real.

## What is the same across all of them

- **Target image:** *systemd Ubuntu* — really **Ubuntu 25.04 / Python 3.13.3**,
  no pip, no `ensurepip`, PEP 668, password-gated `sudo` — except
  `marlow-depot`, which needs a Docker daemon and therefore the *Alpine Docker*
  image (Alpine 3.15, musl, busybox, Docker 20.10.11, Compose v2.1.1, no
  `python3` on the host). Pip footprints vary: `caverly-trust`,
  `norbury-flow` and `redcliffe-signals` need nothing at all.
- **Dependencies stay small.** Of the twelve labs, `caverly-trust` and
  `norbury-flow` need no pip package at all; `bellhaven-rubric` needs `sympy`,
  `ashcombe-intake` needs `pymupdf`, `pelham-approvals` needs `langgraph`.
- **No hosted model.** Each Python lab ships a stdlib service installed to
  `/opt/<lab>-svc` as `root:root 0700`, whose replies are computed rather than
  sampled. Real tools, reproducible model decisions.
- **Cold-start discipline.** Setup's foreground is the shortest path to a usable
  lab; anything slow is detached behind a readiness file, and every check waits
  on it only when it is genuinely missing.
- **Grading cannot brick the VM.** Anything a check touches is pre-created as the
  learner in setup, and every check hands ownership back from an `EXIT` trap
  rather than from a success path.
- **Each pack carries its own proof:** `gen_tests.sh`, `build.sh`, `run-all.sh`,
  `sweep.sh`, `validation/permutations.sh`, and a `VALIDATION.md` of observed
  numbers and open items.

## Verification status

Every pack was built and run end to end. Observed, not reported:

- **Reference solution 50/50** in all eleven, slowest single check 13 s
  (`marlow-depot`'s cold start) against a ~120 s cap. The five newest labs run
  their slowest check in **1 s**.
- **Every alternative correct shape 50/50** — 5 or 6 per lab, 57 in total,
  varying topology, control flow, storage, configuration format and API style.
- **Defect probes lose exactly their own theme** wherever the defect really is
  one theme: 30 of 38 in the first six, and 32 of 39 in the newest five. The
  rest are documented as honest multi-theme losses, with the reason.
- **Fabrication probes**: every one of the five new labs has at least one, and
  each fails the theme it targets — 20/50 for a flow runner that answers from a
  canned string, 30/50 for an approval service with no graph behind it, 40/50
  for a hand-written scorecard, a fabricated evaluation report, and a document
  worker that invents elements instead of parsing.
- **Ordering matrices pass** — 6 or 7 rows each, covering untouched starters,
  written-but-never-run, partial work, killed grading runs, repeat submissions,
  deleted state, and — for the labs that own a port or a spool — that the
  learner can still run their own workflow afterwards.

The one item no local run can settle is the **root-ownership invariant with the
checks actually running as root**. Off a real VM that assertion is vacuous, and
each `VALIDATION.md` says so plainly. Run each pack's
`validation/permutations.sh` **as root on the image once** before the first
cohort.

See [`DESIGN-NOTES.md`](DESIGN-NOTES.md) for the freshness ledger against every
pre-existing lab, and for the cross-pack lessons — including the three
assertions that turned out to fail correct solutions, and the two ways a shell
can record the wrong process id.
