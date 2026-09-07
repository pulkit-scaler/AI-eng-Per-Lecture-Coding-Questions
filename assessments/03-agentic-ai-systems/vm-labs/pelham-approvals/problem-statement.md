# Pelham — an approval agent that knows when to stop

## Overview

Pelham Group reimburses about four hundred expense claims a week. Most of them
are a team lunch or a rail fare and nobody should have to look at them. A few of
them are not, and those need a person — a person who is not sitting in a
terminal waiting, but who will click a button in a chat message some time in the
next two days.

You are going to build the agent that tells those two cases apart, and the
service around it that can **wait**. Not poll, not time out, not hold a request
open: pause where it is, keep everything it knew at that moment, and pick up
exactly there when the decision finally arrives over a webhook.

Its state is structured as **beliefs, desires and intentions** — not because it
is a nice acronym, but because in eighteen months a compliance reviewer is going
to ask what the agent knew when it approved something, and "it is in the message
log somewhere" is not an answer.

## Learning objectives

- Structure agent state so beliefs, desires and intentions are first-class
  fields that a reviewer can read.
- Keep business goals stable and human-set, and let only the intention respond
  to the claim in front of you.
- Pause a running graph mid-flight, surface what the reviewer needs, and commit
  nothing while it waits.
- Resume from a webhook, on the right thread, with an audit trail that only ever
  grows.
- Make the callback safe: the same button pressed twice, a decision for a claim
  that does not exist, a decision nobody defined.

## What is provided

Everything below is in `/home/user/pelham-approvals` and already works. Do not
modify anything under `pelham_kit/`.

- `pelham_kit.get_chat_model()` — the analyst. Call `.invoke(prompt)` and read
  `.content`. It returns a JSON object with `category_valid` (bool),
  `risk_level` (`low`, `medium` or `high`) and `reasoning` (a sentence) — often
  wrapped in a code fence, the way models do. It judges from the claim text you
  put in the prompt, so what you put in the prompt is what it sees.
- `pelham_kit.POLICY_THRESHOLD_USD` — the figure at and above which a person has
  to sign a claim off. It is `100`.
- `pelham_kit.VALID_CATEGORIES` — `meals`, `travel`, `software`,
  `office_supplies`.
- `pelham_kit.DESIRES` — the three business goals, written by the people who own
  the process.
- `check_local.py` — starts your service, walks a few claims through it and
  prints what came back.

The analyst answers on `http://127.0.0.1:8766`. Leave it running. LangGraph and
LangChain are installed for you; there is no key to set.

## Interface contract

Three files, with exactly these paths and names.

- `bdi/nodes.py` — the node functions `perceive(state)`, `deliberate(state)`,
  `human_review(state)`, `finalize(state)`, plus a router `route_decision(state)`
  and whatever node handles the automatic path. Each node returns a dict of
  state updates.
- `bdi/graph.py` — `build_graph()` returns a **compiled** graph that can pause
  and be resumed, with a checkpointer attached so each `thread_id` is its own
  independent conversation.
- `server.py` — the approval service. Running `python3 server.py` serves on
  **`127.0.0.1:8767`**, honouring `PELHAM_SERVICE_PORT` if it is set.

The service speaks exactly these four things:

- `GET /health` → `200` once it is serving.
- `POST /claims` with `{"thread_id": "<id>", "claim": {...}}` → `200` and a body
  carrying `thread_id`, `pending` (a bool), `interrupt` (what the reviewer is
  shown, or `null`) and `final_status`.
- `GET /claims/<thread_id>` → `200` and the full state of that thread:
  `beliefs`, `desires`, `intentions`, `audit_log`, `human_decision`,
  `final_status`, and `pending`. `404` for a thread that does not exist.
- `POST /webhook/approval` with `{"value": "<decision>|<thread_id>"}` → `200`
  and a body carrying `thread_id` and `final_status`. A `4xx` for anything it
  cannot or must not act on.

A claim is `{"employee": str, "amount_usd": number, "category": str,
"description": str}`. Everything else — extra state fields, extra endpoints,
helper modules, how you build the graph — is yours.

## Task 1 — Beliefs, desires and intentions as state

