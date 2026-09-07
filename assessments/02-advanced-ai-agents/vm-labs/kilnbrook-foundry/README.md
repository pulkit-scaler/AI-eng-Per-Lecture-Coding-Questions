# Kilnbrook Foundry — VM Lab Pack

Execution-graded lab on **building an agent from scratch with the raw OpenAI SDK**. The learner
writes the whole agent (`solution.py`); the model client, the database helper, the persona and the
operations database are provided. Grading runs the learner's agent and inspects what the endpoint
actually received and what the database actually returned.

- **Points:** 50 (5 scripts × 10) — the platform accepts at most 5 test scripts
- **Docker required:** no
- **Hosted model required:** no — the endpoint is local and stdlib-only
- **Frameworks:** none. No LangChain, no LangGraph; the loop is the learner's own code.

## Content covered

Grounded in `modules/02-advanced-ai-agents/markdown/L1_Agents_Foundations_&_Planning.md`, which
builds a Text2SQL agent out of five components:

| Source material | Task | Check |
|---|---|---|
| Component 1 — Persona as the system prompt, `build_system_prompt(persona)` | Task 1 | TC01 |
| Component 4 — the read-only guard, stated as two tests and enforced as two tests | Task 3 | TC02, TC05 |
| Component 4 — Tools: the OpenAI-format schema, `name`/`description`/`parameters`/`required` | Task 2 | TC01 |
| Component 4 — the three tools `list_tables` → `get_table_schema` → `execute_sql`, and the tool lookup map | Task 3 | TC02 |
| Component 3 — ReAct: the LLM never executes a tool; the app runs it and appends `{"role": "tool", "tool_call_id", "content"}` | Task 4 | TC03, TC05 |
| Component 5 — short-term memory: the messages list is what stops the agent re-listing tables for the next question | Task 5 | TC04 |
| Persona boundaries — "NEVER run DELETE, DROP, UPDATE, INSERT" enforced where it can actually be enforced | Task 3, 5 | TC02, TC05 |

Every technique the lab requires appears in that one lecture: the persona dictionary and its
renderer, `tools_schema` in OpenAI format, `tool_choice="auto"`, the six-step function-calling
cycle, `json.loads(call.function.arguments)`, the `tool_functions` name-to-function map, the
`while True` loop that ends when `message.tool_calls` is empty, and the with/without-memory
comparison.

**One deliberate exception, bridged in the statement — the SQL dialect.** L1 builds these same three
tools against MySQL (`mysql.connector`, `SHOW TABLES;`, `SHOW COLUMNS FROM`, `pd.read_sql`); this
lab runs on SQLite, where the two schema-discovery lookups are spelled `sqlite_master` and
`PRAGMA table_info(...)`. Those two spellings are not taught until L3 — the only occurrences of
"sqlite" anywhere in L1 are incidental output noise, a HuggingFace progress bar and a pandas
`UserWarning`. A learner working faithfully from L1 would therefore write `SHOW TABLES;`, get a
`sqlite3.OperationalError` and lose TC02 through no fault of their understanding. The lab is not
ported to MySQL over this (the image has no MySQL, and L3 is SQLite too); instead Task 3 names both
statements outright. That is pedagogically free: what TC02 assesses is that the schema is
*discovered through the tools at run time* rather than hard-coded, and the anti-hardcoding
requirement carries that weight on its own. Recording the exception here because it is exactly the
kind of thing a future edit would otherwise "tidy away" as redundant hand-holding.

Note that the learner never writes analytical SQL — the model does, and `execute_sql` merely runs
whatever arrives in `call.function.arguments`. The dialect exposure is confined to the two
catalogue lookups above.

Deliberately **not** reused: LangChain and LangGraph. Three existing labs already cover LangGraph
(`skyline-dispatch`, `fernvale-archive`, `tidewater-locks`), and this lecture uses neither.

## Layout

