# Six new VM labs — design notes (authoring scratch, not learner-facing)

Curriculum classes covered (module-3 assessment numbering, `M3-L<n>`):

- **M3-L4  Containerization with Docker for AI Engineering** -> `marlow-depot/`
- **M3-L5  LangChain & LangGraph Deep Dive**                 -> `westmere-claims/`
- **M3-L6  Multi-Agent Systems: Patterns & Orchestration**   -> `orenford-newsroom/`
- **M3-L7  CrewAI & Microsoft Autogen Frameworks**           -> `thistledown-mill/`
- **M3-L8  Advanced Agent Patterns: ReAct, Reflection & Memory** -> `redcliffe-signals/`
- **M3-L9  Browser Automation & Web Agents**                 -> `lambwell-market/`

## The deliverable shape is different in every lab (deliberate)

Every lab shipped so far hands the learner one `solution.py` with N functions to fill in.
Six more of those in a row teaches the *portal*, not the subject. Each lab below therefore
has the artifact shape that class would actually produce in real work, and the checks grade
that artifact the way it would really be exercised:

1. `marlow-depot`    — **no Python at all.** `Dockerfile`, `.dockerignore`,
                       `docker-compose.yml`, `ship.sh`. Graded by building, running,
                       measuring and re-loading images.
2. `westmere-claims` — **a command-line program.** `claimctl` with five subcommands.
                       Graded by running commands in separate processes and reading the
                       on-disk checkpoint store between them.
3. `orenford-newsroom` — **a long-running HTTP service.** The learner starts their own
                       service and the grader talks to it over the network, then audits the
                       run records it wrote.
4. `thistledown-mill` — **a configured project, not a script.** `config/agents.yaml`,
                       `config/tasks.yaml`, `mill/tools.py`, `mill/crew.py`, run as a module.
                       Graded from the crew output files plus what the model endpoint saw.
5. `redcliffe-signals` — **one module per pattern** (`react_loop.py`, `reflect.py`,
                       `memory.py`) plus a **store that survives process exit**. Graded
                       across several independent sessions.
6. `lambwell-market` — **four scripts in a pipeline that write artifacts.** Graded from the
                       artifacts, from the site's own request log, and from a Playwright
                       trace that has to really open.

## Target image per lab

- `marlow-depot`  -> **Alpine Docker** (`nestybox/alpine-docker`): the only image with a
  Docker daemon. Alpine 3.15, musl, busybox coreutils, Docker 20.10.11 + Compose v2.1.1,
  classic builder (no buildx/BuildKit syntax), no python3 on the host.
- all five others -> **systemd Ubuntu** (really Ubuntu 25.04 / Python 3.13.3, no pip, no
  ensurepip, PEP 668, password-gated sudo, no Docker).

## Freshness ledger (no lab may reuse another's mechanic)

Already shipped or drafted elsewhere, and therefore off-limits:

- `docker-rag-qa-service` — single-stage Dockerfile + 3-service Compose + non-root + a
  Chroma server. `marlow-depot` instead grades: one-shot indexer ordering into a shared
  named volume, a measured multi-stage size delta, runtime-only secret injection,
  layer-cache reuse timed across two builds, and `docker save`/`load` portability.
- `skyline-dispatch` — `StateGraph` tool loop, `create_agent`, counter-bounded loop.
  `westmere-claims` instead grades: LCEL, `.with_structured_output`, a custom reducer,
  conditional routing on typed state, and cross-process thread persistence.
- `fernvale-archive` — routing verdict, supervisor, swarm, handoff trail.
  `orenford-newsroom` instead grades: parallel specialists merged by a reducer, a
  subgraph used as a node (hierarchy), a bounded critic re-work loop, and per-run cost
  and latency accounting.
- `tidewater-locks` / `ashford-grid` — windowed memory, cosine recall, interrupt/resume;
  critique gate and evaluator-optimizer. `redcliffe-signals` instead grades: an explicit
  ReAct trace whose observations are provably tool output, honest failure at the step cap,
  early-stopping judge-revise, and a memory store that survives process exit.
- `caldon-wire` — async concurrency at a live endpoint. No overlap.


---

## Build progress

- **`marlow-depot` (Docker, M3-L4) — DONE, validated.** Reference 50/50, five
  alternative shapes 50/50, six defect probes at 40/50 each losing exactly their
  own theme, fabrication probe 30/50, ordering matrix 7/7. Slowest check 13 s.
  See its `VALIDATION.md`.
