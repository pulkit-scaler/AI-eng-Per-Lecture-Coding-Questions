# Orenford Dispatch — Run the Newsroom

## Overview

The Orenford Dispatch commissions a briefing, sends it to three source desks,
has it written, and puts it past the night editor before it goes out. Reporters
do not run that by hand — the desk runs it as a **service**, and editors
commission a briefing by posting an assignment number to it.

The chat model, the three source desks, the prompts and the HTTP plumbing are
already written. **You build the newsroom**: the plan, the research pass across
three desks, the writer, the night editor loop, and the accounting that says
what the run cost.

## Learning objectives

- Use **structured output as the contract between agents**, so each stage hands
  the next one a validated record instead of prose to re-parse.
- Fan work out to several workers and **merge their results with a reducer**,
  rather than letting the last one to finish overwrite the rest.
- Keep one failing worker from taking the whole run with it, and **record what
  the result does not cover**.
- Put a **hard cap** on a reviewer loop in code, and make the exhausted path an
  explicit, honest outcome rather than a silent one.
- Keep **every claim traceable to a source**, and drop a source the desk is not
  allowed to cite.
- **Account for what a run actually cost**, per role, from what happened rather
  than from what was expected.

## Environment

The VM is already provisioned — you install nothing.

- Python 3 with these preinstalled and importable: `langchain` **1.2.15**,
  `langchain-core` **1.3.0**, `langgraph` **1.1.9**,
  `langgraph-checkpoint-sqlite` **3.0.3**, `pydantic` **2.13.3**.
- Those packages, their own dependencies and the Python **standard library** are
  all you have. **`numpy`, `pandas` and `scikit-learn` are not installed.** A
  stray `import numpy` stops the service from starting at all.
- The newsroom wire is already running on `http://127.0.0.1:8317` and is what
  the provided model and desks talk to. Leave it running. Check it with
  `curl -s http://127.0.0.1:8317/health`.
- **Your service listens on `http://127.0.0.1:8300`.**
- Work in `/home/user/orenford-newsroom` and start your service from that
  directory, so `import news_kit` resolves and `data/assignments.json` is found.
- Each commissioned briefing gets a bounded time budget well under two minutes,
  so keep every loop bounded. A graph that cannot finish is recorded as a failed
  check rather than hanging.

## What is provided

Under `/home/user/orenford-newsroom/`:

```
news_kit/
  model.py       get_chat_model(role) - .invoke() and .with_structured_output()
  desks.py       records_desk, wire_desk, people_desk, DESK_TOOLS, WireError
  assignments.py load_assignment(id), assignment_ids()
  prompts.py     the four system prompts, the request builders, the limits
  service.py     run_service(handler) - the HTTP plumbing
data/assignments.json  the assignment queue
check_local.py   commissions a few briefings against your running service
serve.py         the starter - this is the file you write
```

Everything is reachable from one import:

```python
import news_kit as kit

kit.load_assignment("OR-4102")   # {"assignment","commissioned","brief"}
kit.assignment_ids()
kit.get_chat_model(role)         # role: planner researcher writer critic
kit.records_desk, kit.wire_desk, kit.people_desk
kit.DESK_TOOLS                   # {"records": ..., "wire": ..., "people": ...}
kit.DESK_ORDER                   # ("records", "wire", "people")
kit.MAX_REVISIONS                # 2
kit.WireError                    # raised when a desk is out of service
kit.PLANNER_SYSTEM, kit.RESEARCHER_SYSTEM, kit.WRITER_SYSTEM, kit.CRITIC_SYSTEM
kit.plan_prompt, kit.research_prompt, kit.draft_prompt, kit.critique_prompt
kit.run_service(handler)
```

**Build every request with the prompt helpers.** The wire reads the
`Assignment:` and `Attempt:` lines they write; a request assembled by hand is a
request about some other assignment, or about attempt one forever.

`get_chat_model(role)` tags the call with the role making it. That tag is how
the newsroom accounts for its own work, so the planner must ask for a planner
model, the writer for a writer model, and so on.

## Interface contract

- The service is `/home/user/orenford-newsroom/serve.py`, started with
  `python3 serve.py` from the project directory, listening on
  **`127.0.0.1:8300`**.
- `kit.run_service(handler)` answers `GET /health` for you and routes
  `POST /brief` to your handler. The request body is
  `{"assignment": "OR-####"}`; whatever dict your handler returns is the
  response body.
- The response must contain these keys:
  - `assignment` — the assignment number
  - `status` — `"published"` or `"published_with_reservations"`
  - `headline` — the writer headline
  - `sections` — the draft sections
  - `claims` — a list of `{"claim": ..., "source_id": ...}`
  - `sources` — the source ids the claims cite, **unique and sorted**
  - `sub_questions` — the three sub-questions from the plan, in plan order
  - `findings` — the desk findings the briefing is built on
  - `excluded` — what was left out, each entry with a `desk` and a `reason`
  - `revisions` — how many times the night editor sent the draft back
  - `reservations` — the night editor issues still outstanding when it went out
  - `audit` — the steps the run visited, in order
  - `accounting` — `planner`, `researcher`, `writer`, `critic` and `total_calls`
