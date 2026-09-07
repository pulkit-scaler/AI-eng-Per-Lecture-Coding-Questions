# Redcliffe Signals — Reason, Review and Remember

## Overview

The Redcliffe control desk answers questions about signal boxes, engineering
possessions and asset faults. Three habits make it useful: it **looks things up
before it answers**, it **puts a draft past a second pair of eyes**, and it
**remembers what the last shift told it**.

Those are three patterns, and you write one module for each. The desk itself —
the reasoning model, the reviewer, the three lookup tools and the vectoriser —
is already there.

## Learning objectives

- Write the **reason-and-act loop** by hand: a thought, an action, the
  observation it produced, and the next thought built on top of it.
- Keep a **trace** that is a record rather than a summary, so a run can be
  audited afterwards.
- Bound the loop with a **step cap in code**, and make running out an **honest
  failure** rather than a guess.
- Write a **judge-and-revise loop** that stops as soon as the reviewer is
  satisfied, and stops anyway at its cap — carrying what is still wrong.
- Persist what the desk remembers so it **survives the process**, and keep
  sessions apart.
- Apply a **windowed** policy to recent turns, and recall from the whole store by
  **cosine similarity** with a **relevance floor**.

## Environment

The VM is already provisioned — you install nothing.

- Python 3 and **the standard library**. That is all: there is no numpy, no
  pandas and no framework to import here, so the similarity arithmetic is yours
  to write.
- The control desk is already running on `http://127.0.0.1:8622`. Leave it
  running. Check it with `curl -s http://127.0.0.1:8622/health`.
- Work in `/home/user/redcliffe-signals` and run everything from that directory,
  so `import signal_kit` resolves and `store/` is where you expect.
- Each graded invocation gets a bounded time budget well under two minutes, so
  keep every loop bounded.

## What is provided

Under `/home/user/redcliffe-signals/`:

```
signal_kit/
  desk.py      think(), judge(), revise(), the three tools, run_tool()
  embed.py     embed(text) -> 64 floats, and tokens()
  prompts.py   the limits
signalctl.py   the command line - it calls your three modules
signals/
  react_loop.py   you write this
  reflect.py      you write this
  memory.py       you write this
store/            where your note store goes
check_local.py    runs every subcommand and shows what it printed
```

```python
import signal_kit as kit

kit.think(prompt, step)      # the next thought, and an action or an answer
kit.run_tool(name, args)     # call the tool the desk named
kit.judge(draft_id, attempt) # accept or revise, with the issues
                             # attempt is the review number: 1, 2, 3 ...
kit.revise(draft_id, attempt, critique)
                             # attempt is the revision number: 1, 2 ...
kit.embed(text)              # a unit-length list of 64 floats
kit.MAX_STEPS      # 4    the most actions one question may take
kit.MAX_ROUNDS     # 2    the most times a draft may go back to the writer
                   #      - the cap is on revisions, not on reviews
kit.RECALL_TOP_K   # 3    the most notes a recall returns
kit.RECALL_FLOOR   # 0.25 below this a note is noise
kit.WINDOW         # 4    how many turns the working window keeps
kit.DeskError      # raised when a tool or the desk refuses
```

`kit.think(prompt, step)` returns a dict. When it wants to act:

```
{"kind": "action", "thought": "...", "action": "signal_status",
 "action_input": {"box": "RC-BOX-19"}}
```

and when it is finished:

```
{"kind": "final", "thought": "...", "answer": "..." or None,
 "answerable": true or false}
```

`step` is 1 on the first thought and one higher each time round. **The desk
reads it**, so a loop that never advances it never advances.

## Interface contract

- `signals/react_loop.py` exports `answer(question)`.
- `signals/reflect.py` exports `refine(draft_id)`.
- `signals/memory.py` exports `remember(session, note)`, `recall(session, query)`
  and `window(session)`.
- Each returns a dict; `signalctl.py` prints it as JSON. The keys are in the
  tasks below.
- The note store is **`store/signals.jsonl`**, relative to the project
  directory.