- **`westmere-claims` (LangChain/LangGraph, M3-L5) — DONE, validated.**
  Reference 50/50, five alternative shapes 50/50, seven defect probes at 40/50
  each losing exactly one theme, fabrication probe 0/50, ordering matrix 7/7.
  Slowest check 2 s on a warm host. See its `VALIDATION.md`.
- **`orenford-newsroom` (Multi-agent, M3-L6) — DONE, validated.** Reference 50/50,
  five alternative topologies 50/50, four single-theme defect probes, two honest
  multi-theme ones, one instructive 0/50 (LangGraph refuses a fan-out with no
  reducer), fabrication probe 0/50, ordering matrix 6/6.
- **`thistledown-mill` (CrewAI, M3-L7) — DONE, validated.** Reference 50/50, six
  alternative shapes 50/50, six single-theme defect probes, canned-tool probe
  40/50 (loses only the data-source theme), ordering matrix 6/6. Slowest check
  4-6 s after batching tool calls into one interpreter start.
- Key CrewAI findings, all established by experiment and written up in that
  pack's VALIDATION.md: 0.203 does **not** use function calling by default;
  `Observation:` appears in its own format instructions so it cannot be used to
  detect a tool result; it asks a 20-second interactive question on first run per
  project directory; and omitting `context=` on a task is **not** a defect in a
  sequential crew.
- (superseded note) `crewai>=0.130,<1.0` resolves to
  **0.203.2** on linux/amd64 CPython 3.13 with `--only-binary=:all:`;
  **2 m 41 s** under x86 emulation, 643 MB of site-packages. It has to go in the
  detached setup job with a generous `deps.ready` wait.
- **`redcliffe-signals` (ReAct/Reflection/Memory, M3-L8) — DONE, validated.**
  Reference 50/50, five alternative shapes 50/50, five single-theme defect probes
  plus two honest multi-theme ones, fabrication probe 20/50, ordering matrix 7/7.
  Standard library only, so the lightest pack here to provision.
- **`lambwell-market` (Browser automation, M3-L9) — DONE, validated.**
  Reference 50/50, five alternative shapes 50/50, six single-theme defect probes,
  fabrication probe 0/50, ordering matrix 7/7. The checks never drive a browser -
  they read the artefacts and the site request log - so the slowest check is 1 s.
  (superseded note) Playwright chromium
  plus `install-deps` is the one dependency that cannot be pre-baked into the
  portal image; it goes in the detached job, and the checks lean on artifacts the
  learner has already produced.

### Reusable scaffolding, now proven twice

`gen_tests.sh` (one preamble, five bodies) + `build.sh` (template expansion,
consistency checks, zip staging, learner-surface grep) + `run-all.sh` +
`sweep.sh` + `validation/permutations.sh`. Copy from `westmere-claims` for a
Python lab and from `marlow-depot` for a Docker one.

Two harness bugs worth not reintroducing:

- A per-call time bound multiplied by the number of learner invocations blows the
  portal cap. Share one `HARD_DEADLINE` across the check and shrink each call
  bound as it approaches.
- A local harness must never reuse a service already on its port, and must export
  the service address into the learner run. Otherwise a candidate is graded
  against a dying service and the row reads as a broken solution.

---

## All six done. Cross-pack lessons worth not relearning

1. **A bound or a spawn that quietly does nothing is the worst failure mode.**
   `timeout` absent on macOS; `setsid` absent on macOS; a heredoc piped into
   `python3 -` arriving empty because a backgrounded job has stdin on
   `/dev/null`. Each one looked like a passing test or a broken candidate. Probe
   the capability, never assume it.
2. **Per-call time bounds multiply.** Share one `HARD_DEADLINE` across a check
   and shrink each call against it. Two packs needed this; the memory check in
   `redcliffe-signals` makes six invocations.
3. **Count interpreter starts, not computation.** Batching six tool calls into
   one start took `thistledown-mill`'s slowest check from 28 s to 4 s.
4. **The ordering matrix earns its keep every time.** It found the bug in
   `lambwell-market` (a learner re-running their own harvest was failed for it)
   and the ownership traps everywhere. The happy path was green throughout.
5. **Assert against a service, not against a response.** Every fabrication probe
   that scored above zero did so on a theme with no service-side cross-check.
   Where a theme is pure local arithmetic, say so in the docs rather than
   pretending otherwise.
6. **A defect probe that scores full marks is telling you something.** Three did:
   omitting `context=` in a sequential CrewAI crew is not a defect; LangGraph
   refuses an unreduced fan-out key outright; and a `report` message must not
   embed a command substitution whose quoted argument contains a double quote.

## Cross-pack fix, 2026-08-26: `pipefail` + `grep -q` made every verifier flaky