```
kilnbrook-foundry/
  problem-statement.md          learner-facing
  README.md                     this file
  INSTRUCTOR-SETUP-GUIDE.md     portal configuration + troubleshooting
  VALIDATION.md                 what was executed, with the numbers observed
  SOLUTION.md                   walk-through of the model answer
  build.sh                      regenerates setup_script.sh, runs every invariant, stages the zips
  gen_tests.sh                  regenerates script_01..05 from one preamble
  sweep.sh                      grades every candidate on its own port and lab dir
  setup-timing.sh               measures the setup FOREGROUND wall clock on the target image
  app/                          provided learner-visible sources
    kiln_kit/{__init__,client,db,persona}.py
    solution_stub.py            shipped to the VM as solution.py
    check_local.py
  service/
    foundryd.py                 HIDDEN endpoint (installed to /opt/kilnbrook-svc, 0700 root)
    make_db.py                  HIDDEN database builder (runs from /tmp, then deleted)
  setup/
    setup_script.template.sh    source of truth; FILE markers are expanded by build.sh
    scripts/setup_script.sh     GENERATED - do not hand-edit
  test-cases/scripts/
    script_01..05.sh            GENERATED, self-contained; ONLY these ship in TestCase.zip
    common.sh                   FAITHFUL REPLICA of the platform helper, including its ERR
                                trap and its jq JSON output (run-all only, NOT shipped)
    run-all.sh                  local validation harness, grading the LAST line as the
                                platform does (NOT shipped)
  reference-solution/
    solution.py                 model answer
    alt1_plain_loop.py          reordered prompt, while loop with a counter, CSV rows, to_dict()
    alt2_spec_driven.py         schemas from a spec table, JSON rows, message rebuilt by field
    alt3_class_agent.py         an Agent class owning the conversation, sqlite3.Row, aligned rows
    alt4_generator_loop.py      the loop as a generator, cursor.description schema, key=value rows
    alt5_recursive_session.py   recursion with a depth argument, module-level schema, table rows
    alt6_extra_tool.py          the three required tools plus a fourth of its own
    alt7_published_rule.py      the read-only guard as exactly the two tests the statement publishes
    _defect1_prompt_role_only.py       probe: only the role reaches the system prompt
    _defect2_schema_hardcoded.py       probe: the schema tool answers from a hardcoded map
    _defect3_wrong_call_id.py          probe: results fed back under the tool name
    _defect4_fresh_per_question.py     probe: run_session starts a new conversation each time
    _defect5_guard_only_delete.py      probe: the guard blocks DELETE but not UPDATE
    _cheat_hardcode.py                 probe: every published value pasted in
    _cheat_bypass_endpoint.py          probe: real tools, answers assembled locally
    _cheat_dump_all.py                 probe: real tools, answer dumps every row so any value is present
    _cheat_single_turn.py              probe: one round trip, then a canned answer
    _envprobe_numpy.py                 regression: numpy at module scope must cost all five checks
    _envprobe_hang.py                  regression: a stalled run must be killed at RUN_BUDGET
  validation/permutations.sh     ordering matrix, run inside ubuntu:25.04
  dist/                          Setup.zip + TestCase.zip (each with scripts/ and data/)
```

## How the endpoint makes this gradeable

`service/foundryd.py` is an OpenAI-compatible chat-completions endpoint whose decisions are
**computed from the conversation it receives**, never sampled. It holds a table of questions, each
with an ordered plan of `{tool, args}` steps, and walks that plan by counting how many of the
current turn's steps already have a result. That gives four properties the checks depend on:

1. **A malformed tool schema stalls the plan.** The endpoint only emits a call for a tool the
   request declared with the right name, a non-empty description and its required parameters
   present. Anything else and it answers `UNABLE: ...` instead — so Task 2 is load-bearing rather
   than decorative.
2. **The final answer carries the learner's own tool output.** It parses the last tool observation
   of the turn and re-emits it inside the persona's three-part output format. A stubbed tool
   produces a wrong final value, which is what makes hard-coding score zero.
3. **Memory is observable as step-skipping.** If the conversation already carries a `list_tables` or
   `get_table_schema(<table>)` observation from an earlier turn, the plan for the current question
   drops that step. One shared message list therefore produces **1** tool call on the second
   question where a fresh list produces **3** — the graded difference in TC04.
4. **A restricted surface reports what happened.** Behind an `X-Kiln-Audit` header (a plain 404
   without it) the endpoint exposes the session record — the system prompt it received, its verdict
   on the persona and the tool schemas, the steps it planned, each observation and whether its
   `tool_call_id` matched — plus an oracle that computes the true answer by querying the SQLite
   database itself.

`service/make_db.py` builds the database. Every column is INTEGER or TEXT, so every value has one
unambiguous string form and the checks can look for values inside the learner's rendering without
grading the rendering.

## Regenerating the pack

```bash
./gen_tests.sh          # rewrite the five checks from the shared preamble
./build.sh              # expand the setup template, run every invariant, stage the zips
PY=<venv>/bin/python ./test-cases/scripts/run-all.sh        # grade the reference
PY=<venv>/bin/python ./sweep.sh                            # grade every candidate
./validation/permutations.sh                               # ordering matrix in ubuntu:25.04
./setup-timing.sh                                          # foreground wall clock
```

`build.sh` refuses to ship when any of these is broken: an unexpanded template marker, an inlined
copy that has drifted from its `app/`/`service/` mirror, a persona that differs between
`app/kiln_kit/persona.py` and `service/foundryd.py`, more than five test scripts, a check missing
`SVC_WAIT`/`RUN_BUDGET`/`CURL_MAX`/`DEPS_WAIT`/`PYTHONDONTWRITEBYTECODE`/the `EXIT`-trap `chown`, a
check missing `trap - ERR`, `set +eE`, the `exec 2>>` stderr redirect, the `id -u user` ownership
gate or `run_evidence`, a check that still splices the dead `trace_hint` stub, an apostrophe inside a
quoted Python heredoc, a preamble that has drifted between checks, a markdown table in the problem
statement, a leaked internal term in a learner-visible file, or a zip missing `scripts/` or `data/`.

## Scoring is a prefix, not a sum

The platform's `main.sh` breaks out of its loop at the first check that does not report success, so a
submission failing check 1 never runs checks 2 to 5 and scores 0, not 40. `sweep.sh` prints both
numbers: `SCORE` is the per-theme sum, which says which themes a candidate implements, and `PORTAL`
is the prefix, which is what a real submission would be awarded. The five checks are therefore
ordered by how little each depends on: TC01 needs Tasks 1 and 2 only, TC02 needs Task 3 only, then
TC03 the loop, TC04 the shared conversation, TC05 the guard driven through the loop.
