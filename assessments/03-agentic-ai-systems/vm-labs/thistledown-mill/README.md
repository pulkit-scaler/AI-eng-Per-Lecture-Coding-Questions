# `thistledown-mill` — CrewAI & Microsoft Autogen Frameworks (M3-L7)

A VM lab whose deliverable is a **configured project**, not a script. The learner
writes two YAML files, two tools and one `build_crew()`; the entry point, the
database, the order book and the planning model are provided. Three of the five
checks never involve a model at all.

- **Target image:** *systemd Ubuntu*, really **Ubuntu 25.04 / Python 3.13.3**.
- **Max Score 50 = 5 checks × 10.**
- **Project:** `/home/user/thistledown-mill`. Planning model on
  `127.0.0.1:8433`. SQLite at `data/mill.db`.

## The one thing to know before touching this pack

**CrewAI 0.203 does not use OpenAI function calling by default.** It sends
`tools: []` and describes the tools *in the system prompt*, expecting the text
protocol back:

```
Thought: ...
Action: run_query
Action Input: {"sql": "..."}
```

`service/millsvc.py` answers both conventions, but the text one is the live path.
Three details were established by experiment and are load-bearing:

- **The word `Observation:` appears in CrewAI's own format instructions**, so it
  cannot be used to detect that a tool has reported back. The model counts
  messages instead: an opening turn is `[system, user]`, anything longer means a
  result has come back.
- **An agent with no query tool must not be handed a query**, or it goes looking
  for a tool it does not have and burns its turns. The model checks the offered
  tool list (from the `tools` array or from `Tool Name:` lines) before proposing
  one.
- **CrewAI asks, once per project directory, whether you want to view execution
  traces, and waits 20 s.** Provisioning marks that question answered in
  `~/.local/share/thistledown-mill/.crewai_user.json` as the learner. Without
  that, every graded run pays 20 s of nothing.

## The five themes

1. **The tools** — called directly in **one** interpreter start, six calls: the
   right figures for a yarn, the cloth-to-yarn specification, every row of the
   yarn table, a database error handed back as text, and two queries nothing
   could have prepared in advance (a `COUNT(*)` over the looms and one column of
   one row). Those last two are what a canned tool cannot survive.
2. **The guard** — six write and multi-statement attempts, each refused *in
   words*, none returning rows, and the database byte for byte unchanged.
3. **The crew** — two agents, two tasks, every role, goal, description and
   expected output matching the YAML, sequential process, `run_query` in exactly
   one pair of hands, every agent capped at `MAX_ITER`.
4. **A run** — one order end to end; the note carries stock figures that only a
   query could have supplied, and the model trace shows the query naming the
   right yarn.
5. **An order that cannot be met** — the cloth specified in a yarn the mill does
   not stock: the tool answers plainly, the run still writes a note, and the
   turn count stays bounded.

## Interpreter starts

crewai is a heavy import, so grading cost here is interpreter starts, not
computation. Batched deliberately: **1 per check** for checks 1–4 and 2 for
check 5. An earlier version made one start per tool call and check 2 took 28 s;
batched, the slowest check is 4–6 s.

## Marking notes

Verified during authoring — all 50/50: block scalars instead of folded ones; the
`@tool` decorator instead of `BaseTool` subclasses; a driver-level sqlite
authorizer on top of the text guard; a third tool added to the analyst; the
agents built in a loop over the configuration; **and no explicit `context=` on
the note task**, because a sequential crew already hands the previous task output
on. That last one started life as a defect probe and turned out not to be one —
the statement says either is fine.

Single-theme losses: a raised database error (check 1), no SQL guard (check 2),
and four different ways of getting the crew wrong — configuration written into
the Python, both agents given the database, no turn cap, only one task — each
losing check 3 and nothing else.

The canned-tool probe scores **40/50**, losing check 1 only. It really did build
the crew, the guard, the configuration and the run; what it faked was the data
source, and that is the theme it loses.

## Pack layout

```
app/                  everything provided, plus the four starters and build_db.py
service/millsvc.py    the planning model (root-only, outside the project)
setup/                setup_script.template.sh -> scripts/setup_script.sh
reference-solution/   the model answer, 6 alternative shapes, 6 defect probes,
                      1 fabrication probe
test-cases/scripts/   script_01..05.sh (shipped) + common.sh, run-all.sh
validation/           the ordering matrix
dist/                 Setup.zip + TestCase.zip
```

## Authoring commands

```bash
./gen_tests.sh
./build.sh
PY=/path/to/crewai-venv/bin/python ./test-cases/scripts/run-all.sh
PY=... ./sweep.sh
PY=... ./validation/permutations.sh
```