Chasing a live-VM report, `build.sh` in `marlow-depot` printed
`ERROR: dist/TestCase.zip has no scripts/ folder` on a zip that plainly had one
(`unzip -l` showed `scripts/` first in the listing). It reproduced about **1 run
in 5**.

The zip was never wrong. The check was:

```bash
unzip -Z1 "$z" | grep -q '^scripts/$' || { echo "ERROR: ..."; exit 1; }
```

`grep -q` exits the instant it matches. `scripts/` is the *first* entry, so
`unzip` still has six lines to write, gets SIGPIPE, and exits 141 — and under
`set -euo pipefail` that becomes the pipeline's status, so the `||` branch fires
even though grep succeeded. It is a race, which is why it was intermittent, and
why `data/` (the *last* entry, by which point unzip has already finished) never
misfired.

All seven packs had the identical three lines. Fixed by removing the pipe:

```bash
grep -q '^scripts/$' <<< "$(unzip -Z1 "$z")"
```

Verified: `marlow-depot` 0 failures in 20 consecutive builds (previously ~1 in
5 — so ~1.2% chance of that by luck), all seven packs 0 failures in 5 builds
each, and a negative test under `set -euo pipefail` confirming the new predicate
still reports `MISSING scripts/` for a zip without it and still catches a
`common.sh` smuggled into a test zip. A follow-up scan found no other
early-exiting pipeline (`| head`, `| grep -m`, `| grep -q`) in any `build.sh`.

**The rule:** under `pipefail`, never put an early-exiting consumer downstream of
a producer that has more to say. Use a here-string, or read the producer into a
variable first. This never touched a learner — `build.sh` is authoring-side only,
and no test script contains this shape — but it did mean the packs' own
verification could cry wolf on a correct zip, which is exactly the kind of noise
that gets a real signal ignored.

## The big one, 2026-08-26: the judge's ERR trap silently voided every submission

A no-op submit on the portal rendered an empty "Test Case Results:" list — no
rows, no messages, no error. Reading the platform's own `main.sh` and
`common.sh` off a live VM explained it, and reproducing it locally confirmed it.

`common.sh` ends with:

```bash
trap 'handle_script_error $LINENO $? "$BASH_COMMAND"' ERR
```

Every check sources that file, so **the trap is installed inside the check's own
shell**. An ERR trap fires on any non-zero simple command *regardless of
`set -e`* — including a deliberate `return 1` from a guard. Its handler POSTs an
internal error and exits, which prints a second line **after** our verdict.

`main.sh` grades `result=$(echo "$complete_result" | tail -n 1)` — the **last**
line of stdout+stderr. So the verdict was discarded, the last line matched
neither `"status": "failed"` nor `"status": "success"`, and `main.sh` raised
`"$script_path doesn't return response in correct format"`, which POSTs
`evaluated: false` with **no results array**. Hence a panel with nothing in it.

Reproduced with a replica of the real `common.sh`:

```
{ "status": "failed", "message": "the base images this lab needs are not ..." }
INTERNAL_ERROR: An error occurred at line 333: 'return' exited with status '1'
```

**Fix, all seven packs:** `trap - ERR` and `set +eE` immediately after sourcing
the helper. Verified: every check in all seven now emits exactly **one** line, a
parseable verdict, under the replica judge.

### Why local validation said 50/50 for months

The local `common.sh` was a *convenience stub* — `echo "RESULT:$1 | $2"`, no
ERR trap — and `run-all.sh` searched for the **first** `RESULT:` line anywhere in
the output. Both differences hid the bug. A stub easier to satisfy than the real
helper makes validation worthless, and this cost a whole collection.

Both are now faithful: the stub is a copy of the real helper (jq JSON output, ERR
trap, `handle_internal_error` that exits), and `run-all.sh` grades the **last
line** exactly as `main.sh` does, with a loud `[!!!!] UNPARSEABLE` branch that
says the portal would report no test cases at all. Negative control: deleting
`trap - ERR` from one check makes the harness flag it immediately.

### Two consequences still open

- **`main.sh` `break`s at the first failing case.** Partial credit is a
  *prefix*, not a per-theme sum: a solution that fails check 1 never runs checks
  2-5, so it scores 0/50 rather than 40/50. Every "loses exactly its own theme →
  40/50" figure in the VALIDATION files assumes independent checks and is only
  literally true for a defect in check 5. If we want fair partial credit, checks
  must be **ordered fundamental → advanced** in every pack.