- Every model call goes through `kit.think`, `kit.judge` or `kit.revise`, and
  every tool call through `kit.run_tool`.

---

### Task 1 — `answer(question)`: reason, act, observe

1. Start a scratchpad holding the question. Loop at most `kit.MAX_STEPS` times.
2. On each turn call `kit.think(scratchpad, step)` with `step` starting at 1 and
   rising by one.
3. If it returns `kind == "action"`, call that tool through
   `kit.run_tool(action, action_input)`, append what came back to the scratchpad,
   and go round again.
4. If it returns `kind == "final"`, stop.
5. Record every acting turn in a `trace` entry with `step`, `thought`,
   `action`, `action_input` and `observation`. The observation is **what the tool
   returned** — not the thought, not a summary of it. The closing turn acted on
   nothing: recording it with nulls as the example below does, or leaving it out,
   are both fine.
6. Return `question`, `answered` (bool), `answer`, `steps` (how many actions
   were taken), `actions` (their names in order), `trace`, and
   `stopped_because` — a sentence saying why the loop ended.

**Requirements.** A tool that refuses raises `kit.DeskError`; that is an
observation like any other, so catch it, record it and carry on. `answered` is
true only when the desk actually produced an answer.

**Example.**

```
$ python3 signalctl.py ask --question "what aspect is RC-BOX-14 showing"
{"question": "what aspect is RC-BOX-14 showing", "answered": true,
 "answer": "RC-BOX-14 is degraded and showing double yellow, last reset on 2026-03-08.",
 "steps": 1, "actions": ["signal_status"],
 "trace": [{"step": 1, "thought": "I still need what signal status holds ...",
            "action": "signal_status", "action_input": {"box": "RC-BOX-14"},
            "observation": {"state": "degraded", "aspect": "double yellow", ...}},
           {"step": 2, "thought": "I have everything the desk records on this.",
            "action": null, "action_input": null, "observation": null}],
 "stopped_because": "the desk had everything it needed"}
```

---

### Task 2 — Run out of steps honestly

Some questions the desk simply does not record. The loop has to end anyway.

1. When the loop reaches `kit.MAX_STEPS` actions without a final answer, stop
   there. The cap counts **actions**, and once it is spent the desk is not asked
   to think again.
2. When the desk itself returns a final with `answerable` false, stop then too.
3. In both cases return `answered` false and `answer` null.
4. Put the reason in `stopped_because`: what was being looked for and why the
   loop gave up. A refusal that does not say what was missing is not much use to
   the person reading it.

**Requirements.** The cap lives **in code**. Never return a plausible-sounding
answer for something the desk did not settle: a wrong answer with a confident
tone costs more than an honest gap.

---

### Task 3 — `refine(draft_id)`: judge and revise

1. Call `kit.judge(draft_id, attempt)` with `attempt` starting at 1 and rising
   by one on every later review.
2. On `accept`, stop immediately. A draft the reviewer is happy with must not be
   revised or reviewed again.
3. On `revise`, call `kit.revise(draft_id, attempt, issues)` with the issues the
   reviewer gave. Here `attempt` is the **revision** number — 1 the first time a
   draft goes back to the writer, one higher each time after — and it is a
   different count from the review number in step 1.
4. `kit.MAX_ROUNDS` caps the **revisions**, not the reviews: a draft goes back to
   the writer at most `kit.MAX_ROUNDS` times. Every revision is reviewed, **the
   last one included**, so a draft the reviewer never accepts takes
   `kit.MAX_ROUNDS` revisions and `kit.MAX_ROUNDS + 1` reviews. That final
   verdict is the one whose issues go out with the draft.
5. Return `draft_id` (upper case), `accepted` (bool), `revisions` (how many
   times it went back), `outstanding` (the reviewer issues still open, empty when
   accepted), `text` (the latest revision, or null if it was never revised) and
   `history` (one entry per review: attempt, verdict, issues).

