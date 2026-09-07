# Thistledown Mill — Configure the Planning Crew

## Overview

Thistledown Mill takes an order for cloth and has to answer one question before
the loom is booked: is there enough yarn. A stock analyst reads the mill
database and reports what is held; a production planner turns that into the note
that goes on the shed wall.

That desk is a **configured project**, not a script. The agents and the tasks
live in YAML, the tools live in Python, and one command runs the whole thing on
one order. The entry point, the database, the order book and the planning model
are already written.

**You write four files**: the two configuration files, the two tools, and the
function that assembles them into a crew.

## Learning objectives

- Describe an agent by **role, goal and backstory**, and a task by
  **description and expected output**, in configuration rather than in code.
- Build a **sequential crew** from that configuration, so changing an agent
  means editing a file rather than editing Python.
- Write real **tools** as tool classes with typed arguments, and give them
  descriptions an agent can actually act on.
- Make a Text-to-SQL tool **safe**: read-only statements only, write verbs
  refused wherever they appear, one statement at a time, a row cap, and a
  connection that physically cannot write.
- Hand a problem back to an agent **as text** instead of raising, so the run can
  correct itself rather than ending.
- Give every agent a **turn cap**, and keep the tool that reads the database in
  exactly one pair of hands.

## Environment

The VM is already provisioned — you install nothing.

- Python 3 with **`crewai` (0.130 or newer)** and its dependencies installed and
  importable. `crewai` is a large install; it lands a minute or two after the VM
  comes up, and `python3 -c 'import crewai'` tells you when it is ready.
- The mill runs its **own planning model on this machine**, on
  `http://127.0.0.1:8433`. `millkit.planning_llm()` is already pointed at it.
  **Nothing in this lab needs an account anywhere and there is no key to set.**
  Check the model with `curl -s http://127.0.0.1:8433/health`.
- The mill database is SQLite at `data/mill.db`. There is no server to start.
- Work in `/home/user/thistledown-mill` and run everything from that directory.

## What is provided

Under `/home/user/thistledown-mill/`:

```
mill/
  millkit.py     the database, the order book and the planning model - configured
  main.py        the entry point: python3 -m mill.main --order TM-####
  tools.py       the starter - this is one of the files you write
  crew.py        the starter - this is one of the files you write
config/
  agents.yaml    the starter - you write this
  tasks.yaml     the starter - you write this
data/mill.db     the mill database
data/orders.json the order book
out/             where a run writes its planning note
check_local.py   exercises your tools, then runs one order end to end
```

What `millkit` gives you:

```python
from . import millkit

millkit.read_only()        # a connection that cannot write, whatever the SQL says
millkit.planning_llm()     # the planning model, ready to hand to an Agent
millkit.CONFIG_DIR         # where agents.yaml and tasks.yaml are
millkit.MAX_ITER           # 4 - the turns one agent may take
millkit.ROW_CAP            # 50 - the rows a query may hand back
millkit.QUERY_TIMEOUT      # 10 - seconds a query may run
millkit.load_order(id)     # {"order","customer","cloth","metres","wanted"}
millkit.order_ids()
```

The database has three tables:

- `yarn_stock(yarn_code, description, cones_on_hand, metres_per_cone, bin)`
- `cloth_spec(cloth, yarn_code, metres_of_yarn_per_metre_of_cloth)`
- `looms(loom, machine, available, set_for)`

Available metres of a yarn are `cones_on_hand * metres_per_cone`. Which yarn a
cloth is made from is in `cloth_spec` — and one cloth on the book is specified in
a yarn the mill does not stock at all.

## Interface contract

- `mill/tools.py` exports **`RunQueryTool`** and **`StockLookupTool`**, each
  callable with no arguments to get a tool instance. Their tool names are
  exactly **`run_query`** and **`stock_lookup`**.
- `mill/crew.py` exports **`build_crew()`**, taking no arguments and returning a
  ready-to-run `Crew`.
- `config/agents.yaml` has exactly the keys **`stock_analyst`** and
  **`production_planner`**, each with `role`, `goal` and `backstory`.
- `config/tasks.yaml` has exactly the keys **`stock_check`** and
  **`production_note`**, each with `description` and `expected_output`.
- Placeholders in braces are filled in at run time from the order:
  `{order}`, `{customer}`, `{cloth}`, `{metres}`, `{wanted}`.
- The crew has **two agents and two tasks**, runs **sequentially**, and every
  agent is capped at `millkit.MAX_ITER` turns.
- `run_query` is held by **exactly one** agent.
- A run is `python3 -m mill.main --order TM-####`, which writes
  `out/TM-####.md`. That entry point is provided; do not edit it.

---

### Task 1 — Write `mill/tools.py`

Two tools, each a `BaseTool` subclass with a `name`, a `description`, an
`args_schema` and a `_run`.

1. **`run_query(sql)`** runs one read-only statement and returns the rows as
   text. Include the table and column names in its `description` — that
   description is the only thing telling an agent what it can ask for.
2. Read through `millkit.read_only()`. Take at most `millkit.ROW_CAP` rows, and
   say so in the output when you truncate.
3. Return rows as text with a header line and one line per row. An empty result
   is not an error: say `no rows`.
4. **`stock_lookup(yarn_code)`** returns one yarn: its description, cones on
   hand, metres per cone and bin. A yarn with no row is `no rows`, not a crash.
5. Whatever goes wrong — a bad column, a locked database — **return it as text**.
   A tool that raises ends the run; a tool that explains itself lets the agent
   try again.

**Requirements.** Both tools are read-only. Neither takes a table name as a
parameter and pastes it into SQL. `stock_lookup` takes a code, not a query.

