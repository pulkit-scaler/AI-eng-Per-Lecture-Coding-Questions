# Westmere Claims Desk — Build `claimctl`

## Overview

Westmere Mutual takes motor claims by phone. A handler types the story into a
first-notification screen, the desk turns it into a structured triage record,
that record decides which queue the file joins, and a settlement quote is drawn
against the policy limit. Handlers also want to pick a conversation back up
tomorrow morning exactly where they left it last night.

None of that is a notebook. It is a **command-line program** that operators run,
scripts call, and a cron job drives — so that is what you build:
`claimctl`, with five subcommands.

The chat model, the claims file, the prompts and the three desk tools are
already written. **You write the program**: its subcommands, its schemas, its
graph, its retry loop and its store.

## Learning objectives

- Get a **validated, typed record** out of a model call instead of parsing prose,
  and drive it from a small **LCEL** chain.
- Give each piece of graph state the **reducer** it needs: append-only history,
  and a counter that clamps instead of growing without limit.
- **Route on typed state**, never on words in the text the model was given.
- Keep a loop **provably terminating** with an attempt cap in code, and make the
  exhausted path an explicit, honest outcome rather than a guess.
- Bound a **retry** around a validator and record why each attempt was refused.
- Persist a run under a **thread id** so a later process continues from what an
  earlier one left behind, and keep threads isolated from one another.
- Read a finished conversation back out of the store for audit.

## Environment

The VM is already provisioned — you install nothing.

- Python 3 with these preinstalled and importable: `langchain` **1.2.15**,
  `langchain-core` **1.3.0**, `langgraph` **1.1.9**,
  `langgraph-checkpoint-sqlite` **3.0.3**, `pydantic` **2.13.3**.
- Those packages, their own dependencies and the Python **standard library** are
  all you have. **`numpy`, `pandas` and `scikit-learn` are not installed.** A
  stray `import numpy` at the top of your program fails every subcommand, not
  just the one you wanted it for.
- The claims desk is already running on `http://127.0.0.1:8571` and is what the
  provided model and tools talk to. Leave it running. Check it with
  `curl -s http://127.0.0.1:8571/health`.
- Work in `/home/user/westmere-claims` and run everything from that directory,
  so `import claim_kit` resolves and the relative paths below line up.
- Each graded invocation of your program gets a bounded time budget well under
  two minutes, so keep every loop bounded. A graph that cannot finish is
  recorded as a failed check rather than hanging.

## What is provided

Under `/home/user/westmere-claims/`:

```
claim_kit/
  model.py       get_chat_model() - a chat model with .with_structured_output()
  claims.py      load_claim(claim_id), claim_ids()
  prompts.py     the system prompts and the request builders, plus the limits
  tools.py       policy_lookup, payout_table, fraud_history
data/claims.json the claims on file: claim_id, policy, reported, narrative
state/           where your store goes
check_local.py   runs every subcommand and prints exactly what it printed
claimctl.py      the starter - this is the file you write
```

Everything is reachable from one import:

```python
import claim_kit as kit

kit.get_chat_model()          # .invoke(messages) and .with_structured_output(S)
kit.load_claim("WM-3102")     # {"claim_id","policy","reported","narrative"}
kit.claim_ids()
kit.triage_prompt(claim_id, narrative, attempt)
kit.settlement_prompt(claim_id, narrative, attempt, correction)
kit.TRIAGE_SYSTEM, kit.SETTLEMENT_SYSTEM, kit.CHAT_SYSTEM
kit.CONFIDENCE_FLOOR        # 0.55
kit.MAX_TRIAGE_ATTEMPTS     # 3
kit.STEP_CEILING            # 4
kit.MAX_SETTLE_ATTEMPTS     # 3
kit.policy_lookup.invoke({"claim_id": ...})
kit.payout_table.invoke({"category": ..., "severity": ...})
kit.fraud_history.invoke({"policy": ...})
```

**Build every request with `kit.triage_prompt` and `kit.settlement_prompt`.**
The desk reads the `Claim:` and `Attempt:` lines those helpers write; a request
assembled by hand is a request about some other claim, or about attempt one
forever.

## Interface contract

Fix these exactly; everything else is yours.

- The program is `/home/user/westmere-claims/claimctl.py`, run as
  `python3 claimctl.py <subcommand> [flags]` from the project directory.
- Five subcommands, with these flags:
  - `triage --claim <ID>`
  - `route --claim <ID>`
  - `settle --claim <ID>`
  - `chat --thread <NAME> --say <TEXT>`
  - `trail --thread <NAME>`
- Each one prints **one JSON object on stdout, last**. Anything you print
  before it is ignored, so debug output is safe.
- The keys each subcommand must print are listed in its task below.
- Thread state lives in **`state/claims.db`**, relative to the project
  directory.