**Requirements.** Reviews and revisions are counted separately: a draft accepted
first time takes one review and no revisions, and a draft revised twice and still
not accepted takes two revisions and three reviews. A draft that is never accepted
goes out with `accepted` false and its outstanding issues attached — dropping
them is worse than the rework.

**Example.**

```
$ python3 signalctl.py review --draft RC-D-118
{"draft_id": "RC-D-118", "accepted": true, "revisions": 1, "outstanding": [],
 "text": "Point machine to be swapped during the next window. (revision 1 ...)",
 "history": [{"attempt": 1, "verdict": "revise", "issues": ["the asset reference is missing"]},
             {"attempt": 2, "verdict": "accept", "issues": []}]}
```

---

### Task 4 — `remember` and `window`: memory that outlives the process

1. `remember(session, note)` appends the note to `store/signals.jsonl`, tagged
   with its session. Create `store/` if it is not there.
2. Return `session`, `note` and `turns` — how many notes that session now has.
3. `window(session)` returns `session`, `turns` (all of them) and `window` — the
   **last `kit.WINDOW`** notes, oldest first.
4. Two different sessions are two different conversations and must not see each
   other.

**Requirements.** Every `signalctl` command is a **separate process**, so the
count only grows if the notes really reached the store. A dict at module level
does not survive the process that made it.

**Example.**

```
$ python3 signalctl.py note --session nightturn --say "RC-BOX-14 dropped to double yellow"
{"session": "nightturn", "note": "RC-BOX-14 dropped to double yellow", "turns": 1}
$ python3 signalctl.py window --session nightturn
{"session": "nightturn", "turns": 1, "window": ["RC-BOX-14 dropped to double yellow"]}
```

---

### Task 5 — `recall`: similarity, ranked and floored

1. Vectorise the query with `kit.embed`.
2. Score **every** note in that session against it. Both vectors are unit
   length, so the cosine similarity is the dot product: the sum of the
   element-wise products. There is no numpy here — write the loop.
3. Sort by score, highest first, and take at most `kit.RECALL_TOP_K`.
4. Drop anything scoring below `kit.RECALL_FLOOR`. A note that is not about the
   query is noise, and noise in the context is worse than a shorter context.
5. Return `session`, `query`, `recalled` — a list of `{"note", "score"}` best
   first — and `considered`, how many notes were scored.

**Requirements.** `recall` asks the desk nothing. It is arithmetic over what is
already on file.

**Example.**

```
$ python3 signalctl.py recall --session nightturn --about "which box dropped its aspect"
{"session": "nightturn", "query": "which box dropped its aspect",
 "recalled": [{"note": "RC-BOX-14 dropped to double yellow", "score": 0.71}],
 "considered": 2}
```

---

## Run and verify before you submit

```bash
cd /home/user/redcliffe-signals

curl -s http://127.0.0.1:8622/health
python3 check_local.py

python3 signalctl.py ask --question "what aspect is RC-BOX-14 showing"
python3 signalctl.py review --draft RC-D-118
python3 signalctl.py note --session mine --say "SEC-7 possession granted"
python3 signalctl.py note --session mine --say "the kettle needs descaling"
python3 signalctl.py recall --session mine --about "possession window"
python3 signalctl.py window --session mine
wc -l store/signals.jsonl
```

## How you are graded

Five checks, 10 points each, 50 in total.

1. **The loop.** Two questions answered by acting on what came back, with every
   step of the trace carrying the thought, the action and the observation the
   tool really returned — checked against what the desk saw.
2. **Honest failure.** A question the desk cannot settle ends with `answered`
   false, a stated reason, and no more actions than the cap allows.
3. **The reviewer loop.** A draft accepted first time is reviewed once and never
   revised; a draft never accepted stops at the cap and carries its outstanding
   issues.
4. **Memory.** Five notes written in five separate processes all reach the store,
   a second session stays separate, and the window keeps the last four in order.
5. **Recall.** Every note ranked, the related ones returned best first, and the
   ones below the floor left out — without asking the desk anything.