- Sub-question **index decides the desk**: `sub_questions[0]` goes to the
  records desk, `[1]` to the wire desk, `[2]` to the people desk. That order is
  `kit.DESK_ORDER`.
- The wire answers a record by **the name of the model** it is asked for, so
  name yours `Plan`, `Finding`, `Draft` and `Critique`. Fields are yours to
  arrange; the names are not.
- Every model call goes through `kit.get_chat_model(role)` and every desk
  lookup through the tools in `news_kit`.
- Your own helper modules may live beside `serve.py`. Only the service, the
  endpoint and the response keys are fixed.

---

### Task 1 — Plan the assignment

1. Define a Pydantic model for the plan: `assignment` (str), `angle` (str) and
   `sub_questions` — a list of **exactly three** strings. Constrain that length
   in the schema, so a plan with two or four sub-questions is a validation error
   rather than a run that quietly skips a desk.
2. Build the request with `kit.plan_prompt(assignment_id, brief)` and send it
   through `kit.get_chat_model("planner").with_structured_output(...)`.
3. Put the plan into your graph state, and report its `sub_questions` in the
   response, in plan order.

**Requirements.** One assignment is one planner call.

**Example.**

```
$ curl -s -X POST http://127.0.0.1:8300/brief \
       -H 'Content-Type: application/json' -d '{"assignment":"OR-4102"}' \
  | jq '{sub_questions, accounting}'
{
  "sub_questions": [
    "which committee approved closing the two sites and on what date",
    "what the tonnage forecast was before and after the decision",
    "what the site staff were told and when"
  ],
  "accounting": {"planner": 1, "researcher": 3, "writer": 1, "critic": 1,
                 "total_calls": 6}
}
```

---

### Task 2 — Research the three desks and merge what comes back

1. Give each desk its own step. The step for desk *i* takes
   `sub_questions[i]`, calls that desk tool with the assignment and the
   sub-question, and turns the answer into a finding through
   `kit.get_chat_model("researcher").with_structured_output(Finding, desk=...)`.
   Build that request with
   `kit.research_prompt(assignment_id, desk, question, note)`, where `note` is
   what the desk answered.
2. Define a Pydantic model for a finding: `assignment`, `desk`, `sub_question`,
   `source_id`, `note`, and `blocked` (bool, default false).
3. The three desk steps write into **one** findings list on the state. Give that
   key a **reducer** so each step contributes and nothing is lost — a list that
   is assigned rather than merged keeps only the desk that finished last. No
   source may appear twice in the findings the briefing is built on; whether the
   duplicate goes in the reducer or on the way out is yours to decide.
4. A desk that is **out of service** raises `kit.WireError`. Catch it in that
   desk step: add an entry to `excluded` naming the desk and the reason, and
   leave the other desks alone. The briefing still goes out.
5. A finding whose `blocked` flag is true is a source the desk may not cite.
   Do not put it in the findings list; record it in `excluded` with a reason.

**Requirements.** All three desks are consulted on every assignment, even the
one whose desk is down — a desk has to be *asked* before it can be reported
unavailable. Running the desk steps as a nested graph of their own keeps the
failure contained and the merge in one place, but the shape is yours.

**Example.** On an assignment whose people desk is out:

```
$ curl -s ... -d '{"assignment":"OR-4199"}' | jq '{status, findings: [.findings[].desk], excluded}'
{
  "status": "published",
  "findings": ["records", "wire"],
  "excluded": [{"desk": "people", "reason": "desk unavailable", "detail": "..."}],
  "accounting": {"planner": 1, "researcher": 2, "writer": 1, "critic": 1,
                 "total_calls": 5}
}
```

---

### Task 3 — Write the briefing and put it past the night editor

1. Define Pydantic models for the draft (`assignment`, `headline`, `sections` of
   `{heading, body}`, `claims` of `{claim, source_id}`) and for the critique
   (`verdict` — `"accept"` or `"revise"` — plus `issues` and `instructions`).
2. The writer step builds its request with
   `kit.draft_prompt(assignment_id, angle, attempt, feedback)` and calls
   `with_structured_output(Draft, cited=<the findings>)`. Those extras travel to
   the wire as JSON, so hand it plain dicts rather than model objects.
   `attempt` is 1 on the first pass and increases by one each time the draft
   comes back.
3. The night editor step calls
   `kit.critique_prompt(assignment_id, headline, attempt)` through a critic
   model.