- **`TIME_LIMIT` defaults to 40 s per script** (`TIME_LIMIT="${TIME_LIMIT:-40}"`),
  presumably from the portal's Time Limit field. The packs are budgeted against
  ~120 s — `marlow-depot`'s cold-start check is ~101 s worst case. At 40 s a
  *correct* solution times out, and since a timeout also `break`s the loop, it
  takes the rest of the run with it. The configured value needs checking before
  anything else here matters.

---

## Five more labs (M3-L13, L15, L16, L17, L18)

Curriculum classes covered (module-3 assessment numbering, `M3-L<n>`):

- **M3-L13 Parsing Complex Documents**              -> `ashcombe-intake/`
- **M3-L15 LLM-as-a-Judge & Advanced Evaluation**   -> `bellhaven-rubric/`
- **M3-L16 Human-in-the-Loop & BDI Architecture**   -> `pelham-approvals/`
- **M3-L17 Advanced Security & Production Readiness** -> `caverly-trust/`
- **M3-L18 Rapid Prototyping & Low-Code Tools**     -> `norbury-flow/`

### Deliverable shapes, continued

The first six used up: Dockerfiles, a CLI, an HTTP service, a configured
project, a module-per-pattern plus a store, artefact-writing pipeline scripts,
an async client. These five add:

7. `ashcombe-intake`  — **a spool worker.** The unit of work is discovered, not
   declared: documents arrive in a folder and the worker drains it.
8. `bellhaven-rubric` — **a regression gate.** Four stage modules plus a command
   that ends in an exit code a pipeline can read.
9. `pelham-approvals` — **a service that waits.** An HTTP service whose whole
   point is that a request can pause for days and be resumed by a webhook.
10. `caverly-trust`   — **a policy layer around code you may not change**, plus
    an audit artefact, exercised by a red-team campaign.
11. `norbury-flow`    — **a compiler.** Someone else's exported artefact becomes
    running Python.

### Freshness against the first six

- `caldon-wire` graded concurrency at an endpoint; `pelham-approvals` grades the
  opposite — a single request that deliberately stops and is finished later.
- `orenford-newsroom` was also an HTTP service, but its mechanic was fan-out and
  merge. `pelham-approvals` grades interrupt, checkpoint, thread isolation and
  webhook resume, and none of those appear there.
- `tidewater-locks` (never shipped) had interrupt/resume from a CLI. This is the
  webhook shape from the same class's Section 6, with BDI state as its own
  theme, and the replay/unknown-thread/bad-decision safety as a fifth.
- `redcliffe-signals` had a judge-revise loop; `bellhaven-rubric` grades the
  *measurement* side — stratification, kappa, escalation — which nothing else
  touches.
- `lambwell-market` wrote artefacts from four fixed scripts; `ashcombe-intake`
  discovers its work list and is graded on idempotency and cost, not artefacts
  alone.

### Cross-pack lessons from this batch

1. **A helper called inside `$( )` cannot report an exit code.** `run_gate` set
   `GATE_RC` in a subshell, so every "and it exited non-zero" assertion in two
   packs was vacuous. Exit codes now go through a file. This is the same class
   of bug as the inert `timeout`: it looks like a check and is not one.
2. **`cmd & echo $!` inside a subshell records the wrapper, not the program.**
   Killing that pid left a service running, later runs silently reused it, and
   two ordering rows failed. `( cd X && exec env ... prog ) &` makes `$!` the
   program. Only the local harnesses had it; the shipped checks were fine.
3. **A service the checks start must be stopped by the checks.** A root-owned
   process holding the learner's port is a lab they cannot get back into.
   `pelham-approvals` stops only what it started, and the matrix asserts the
   port is free afterwards.
4. **A stateful desk outlives a grading run.** `ashcombe-intake` keys its
   records by run id, the run ids are fixed, and a second grading pass therefore
   saw every document parsed twice. Each check now clears its own run first.
   Deltas (`pelham-approvals`) and per-attempt ids (`caverly-trust`) are the
   other two ways out.
5. **Writing the second implementation is how you find the over-strict check.**
   Three false negatives were caught that way and only that way: an exact
   artefact count that failed a worker writing its own manifest, a cycle
   refusal that had to name one specific node, and `StateGraph(dict)` — which
   turned out **not** to be a valid alternative at all, because the fields do
   not survive.
6. **Grade at the service, not at the return value.** Every fabrication probe in
   this batch that scored above 20/50 did so on a theme with no service-side
   cross-check. Where the desk records what it was handed — the strategy, the
   temperature, the tool list, the prompt text, the number of prompts sent — a
   canned answer scores 20-40/50 and the message says exactly why.

---