1. Write `perceive(state)`. It reads the incoming claim from `state["request"]`
   and writes `beliefs`: the employee, the amount, the category, the
   description, **and** the two policy facts the decision will be measured
   against — `policy_threshold_usd` and `valid_categories`. A belief set that
   omits the policy is a belief set nobody can audit a decision against.
2. Write `deliberate(state)` so it sets `desires` from `pelham_kit.DESIRES`.
   These are business goals. They are the same on every claim, and they do not
   come from a model — a reviewer has to be able to check that the agent was
   pursuing what the business asked for.
3. `deliberate` also forms `intentions`: a list, each entry a dict with at least
   an `action` naming what the agent has committed to doing.
4. Every node appends to `audit_log`, and each entry names the stage that wrote
   it — `perceive`, `deliberate`, `human review`, `finalize`. That log is the
   thing the reviewer reads.

**Requirements.** `beliefs`, `desires`, `intentions` and `audit_log` are fields
of the state, readable through `GET /claims/<thread_id>`. Not derived on
request, not reconstructed from messages.

**Example.** After a `45` meals claim from Priya Sharma has cleared:

    beliefs    {"employee": "Priya Sharma", "amount_usd": 45,
                "category": "meals", "description": "...",
                "policy_threshold_usd": 100,
                "valid_categories": ["meals", "travel", "software",
                                     "office_supplies"]}
    desires    the three goals from pelham_kit.DESIRES, unchanged
    intentions [{"action": "auto_approve", "reason": "..."},
                {"action": "process_reimbursement", "reason": "..."}]
    audit_log  ["[PERCEIVE] ...", "[DELIBERATE] ...", "[FINALIZE] ..."]

## Task 2 — Decide which claims a person has to see

1. In `deliberate`, put the claim to the analyst with
   `pelham_kit.get_chat_model()`. Include the employee, the amount, the category
   **and the description** in the prompt — the analyst judges from what you show
   it.
2. Read `category_valid`, `risk_level` and `reasoning` out of the reply. The
   reply is JSON, often inside a code fence. A reply you cannot parse is not
   permission to auto-approve.
3. A claim clears on its own **only** when all three hold: the amount is
   **strictly below** `POLICY_THRESHOLD_USD`, the analyst says the category is
   valid, and the analyst puts the risk at `low`. A claim at exactly the
   threshold goes to a person.
4. Anything else goes to a person, including a small claim in a perfectly valid
   category whose description is one the analyst flags.
5. Write `route_decision(state)` to select the next node from what `deliberate`
   decided.

**Requirements.** The decision has to use the analyst's answer, not the amount
alone and not a category list you match yourself. One analyst call per claim;
reading a claim back later must not run the agent again.

**Example.**

    45, meals,   "Team lunch during sprint planning"   -> clears on its own
    850, software, "JetBrains team license renewal"    -> a person decides
    100, meals,  "Client lunch after the review"       -> a person decides
    40, consulting, "Two hours of advice"              -> a person decides
    40, meals,   "gift card for the team"              -> a person decides

## Task 3 — Pause, and commit nothing while you wait

1. Write `human_review(state)` so it **pauses the graph** at that node and
   surfaces a payload to the caller. The payload must carry the `claim` itself,
   the agent's `agent_reasoning`, and the `options` the reviewer may pick —
   `approve` and `reject`.
2. In `build_graph()`, compile with a checkpointer so the pause is durable: the
   state is snapshotted, tagged with the `thread_id`, and still there when a
   completely separate HTTP request asks about it.
3. While a claim waits, `final_status` and `human_decision` stay empty. Nothing
   downstream may be committed before the decision arrives.
4. `POST /claims` returns `pending: true` and the payload under `interrupt`.
   `GET /claims/<thread_id>` returns `pending: true` for as long as it waits.
5. Each `thread_id` is its own conversation. Starting a second claim must not
   disturb a paused one — not its beliefs, not its audit log, not its status.

**Requirements.** Reading a paused claim is a read. It must not re-run the
agent, and it must not put more work through the analyst.

**Example.**

    POST /claims {"thread_id": "c-88", "claim": {... 850 ...}}
    -> {"thread_id": "c-88", "pending": true, "final_status": null,
        "interrupt": {"message": "Human approval required",
                      "claim": {...},
                      "agent_reasoning": "...",
                      "options": ["approve", "reject"]}}