- Every model call goes through `kit.get_chat_model()`, and every tool call
  through the three tools in `claim_kit`. That is what attributes work to your
  run.
- Your own helper modules may live beside `claimctl.py`. Only the command line
  and the JSON are fixed.

---

### Task 1 — `triage`: a validated record out of a chain

1. Define a Pydantic model for the triage record with exactly these fields:
   `claim_id` (str), `category` (one of `collision`, `theft`, `weather`,
   `glass`), `severity` (one of `low`, `medium`, `high`, `critical`),
   `needs_adjuster` (bool), `fraud_score` (float, 0 to 1 inclusive),
   `confidence` (float, 0 to 1 inclusive), `summary` (str).
2. Build the request with `kit.triage_prompt(claim_id, narrative, attempt)`,
   with `attempt` starting at 1.
3. Send it through `kit.get_chat_model().with_structured_output(...)`, so what
   comes back is an instance of your model rather than text you have to parse.
4. Print the record as JSON with every field named above.

**Requirements.** Constrain `category` and `severity` with a `Literal`, and
`fraud_score` and `confidence` with numeric bounds, so an out-of-range value is
a validation error and not a number that quietly poisons the rest of the run.
One triage is **one** request to the desk. Some narratives mention a second
claim number in passing; the file being triaged is the one named on the command
line.

**Example.**

```
$ python3 claimctl.py triage --claim WM-3102
{"claim_id": "WM-3102", "category": "collision", "severity": "low",
 "needs_adjuster": false, "fraud_score": 0.05, "confidence": 0.88,
 "summary": "Car park scuff, third party admitted fault, car drivable."}
```

---

### Task 2 — `route`: a graph that decides which queue the file joins

Build a `StateGraph` with a typed state, a triage step, a classify step and
three branch steps.

1. State keys: the claim id, the attempt number, the record, the chosen branch,
   the evidence the branch gathered, an **audit list**, and a **step counter**.
2. The triage step runs Task 1 at the current attempt number and writes the
   record into state.
3. After the triage step, a **conditional edge**:
   - if the record's `confidence` is below `kit.CONFIDENCE_FLOOR` and fewer than
     `kit.MAX_TRIAGE_ATTEMPTS` attempts have been made, go back to triage and
     ask again at the next attempt number;
   - otherwise go on to classify.
4. The classify step picks the branch **from the record**, in this order:
   - the confidence floor was never cleared → `adjuster`;
   - else `fraud_score` at or above 0.7 → `fraud_review`;
   - else `severity` is `high` or `critical`, or `needs_adjuster` is true →
     `adjuster`;
   - else → `fast_track`.
5. A second conditional edge sends the run to the branch step that state names.
   Each branch consults exactly one tool: `fast_track` → `kit.payout_table`,
   `adjuster` → `kit.policy_lookup`, `fraud_review` → `kit.fraud_history`.
6. Every step appends its own name to the audit list, in visit order, and adds 1
   to the step counter.
7. Print `claim_id`, `branch`, `attempts` (how many times the triage step ran),
   `steps`, `audit` and `tool` (the name of the tool the branch used).

**Requirements.** The audit list must **accumulate** — a plain assignment
overwrites it and you will report one step. The step counter must **clamp at
`kit.STEP_CEILING`**, so a run with more visits than the ceiling reports the
ceiling while the audit list still shows every visit. Give each key the reducer
that behaviour needs. The branch decision must read the typed record; a
narrative that happens to contain the word *fraud* is not a fraud referral.

**Example.**

```
$ python3 claimctl.py route --claim WM-3102
{"claim_id": "WM-3102", "branch": "fast_track", "attempts": 1, "steps": 3,
 "audit": ["triage", "classify", "fast_track"], "tool": "payout_table"}
```

---

### Task 3 — `settle`: a bounded retry around a validator

1. Define a Pydantic model for a settlement quote: `claim_id` (str), `amount`
   (float), `basis` (str).
2. Read the settlement limit for the claim with
   `kit.policy_lookup.invoke({"claim_id": ...})`; the answer has a `cap`.
3. Ask the desk for a quote with
   `kit.settlement_prompt(claim_id, narrative, attempt, correction)`, through
   `with_structured_output`, starting at attempt 1 with no correction.
4. A quote is acceptable when the amount is **greater than zero and no greater
   than the cap**. On an acceptable quote, stop: status `approved`, with that
   amount.
5. On an unacceptable quote, write down a note in exactly this form and pass it
   back as the `correction` on the next attempt:
   `attempt <n> quoted <amount> over the <cap> settlement cap`
   with the amount and the cap as whole numbers.
6. After `kit.MAX_SETTLE_ATTEMPTS` refused quotes, stop anyway: status
   `escalated`, `amount` null, and every note kept.
