# Norbury — graduate the prototype

## Overview

The research desk at Norbury built their assistant in a visual builder. It took
an afternoon: drag in a chat input, a prompt, a model, three tool nodes and a
memory node, wire them together, hit Play. It demos beautifully.

It is also not something anybody can deploy. The export has the API key written
into it as `***`. There is no limit on how many times the agent may loop. There
is no record of what it did. And the only thing that knows how the components
connect is a JSON file nobody has written code against.

Your job is the step the demo never covers: **turn the export into production
Python**. Not by rewriting it from memory — by reading the flow, checking that
it is runnable, and building the runtime it describes.

## Learning objectives

- Read a visual builder's export as what it is: a node graph with typed
  components and ports.
- Refuse a flow that cannot run, loudly and specifically, rather than running
  half of it.
- Resolve the order components have to be built in.
- Carry a prototype's configuration into the runtime, and leave its placeholder
  credential behind.
- Write out the agent loop the builder drew as one box, with the step limit a
  prototype never had.

## What is provided

Everything below is in `/home/user/norbury-flow` and already works. Do not
modify anything under `flow_kit/`.

- `flow_kit.call_model(config, system, messages, tools, api_key,
  force_final=False)` — asks the model what to do next. Returns either
  `{"type": "final", "text": ...}` or `{"type": "tool", "tool": ...,
  "input": ...}`. With `force_final` set it always returns a final answer.
  Raises `flow_kit.NorburyError` when the credential is missing or is the
  placeholder an export carries.
- `flow_kit.call_tool(name, text, max_results=5)` — runs one tool backend and
  returns what it found, as text.
- `flow_kit.NODE_KINDS` — `ChatInput`, `Prompt`, `LanguageModel`, `Tool`,
  `Memory`, `ChatOutput`.
- `flow_kit.MODEL_PORTS` — the ports a `LanguageModel` accepts a connection on:
  `input`, `prompt`, `tools`, `memory`.
- `flow_kit.TOOL_NAMES` — `arxiv_search`, `web_search`, `summarise`.
- `flow_kit.API_KEY_ENV` — the name of the environment variable the credential
  comes from, `NORBURY_API_KEY`. It is already set in your shell.
- `flows/` — two exports to work against. `runs/` — where run logs go.
- `check_local.py` — validates and runs them and prints what happened.

The model endpoint answers on `http://127.0.0.1:8788`. Leave it running.
Everything here is the standard library.

### What an export looks like

    {
      "name": "research-briefing",
      "nodes": [
        {"id": "ChatInput-1",  "type": "ChatInput",     "config": {}},
        {"id": "Prompt-1",     "type": "Prompt",        "config": {"template": "..."}},
        {"id": "Model-1",      "type": "LanguageModel",
         "config": {"model": "norbury-8b", "temperature": 0.3,
                    "api_key": "***", "max_iterations": 4}},
        {"id": "Arxiv-1",      "type": "Tool",
         "config": {"tool": "arxiv_search", "max_results": 5}},
        {"id": "Memory-1",     "type": "Memory",        "config": {"window": 6}},
        {"id": "ChatOutput-1", "type": "ChatOutput",    "config": {}}
      ],
      "edges": [
        {"source": "ChatInput-1", "target": "Model-1",     "port": "input"},
        {"source": "Prompt-1",    "target": "Model-1",     "port": "prompt"},
        {"source": "Arxiv-1",     "target": "Model-1",     "port": "tools"},
        {"source": "Memory-1",    "target": "Model-1",     "port": "memory"},
        {"source": "Model-1",     "target": "ChatOutput-1", "port": "output"}
      ]
    }

`"api_key": "***"` is the placeholder the builder writes where the key was. It
is not a credential and it must never leave your process.

## Interface contract

Three files, with exactly these paths and names.

- `flow/spec.py` — a `FlowError` exception class; `load_flow(path)` returns the
  parsed export; `validate(flow)` returns nothing and raises `FlowError`;
  `plan(flow)` returns a list of node ids.