## Task 4 — Resume from the webhook

1. `POST /webhook/approval` takes `{"value": "approve|c-88"}` — the decision and
   the thread, exactly as a chat platform would send back the value of the
   button that was clicked.
2. Resume the paused graph on that thread, feeding the decision in as the answer
   the pause was waiting for.
3. `finalize(state)` records the outcome. An approved claim ends
   `APPROVED (human)` and a rejected one `REJECTED (human)`; both have to say
   that it was a person, because "approved" alone does not distinguish the two
   paths. It also appends the next action to `intentions`.
4. Resuming adds to the audit log — the decision that came back, and the
   outcome. Everything written before the pause is still there, in order,
   afterwards. An audit log is append-only.
5. Deciding one thread must not touch another.

**Requirements.** `human_decision` on the resumed thread holds what the reviewer
sent. `pending` becomes false.

**Example.**

    POST /webhook/approval {"value": "approve|c-88"}
    -> {"thread_id": "c-88", "final_status": "APPROVED (human)"}

    GET /claims/c-88
    -> audit_log now ends: "[HUMAN_REVIEW] Received decision: approve.",
                           "[FINALIZE] Status=APPROVED (human). ..."

## Task 5 — Make the callback safe

Webhooks are delivered by systems you do not control, to endpoints anyone can
reach. Assume every one of these will happen in the first week.

1. **The same button pressed twice.** A callback for a thread that has already
   been decided is refused with a `4xx`. The outcome does not change and no new
   audit entries appear. A claim does not get decided twice.
2. **A decision for a claim that does not exist.** Refused with a `4xx` and a
   JSON body. An unknown thread is a bad request, not a crash and not a `5xx`.
3. **A decision nobody defined.** Anything that is not `approve` or `reject` is
   refused with a `4xx`, and the claim stays exactly where it was — still
   waiting, still with no final status.
4. **A malformed body.** A value with no `|` in it is refused with a `4xx`.
5. After any of those, the service is still serving and a fresh claim still
   works.

**Requirements.** Refusals are `4xx` and never `5xx`; an exception escaping a
handler is a failure of this task.

**Example.**

    POST /webhook/approval {"value": "approve|c-88"}   (again)
    -> HTTP 409, and GET /claims/c-88 is byte-for-byte what it was

    POST /webhook/approval {"value": "maybe|c-91"}
    -> HTTP 400, and c-91 is still pending with no final status

## Run and verify locally

    cd /home/user/pelham-approvals
    python3 check_local.py

That starts your service on a spare port, walks three claims through it,
approves one through the webhook, presses the same button again, and prints the
audit log and the BDI state it ended with. You can also run the service yourself
and drive it by hand:

    python3 server.py &
    curl -s -X POST http://127.0.0.1:8767/claims \
      -H 'Content-Type: application/json' \
      -d '{"thread_id":"c-1","claim":{"employee":"A","amount_usd":850,
           "category":"software","description":"licence renewal"}}'

Leave your service running when you submit if you like — it will be used as it
stands. If it is not running, it will be started for you.

The claims used to score your work are not the ones in `check_local.py`.

## How you are graded

Five checks, ten points each, fifty in total.

1. **BDI state.** Beliefs carry the claim and the policy it was measured
   against; desires are present and identical across two different claims;
   intentions name actions; the audit log records every stage in order; and the
   analyst was really consulted.
2. **Routing.** Five claims spanning below, at and above the threshold, an
   invalid category, and a small valid claim whose description the analyst
   flags — every one routed the right way, with one analyst call each.
3. **The pause.** The payload carries the claim, the reasoning and both options;
   nothing is committed while it waits; the pause survives separate requests;
   a second thread leaves it alone; and reading it back does not re-run the
   agent.
4. **The resume.** The right thread resumes, the outcome names both the decision
   and that a person made it, the audit log grew without being rewritten, the
   intentions grew, and the other thread is untouched.
5. **A safe callback.** Replay, unknown thread, unrecognised decision and
   malformed body are each refused as client errors and change nothing, and the
   service still works afterwards.