7. Print `claim_id`, `attempts`, `status`, `amount` and `notes`.

**Requirements.** The loop is bounded **in code**. Asking the desk once more
than the cap allows is not a near miss, it is an unbounded loop that happened to
stop. This task needs no graph: a loop over `range` and one `if` is the whole
thing.

**Example.**

```
$ python3 claimctl.py settle --claim WM-3102
{"claim_id": "WM-3102", "attempts": 1, "status": "approved", "amount": 1240.0,
 "notes": []}
```

---

### Task 4 — `chat`: a conversation that survives the process

1. Build a small graph whose state holds the message history, merged with
   LangGraph's message reducer so each turn appends rather than replaces.
2. Its one node sends `kit.CHAT_SYSTEM` plus the whole history to
   `kit.get_chat_model()` and appends the reply.
3. Compile it with a **checkpointer backed by `state/claims.db`**, and invoke it
   with the thread id from `--thread`.
4. Add only the new human turn to the invocation. The turns already on the
   thread come back from the store; sending them again asks the desk to answer
   things it has already answered.
5. Print `thread`, `turn` (how many human turns this thread now has, counting
   this one) and `reply` (what the desk just said).

**Requirements.** The store must be on disk, because each invocation is a
**separate process**: the second `claimctl chat` on a thread is a new
interpreter that has to find the first one waiting for it. Two different
`--thread` values are two different conversations and must not see each other.
Create `state/` if it is not there.

**Example.**

```
$ python3 claimctl.py chat --thread t1 --say "my policy is WM-P-4410"
{"thread": "t1", "turn": 1,
 "reply": "Noted, policy WM-P-4410. Tell me what happened and I will open a file."}
$ python3 claimctl.py chat --thread t1 --say "what policy did I give you?"
{"thread": "t1", "turn": 2,
 "reply": "Your policy on file is WM-P-4410. I have that from earlier in this conversation."}
```

---

### Task 5 — `trail`: read the conversation back for audit

1. Compile the same graph against the same store.
2. Read the current state for the thread named by `--thread` — do not run the
   graph, and do not call the desk.
3. Print `thread`, `turns` (the number of human turns on it) and `messages`, a
   list of `{"role": "human"|"ai", "content": "..."}` in the order they were
   said.
4. A thread that has never been used is not an error: report `turns` 0 and an
   empty list.

**Requirements.** Everything printed here comes out of the store. If `trail`
has to ask the desk anything, the history is not really persisted.

**Example.**

```
$ python3 claimctl.py trail --thread t1
{"thread": "t1", "turns": 2, "messages": [
  {"role": "human", "content": "my policy is WM-P-4410"},
  {"role": "ai", "content": "Noted, policy WM-P-4410. Tell me what happened and I will open a file."},
  {"role": "human", "content": "what policy did I give you?"},
  {"role": "ai", "content": "Your policy on file is WM-P-4410. I have that from earlier in this conversation."}]}
```

---

## Run and verify before you submit

```bash
cd /home/user/westmere-claims

curl -s http://127.0.0.1:8571/health
python3 check_local.py            # every subcommand, and what it printed

# the ones worth trying by hand - one claim down each branch
python3 claimctl.py route  --claim WM-3102   # fast_track
python3 claimctl.py route  --claim WM-3290   # adjuster
python3 claimctl.py route  --claim WM-3126   # fraud_review
python3 claimctl.py settle --claim WM-3117
python3 claimctl.py chat   --thread mine --say "my policy is WM-P-4469"
python3 claimctl.py chat   --thread mine --say "what policy did I give you?"
python3 claimctl.py trail  --thread mine
ls -l state/
```

`check_local.py` runs your program the same way the checks do — as a separate
process, taking the last JSON object on stdout. If a key is missing there, it is
missing when you are graded. Its `route` cases send one claim down each of the
three branches, so every branch step runs at least once before you submit.

## How you are graded

Five checks, 10 points each, 50 in total. Each one runs your program and reads
what it printed, alongside what the desk saw:

1. **Triage records.** Three claims, every field correct, one request each,
   through the provided model.
2. **Routing.** Three claims to three different branches, decided by the record,
   each consulting exactly the one tool its branch owns.
3. **The loop.** A claim that resolves on a second look and one that never
   resolves: the right number of attempts, a complete audit trail, a clamped
   step counter, and the honest branch on exhaustion.
4. **Settlement.** One quote approved on the first attempt, one refused three
   times and escalated with no amount and every note kept — and the desk asked
   exactly as many times as the cap allows.
5. **Threads.** Three turns in three separate processes, recall across them,
   isolation between threads, a trail read back out of the store, and no
   re-answering of turns that already happened.