- `flow/runtime.py` — `build_runtime(flow)` returns whatever your runtime needs;
  `run_turn(runtime, message, history=None)` returns the pair
  `(text, trace)`, where `trace` carries at least `tool_calls` (a list of tool
  names in the order they ran), `model_calls` and `stopped_early`.
- `flowctl.py` — the command line:

      python3 flowctl.py validate <flow.json>
      python3 flowctl.py run <flow.json> --message "..." --session <id>

Both subcommands print one line of the form `LABJSON:<JSON object>` and exit
`0` on success, non-zero on a `FlowError`. Helper modules are fine.

## Task 1 — Refuse a flow that cannot run

A prototype that half-runs is worse than one that refuses to start, because the
half that did not run says nothing. Check everything once, up front, and name
the node.

1. `load_flow(path)` reads the export. A file that is missing or is not JSON is
   a `FlowError` like any other unrunnable flow — not an `OSError` reaching the
   caller.
2. `validate(flow)` raises `FlowError` when any of these holds, and the message
   **names the node or the component kind at fault**:
   - a node whose `type` is not one of `flow_kit.NODE_KINDS`;
   - an edge whose `source` or `target` is not a node in the flow;
   - anything other than exactly one `ChatInput`, one `LanguageModel` and one
     `ChatOutput`;
   - a `Tool` node whose `config.tool` is not in `flow_kit.TOOL_NAMES`;
   - a `LanguageModel` node with no `model` in its config;
   - an edge into the `LanguageModel` on a port that is not one of
     `flow_kit.MODEL_PORTS`;
   - nodes that feed each other in a circle;
   - a `ChatOutput` that nothing connects the `ChatInput` to.
3. A flow that passes all of that returns normally.

**Requirements.** Raise `FlowError`, never a bare `KeyError` or `TypeError`.
The message is what somebody reads at three in the morning, so it says which
node.

**Example.**

    validate({... a node of type "VectorStore" with id "Store-2" ...})
    -> FlowError: node Store-2 is a 'VectorStore', which this runtime has no
       component for. Known kinds are ChatInput, Prompt, LanguageModel, ...

## Task 2 — Work out the order to build things in

1. `plan(flow)` returns every node id exactly once, ordered so that **a node
   never appears before anything that feeds it**. A model cannot be built before
   the prompt and the tools wired into it.
2. The list **starts with the `ChatInput` node** — the flow starts where the
   message comes in — and **ends with the `ChatOutput` node**.
3. Several nodes have nothing feeding them, so more than one order satisfies the
   edges. Any of them is fine as long as the two rules above hold.
4. A flow whose nodes feed each other in a circle has no such order: raise
   `FlowError`.

**Requirements.** `plan` is what `validate` leans on to detect a circle, so
getting this right is what makes that refusal work.

**Example.**

    plan(flow) -> ["ChatInput-1", "Arxiv-1", "Memory-1", "Prompt-1",
                   "Model-1", "ChatOutput-1"]

## Task 3 — Carry the configuration across, and leave the placeholder behind

1. `build_runtime(flow)` validates the flow, then resolves it into what a turn
   needs: the model config, the system prompt, the tools, the memory settings
   and the step limit.
2. The **model name** and the **temperature** come from the `LanguageModel`
   node's config and are passed to `flow_kit.call_model` on every call.
   Configuration that stays in the JSON is not configuration.
3. The **system prompt** is the `template` of the `Prompt` node wired to the
   `prompt` port.
4. The **tools** are the `Tool` nodes wired to the `tools` port — those and no
   others. Each carries its own `max_results`, which is passed to
   `flow_kit.call_tool`.
5. The **credential** comes from `os.environ[flow_kit.API_KEY_ENV]`. The
   `api_key` in the export is the placeholder `***`; it must never be sent
   anywhere.
6. If that environment variable is missing or empty, raise `FlowError` with a
   message **naming the variable**. `flowctl.py` then exits non-zero. A runtime
   that treats the placeholder as a credential ships a flow nobody can
   authenticate and nobody can diagnose.
7. `max_iterations` comes from the `LanguageModel` config, defaulting to `3`.

**Requirements.** Nothing that came out of the export's `api_key` field reaches
`flow_kit.call_model`.