**Example.**

```python
>>> RunQueryTool().run(sql="SELECT yarn_code, cones_on_hand FROM yarn_stock WHERE yarn_code = 'YN-WL27'")
'yarn_code | cones_on_hand\nYN-WL27 | 18'
>>> RunQueryTool().run(sql="SELECT nosuchcolumn FROM looms")
'ERROR: no such column: nosuchcolumn'
>>> StockLookupTool().run(yarn_code="YN-CT19")
'yarn_code | description | cones_on_hand | metres_per_cone | bin\nYN-CT19 | carded cotton 20s | 74 | 25 | A-15'
```

---

### Task 2 — Make `run_query` safe

The analyst writes its own SQL. That is the point of the tool and the risk of it.

1. Accept a statement only if it starts with `SELECT` or `WITH`.
2. Refuse a statement containing any of `INSERT`, `UPDATE`, `DELETE`, `DROP`,
   `ALTER`, `CREATE`, `REPLACE`, `ATTACH`, `DETACH`, `PRAGMA`, `VACUUM`,
   `REINDEX`, `TRUNCATE`, `GRANT`, `REVOKE` — **anywhere in it**, not just at
   the front.
3. Refuse more than one statement: a trailing semicolon is fine, an inner one is
   not.
4. Open the connection **read-only**, so a statement that gets past the checks
   still cannot change anything.
5. Say plainly that a refusal is a refusal. `REFUSED: ...` is enough; the agent
   reads it and has to try something else.
6. Keep the row cap and the query timeout from `millkit`.

**Requirements.** A refusal returns text and does not raise, and it does not
return rows. After any number of refused statements the database file must be
byte for byte what it was.

**Example.**

```python
>>> RunQueryTool().run(sql="DELETE FROM yarn_stock")
'REFUSED: only SELECT or WITH statements are allowed, and this one starts with ...'
>>> RunQueryTool().run(sql="SELECT 1; DROP TABLE looms")
'REFUSED: DROP is not allowed anywhere in a query on this database.'
```

---

### Task 3 — Write `config/agents.yaml` and `config/tasks.yaml`

1. `stock_analyst` reads the database and reports what is held. Its backstory is
   what holds it to the method: look the yarn up before saying anything about it,
   quote no figure that was not read out of the database, and report a yarn with
   no row as not stocked rather than estimating around it.
2. `production_planner` writes the note. Its backstory keeps invented quantities
   out: carry the analyst figures through unchanged, and say plainly when an
   order cannot be met.
3. `stock_check` asks the analyst to establish which yarn the cloth is specified
   in and what is held of it, for `{metres}` metres of `{cloth}` on order
   `{order}`.
4. `production_note` asks the planner to write the note for `{order}`, working
   only from what the analyst established.
5. Every `expected_output` says what the answer should contain, not how long it
   should be.

**Requirements.** Use the four keys exactly. Every string the crew uses has to
come from these files: a role written into the Python instead is a role nobody
can change without a code review.

---

### Task 4 — Write `build_crew()` in `mill/crew.py`

1. Load both YAML files from `millkit.CONFIG_DIR`.
2. Build the two agents from `agents.yaml`, handing each the planning model from
   `millkit.planning_llm()` and capping each at `millkit.MAX_ITER` turns.
3. Give the analyst the tools. Give the planner **none** — it writes from what it
   is handed, which is what keeps unread figures out of the note.
4. Build the two tasks from `tasks.yaml` and assign each to its agent. The
   planner has to end up with the analyst findings in front of it: a sequential
   crew already hands the previous task output on, and naming the stock check as
   the note task **context** says so explicitly. Either is fine; getting neither
   is not.
5. Return a `Crew` over both agents and both tasks with a **sequential** process.

**Requirements.** `build_crew()` takes no arguments: the order arrives as inputs
at run time, which is why the placeholders are in the configuration rather than
in the Python.

**Example.**

```bash
$ python3 -m mill.main --order TM-4301
wrote out/TM-4301.md
$ cat out/TM-4301.md
# Planning note TM-4301

Order TM-4301 is cut from YN-WL14 and needs 480 metres.

Stock table says:
YN-WL14 | 26 | 40
...
```

26 cones of 40 metres is 1040 metres available, so 480 can be cut. Those two
figures are in the database and nowhere else — a note that carries them is a note
written from a query.

---

## Run and verify before you submit

```bash
cd /home/user/thistledown-mill

python3 -c 'import crewai; print(crewai.__version__)'   # is it installed yet
curl -s http://127.0.0.1:8433/health                    # is the model up

python3 check_local.py            # your tools, then one order end to end

python3 -m mill.main --order TM-4390
cat out/TM-4390.md
```

`check_local.py` calls your tools directly first — no planning model involved —
so a wrong figure there is a bug in the tool and not in the crew.

## How you are graded

Five checks, 10 points each, 50 in total.

1. **The tools.** Called directly, with no planning model involved: the right
   figures out of the store, every row of the yarn table, and a database error
   handed back as text rather than raised.
2. **The guard.** Six write and multi-statement attempts, each refused in words,
   none returning rows, and the database byte for byte unchanged afterwards.
3. **The crew.** Two agents, two tasks, all four built from the configuration
   files, sequential, the database tool in exactly one pair of hands, and every
   agent capped.
4. **A run.** One order planned end to end, with a note carrying stock figures
   that only a query could have supplied.
5. **An order that cannot be met.** The yarn with no stock row comes back as a
   plain answer rather than an error, and the run still produces a note instead
   of looping.
