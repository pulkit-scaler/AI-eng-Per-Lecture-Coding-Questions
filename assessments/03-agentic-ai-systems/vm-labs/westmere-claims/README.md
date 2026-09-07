# `westmere-claims` — LangChain & LangGraph Deep Dive (M3-L5)

A VM lab whose deliverable is a **command-line program**, not a module of
functions. The learner writes `claimctl.py` with five subcommands; the checks run
it as a separate process, read the JSON it prints, and cross-check that against
what the claims desk actually saw.

- **Target image:** *systemd Ubuntu*, which is really **Ubuntu 25.04 /
  Python 3.13.3** — no pip, no `ensurepip`, PEP 668 externally managed,
  password-gated `sudo`, no Docker.
- **Max Score 50 = 5 checks × 10.**
- **Project:** `/home/user/westmere-claims`. Claims desk on `127.0.0.1:8571`.
  Checkpoint store at `state/claims.db`.

## Why a CLI

Three things become gradeable that a single `solution.py` cannot express:

- **Thread persistence is real.** `chat --thread t1` twice is two interpreters.
  The second one only knows what the first said if the state genuinely reached
  disk, so an `InMemorySaver` fails the check instead of passing it.
- **Interpreter starts are visible.** The checks count them, and the heaviest
  check makes five, which is what drove the `HARD_DEADLINE` design below.
- **The interface is the contract.** Subcommands and printed keys are fixed;
  the internals — argparse or hand-rolled, one file or several, one graph or
  two — are not. Five different shapes score 50/50.

## The five themes

1. **Triage records** — three claims, every field of the record right, one
   structured request each, all through the provided model. One graded claim has
   a narrative that names a *different* claim number, so a program that reads
   the id out of the text instead of the command line answers the wrong file.
2. **Routing** — three claims to three different branches, decided from the
   typed record. One of them has the word *fraud* in its narrative and must
   still fast-track. Each branch has to consult exactly the one desk tool it
   owns, and the desk records which one ran.
3. **The loop** — one claim the desk resolves on the second look and one it never
   resolves. Graded on the attempt count, the number of desk requests matching
   it, the complete audit trail, the **clamped** step counter (audit length 5,
   steps 4), and the honest fallback branch on exhaustion.
4. **Settlement** — one quote inside the policy limit approved on the first
   attempt; one that is never inside it refused three times, escalated with a
   null amount and all three notes kept — and the desk asked exactly three
   times, not four.
5. **Threads** — three turns in three processes, recall across them, isolation
   between two threads, the trail read back out of `state/claims.db` by a fourth
   process, and no re-answering of turns that already happened.

## The desk

`service/claimsvc.py` is installed to `/opt/westmere-svc` as `root:root 0700`
and never appears under the learner project. It answers a structured-record
request, a chat turn and the three tool endpoints, all computed from a fixture
table keyed by claim identifier **and by the attempt number carried in the
prompt** — which is how "ask again and the desk is more confident" is
reproducible without any state living in the desk process.

The kit hands the learner a `BaseChatModel` subclass rather than
`langchain-openai`, so the lab needs no hosted model, no API key and no `openai`
wheel.

## Pack layout

```
app/                    everything provided, plus claimctl_stub.py
service/claimsvc.py     the desk (root-only, outside the project)
setup/                  setup_script.template.sh -> scripts/setup_script.sh
reference-solution/     the model answer, 5 alternative shapes, 7 defect probes,
                        1 fabrication probe
test-cases/scripts/     script_01..05.sh (shipped) + common.sh, run-all.sh
validation/             the ordering matrix
dist/                   Setup.zip + TestCase.zip
```

## Authoring commands

```bash
./gen_tests.sh                       # regenerate the checks from one preamble
./build.sh                           # verify invariants, restage both zips
PY=/path/to/venv/bin/python ./test-cases/scripts/run-all.sh
PY=... ./sweep.sh                    # every candidate, each on its own port
PY=... ./validation/permutations.sh   # ordering matrix (as root on the VM once)
```

`VALIDATION.md` records the observed numbers and the one item a non-VM host
cannot settle.