**Example.**

    $ unset NORBURY_API_KEY; python3 flowctl.py run flows/research-briefing.json \
        --message "..."
    LABJSON:{"ok": false, "error": "no credential in the environment ... set
             NORBURY_API_KEY before running this flow"}
    $ echo $?
    1

## Task 4 — Write out the loop the builder drew as one box

The visual builder shows an Agent node. In production that box is this loop, and
it is where a prototype quietly becomes a bill.

1. `run_turn(runtime, message, history=None)` starts the conversation from the
   history it is given plus the new message.
2. Up to `max_iterations` times: ask the model. If it returns a `final`, that
   text is the answer and the turn is over. If it returns a `tool`, run **that**
   tool with `flow_kit.call_tool`, append the result to the conversation as a
   message with `role` `"tool"` and `name` set to the tool's name, and go round
   again.
3. If the model asks for a tool the flow does not wire, that is a `FlowError`.
4. When the step limit runs out, do **not** hand back the last tool output raw
   and do **not** keep going. Call the model once more with `force_final=True`
   and return what it says. Running out of steps still has to end in something
   to say.
5. `trace["tool_calls"]` lists the tools that ran, in order.
   `trace["stopped_early"]` is true exactly when the step limit was reached.

**Requirements.** The tool results have to go back into the conversation, or the
tools ran for nothing. The step limit is a hard cap on tool calls, not a
suggestion.

**Example.** A flow wiring all three tools with `max_iterations` of 2:

    LABJSON:{"ok": true, "tool_calls": ["arxiv_search", "web_search"],
             "model_calls": 3, "stopped_early": true, "reply": "Wrapping up..."}

## Task 5 — Sessions, memory, and a record of what happened

1. `flowctl.py run` takes a `--session`. Turns in the same session share a
   conversation; different sessions do not. That is what lets one deployment
   serve more than one person.
2. The conversation is carried **only when the flow wires a `Memory` node**. Its
   `window` is how many earlier messages come back. A flow with no `Memory` node
   remembers nothing between turns — what the runtime does is what the flow
   wires, not what would be nice.
3. Every run appends to `runs/<session>.json`: an object with a `session` and a
   list of `turns`, each carrying at least the `message`, the `reply`, the
   `tool_calls` and `model_calls`. A deployment nobody can look back at is a
   deployment nobody can debug.
4. The log survives across processes: a second `flowctl.py run` reads it back
   and continues the conversation.

**Requirements.** `runs/` may not exist yet; create it. A log that cannot be
parsed is a log to start fresh from, not a crash.

**Example.**

    $ python3 flowctl.py run flows/research-briefing.json \
        --message "Research retrieval routing" --session desk-1
    $ python3 flowctl.py run flows/research-briefing.json \
        --message "What did I ask you first?" --session desk-1
    LABJSON:{"ok": true, "reply": "Earlier you asked about retrieval routing.",
             "tool_calls": [], "turns": 2}

## Run and verify locally

    cd /home/user/norbury-flow
    python3 check_local.py

That validates both exports, prints the plan for each, then runs two turns of a
conversation and shows the run log. You can also drive it by hand:

    python3 flowctl.py validate flows/research-briefing.json
    python3 flowctl.py run flows/research-briefing.json \
        --message "Research retrieval routing" --session desk-1

The flows used to score your work are not the ones in `flows/`.

## How you are graded

Five checks, ten points each, fifty in total.

1. **Refusals.** Eight broken flows are each refused with the offending node
   named, two runnable flows are accepted, and a missing file is refused the
   same way.
2. **The plan.** Every node once, never before what feeds it, starting at the
   input and ending at the output, and a flow with a circle refused.
3. **Configuration.** The declared model, temperature, prompt text and exactly
   the wired tools all reach the endpoint; the export placeholder never does;
   and a missing credential fails with a message naming the variable.
4. **The loop.** The wired tools run in the order the model asks for, with their
   node settings; their findings appear in the answer; and a flow capped at two
   steps stops there and still produces a wrap-up.
5. **Sessions.** A second turn in the same session recalls the first, a
   different session does not, a flow with no memory node does not, and the run
   log carries both turns with the tools each used.