# Five more labs (M3-L13, L15, L16, L17, L18)

Curriculum classes covered, continuing the same numbering:

- **M3-L13 Parsing Complex Documents**              -> `ashcombe-intake/`
- **M3-L15 LLM-as-a-Judge & Advanced Evaluation**   -> `bellhaven-rubric/`
- **M3-L16 Human-in-the-Loop & BDI Architecture**   -> `pelham-approvals/`
- **M3-L17 Advanced Security & Production Readiness** -> `caverly-trust/`
- **M3-L18 Rapid Prototyping & Low-Code Tools**     -> `norbury-flow/`

(Markdown lecture files are `L12`, `L14`, `L15`, `L16`, `L17`; the curriculum
numbering is one higher from L3 on.)

## Five more deliverable shapes, none of them repeated

1. `ashcombe-intake`  — **a spool worker.** The unit of work is discovered, not
   declared: `python3 -m intake.worker --once` drains a directory, writes an
   artefact per document and appends to a ledger.
2. `bellhaven-rubric` — **a regression gate.** Four modules, one per stage, and
   a command line that ends in an exit code a pipeline can act on.
3. `pelham-approvals` — **a service that waits.** A long-running HTTP service
   whose graph pauses mid-flight and is resumed days later by a webhook.
4. `caverly-trust`    — **a policy layer plus an audit artefact.** Four rails at
   four hook points around an agent the learner never edits, exercised by a
   red-team campaign.
5. `norbury-flow`     — **a flow compiler.** Reads a visual builder's export,
   refuses what cannot run, and builds the runtime it describes.

## Freshness against the first six

- `westmere-claims`/`orenford-newsroom` own LCEL, reducers, routing, subgraphs
  and cost accounting. `pelham-approvals` takes none of those: its subject is a
  durable pause, a webhook resume, and BDI state as first-class fields.
- `redcliffe-signals` owns the ReAct trace and the judge-revise loop.
  `bellhaven-rubric` instead grades the *evaluation* of such a system: stratified
  sampling, symbolic equivalence, rubric parsing, Cohen's kappa and escalation.
- `lambwell-market` owns pipeline scripts writing artefacts. `ashcombe-intake`
  differs where it counts — the work list is discovered, and idempotency by
  content hash and failure isolation are the graded themes.
- `caverly-trust` and `norbury-flow` have no antecedent in the collection at all.

## Target image

All five run on **systemd Ubuntu** (Ubuntu 25.04 / Python 3.13). Pip footprint,
smallest first: `norbury-flow` and `caverly-trust` need **nothing**;
`ashcombe-intake` needs `pymupdf==1.24.14`; `bellhaven-rubric` needs
`sympy==1.13.3`; `pelham-approvals` needs `langgraph`/`langchain-core`.

## Cross-pack lessons from this batch

1. **A helper called inside `$( )` runs in a subshell, so an exit code it
   assigns never reaches the caller.** `rc=$GATE_RC` after
   `out="$(run_gate ...)"` read a stale zero, which made two "must exit
   non-zero" assertions vacuous in two packs at once. Exit codes are now written
   to a file and read back with `last_rc`.
2. **`( cmd & echo $! >pid )` records the wrapper, not the program.** Killing
   that pid left the service running, later runs reused a service nobody owned,
   and the ordering matrix reported a port the learner could not get back.
   `( ... exec cmd ) &` then `echo $!` is the fix. Same family as the absent
   `timeout` and absent `setsid` traps.
3. **`grep -q` closes the pipe on its first match.** Under `set -o pipefail`
   the SIGPIPE that gives `unzip` turns into a build failure about half the
   time. Capture the listing first. (The six earlier packs use a herestring and
   were never affected.)
4. **A service the checks start is state the checks own.** Where a lab's
   deliverable is a running service, each check starts one only if none is
   answering and stops the one *it* started from its `EXIT` trap — otherwise
   grading leaves a root process on the learner's port.
5. **A stub service remembers previous grading runs.** Run ids in checks are
   fixed, so the second grading pass on a VM sees the first pass's calls. Reset
   the run before counting, or measure deltas. `ashcombe-intake` lost 10 points
   on rows 3-7 of its matrix until it did.
6. **Writing the second implementation is how you find the false negative.**
   Three of the five packs had an assertion that failed a correct solution, and
   all three were caught by an alternative rather than by review: an extra
   manifest file failing an exact artefact count; `StateGraph(dict)` genuinely
   not retaining fields (a real limitation, not a false negative — that
   alternative was dropped); and a depth-first cycle detector naming the other
   node of the same cycle.