4. A conditional edge reads the verdict:
   - `revise`, and fewer than `kit.MAX_REVISIONS` rounds so far → back to the
     writer with the instructions as feedback, counting the round;
   - otherwise → publish.
5. On publication, if the last verdict was still `revise`, set `status` to
   `"published_with_reservations"` and put the night editor `issues` in
   `reservations`. Otherwise `status` is `"published"` and `reservations` is
   empty.

**Requirements.** The cap lives **in code**. A prompt asking the night editor to
be reasonable is not a cap. A briefing that goes out with reservations must say
what they were — dropping them is worse than the rework.

**Example.** On an assignment the night editor never accepts:

```
$ curl -s ... -d '{"assignment":"OR-4210"}' | jq '{status, revisions, reservations, accounting}'
{
  "status": "published_with_reservations",
  "revisions": 2,
  "reservations": ["the angle is not carried through the sections",
                   "no section answers sub-question 1"],
  "accounting": {"planner": 1, "researcher": 3, "writer": 3, "critic": 3,
                 "total_calls": 10}
}
```

---

### Task 4 — Keep every claim traceable

1. Build `sources` from the source ids the surviving claims actually cite —
   **unique and sorted**.
2. Drop any claim whose `source_id` is not one of the findings the briefing is
   built on. A claim citing a source that was excluded, or a source that never
   existed, does not go out.
3. `excluded` carries one entry per source left out, each with the desk and a
   reason — whether the desk was unavailable or the source may not be cited.

**Requirements.** Every id in `claims[].source_id` appears in `sources`, and
`sources` has no duplicates and is in order. This is the check an editor runs
before the briefing goes anywhere.

**Example.** On an assignment with a source that may not be cited:

```
$ curl -s ... -d '{"assignment":"OR-4224"}' | jq '{sources, claims: [.claims[].source_id], excluded}'
{
  "sources": ["SRC-4224-PEO", "SRC-4224-WIR"],
  "claims": ["SRC-4224-PEO", "SRC-4224-WIR"],
  "excluded": [{"desk": "records", "source_id": "SRC-4224-REC",
                "reason": "source may not be cited"}]
}
```

---

### Task 5 — Account for the run

1. Count what the run actually did, per role: `planner`, `researcher`, `writer`,
   `critic`.
2. Report `total_calls` as the sum of those four.
3. Report the steps the run visited in `audit`, in visit order, with a reducer on
   that key so each step appends its own name.

**Requirements.** The figures have to come from what happened, not from what a
normal run costs. Two assignments in the queue take a different number of writer
and night-editor passes from each other, and a block of numbers written out in
advance is wrong for one of them. Count the calls the run actually made: a desk
that was out of service raised before any researcher model was asked anything,
so it costs nothing.

**Example.** An assignment that takes one round of rework:

```
$ curl -s ... -d '{"assignment":"OR-4238"}' | jq '{revisions, accounting}'
{"revisions": 1,
 "accounting": {"planner": 1, "researcher": 3, "writer": 2, "critic": 2,
                "total_calls": 8}}
```

---

## Run and verify before you submit

Start your service and put a briefing through it by hand:

```bash
cd /home/user/orenford-newsroom

curl -s http://127.0.0.1:8317/health          # the wire
pkill -f serve.py                             # the last one you started, if any
nohup python3 serve.py > serve.log 2>&1 &     # your service, as it is now
curl -s http://127.0.0.1:8300/health

python3 check_local.py                        # a few briefings, in full

# the ones worth trying by hand
curl -s -X POST http://127.0.0.1:8300/brief -H 'Content-Type: application/json' \
     -d '{"assignment":"OR-4199"}' | jq .
tail serve.log
```

If a briefing comes back as a 500, the body carries the exception and
`serve.log` carries the traceback.

You do not have to restart anything before you submit. Each check starts
`serve.py` as it stands on disk, so your latest edit is always the one graded,
and the log it reports on holds that run and nothing else. What the checks will
not do is write the file.

## How you are graded

Five checks, 10 points each, 50 in total. Each one commissions a briefing from
your running service and compares the answer against what the wire actually saw:

1. **The research pass.** All three desks consulted, their findings merged into
   one list, the plan's three sub-questions reported, and a unique sorted source
   list.
2. **A desk that fails.** With one desk out of service the briefing still goes
   out, on the findings from the other two, with the unavailable desk recorded
   and a reason given.
3. **The night editor loop.** An accepted draft goes out with no rework; a draft
   that is never accepted stops at the cap, goes out with its reservations, and
   the writer and night editor are each called exactly as many times as the cap
   allows.
4. **Traceability.** A source that may not be cited is dropped from the claims
   and the source list and recorded as left out — after its desk was asked — and
   every remaining claim traces to a listed source.
5. **The accounting.** Two assignments, one of which takes a round of rework:
   every per-role figure and the total match what the wire received.
