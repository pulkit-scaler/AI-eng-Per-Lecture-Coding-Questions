# Ashford Grid

## Scenario

Ashford runs an electricity distribution network. The control room asks questions in plain English,
and a query agent answers them from the operations database. The agent already writes SQL, runs it
and reports whatever comes back, including a database error. Nobody checks the query before it runs,
nobody feeds a failure back for a second try, and every request goes down one path no matter what it
asks for.

You build the layer above that agent: a review step, a bounded refine loop, a retry that reads the
database error, a classifier with a dispatch table, and a set of guard checks that run at the same
time.

## What you will build

Five callables in one file, `solution.py`:

- `critique_query` asks for a structured verdict on a candidate query and never runs it.
- `self_improving_query` drafts, reviews, refines and re-reviews, then runs only what passed.
- `execute_with_feedback` runs a query, reads the database error, and retries with that error and
  every earlier one attached.
- `route_request` classifies a request and dispatches it through a lookup table.
- `parallel_guards` runs four independent guard checks at the same time and aggregates them.

## Environment

The machine is already provisioned. You install nothing.

- **Python:** 3, run as `python3`. `python` is linked to the same interpreter.
- **Installed:** the `openai` package and its own dependencies, which include `httpx` and
  `pydantic`. The Python standard library is available in full.
- **Model endpoint:** already running on `http://127.0.0.1:8836`. The provided client talks to it.
  Leave it running. Check it with `curl -s http://127.0.0.1:8836/health`, which answers
  `{"status": "ok", ...}`.
- **Project directory:** `/home/user/ashford-grid/`. Run every command from there, so that
  `import solution` and `import grid_kit` both resolve.
- **Database:** a SQLite file at `data/grid_ops.db` inside the project. It is opened read only. A
  statement that would change data comes back as an error rather than changing anything.
- **Time budget:** each call you are graded on has well under two minutes. Keep every loop bounded by
  the `max_attempts` you were passed. A loop that does not terminate is recorded as a failure rather
  than waited for.

## Project layout

```
/home/user/ashford-grid/
├── solution.py            <- you write this. It is the only file that is assessed.
├── check_local.py            provided, do not modify (prints what your functions return)
├── data/
│   └── grid_ops.db           provided, do not modify (the operations database)
└── grid_kit/                 provided, do not modify
    ├── __init__.py           re-exports every name below
    ├── client.py             make_client(), MODEL
    ├── db.py                 DB_PATH, connect()
    ├── persona.py            PERSONA, build_system_prompt()
    ├── prompts.py            the four role prompts, GUARD_PROMPTS, GUARD_NAMES
    ├── tools.py              list_tables(), get_table_schema(), schema_summary(),
    │                         execute_sql(), run_sql()
    └── handlers.py           the four desks
```

You open `solution.py` and nothing else.

## The pieces you are given

Every name below is importable straight from the package:

```python
from grid_kit import make_client, MODEL, execute_sql, schema_summary
```

### `grid_kit/client.py`

**`make_client() -> openai.OpenAI`**
Returns a client already pointed at the local endpoint, with a 20 second request timeout and a
retry budget of 2. Build it once and reuse it.

**`MODEL: str`**
The model name to pass on every call. Its value is `"ashford-grid-ops"`.

```python
from grid_kit import make_client, MODEL

client = make_client()
response = client.chat.completions.create(
    model=MODEL,
    temperature=0.0,
    messages=[{"role": "system", "content": "You are a helpful assistant."},
              {"role": "user", "content": "Say ok."}],
)
reply = response.choices[0].message.content   # -> str
```

The 20 second timeout is set for you because the SDK default is several minutes, which is longer
than a graded call may take.

### `grid_kit/db.py`

**`DB_PATH: str`**
Absolute path to the database file. On the VM it is
`/home/user/ashford-grid/data/grid_ops.db`.

**`connect() -> sqlite3.Connection`**
Opens a read-only connection to that file. The three tools below already use it, so you will not
normally need it.

```python
from grid_kit import DB_PATH, connect

conn = connect()
print(conn.execute("SELECT COUNT(*) FROM feeders").fetchone())   # -> (14,)
conn.close()
```

### `grid_kit/persona.py`

**`PERSONA: dict`**
The desk the queries are written for. Its keys are `role`, `instructions`, `rules` and
`output_format`.

**`build_system_prompt(persona=None) -> str`**
Renders a persona dict into a system prompt string. Called with no argument it renders `PERSONA`.

```python
from grid_kit import build_system_prompt

print(build_system_prompt().splitlines()[0])
# You are a Grid Operations Data Analyst for the Ashford network.
```

These two are background. None of the five tasks needs them, and the four role prompts below are
what you send instead.

### `grid_kit/prompts.py`

Five system prompts and one list. Each is the **system** message for one role. You write the user
message, and what you put in it is all that role has to work with.

**`DRAFT_SYSTEM_PROMPT: str`**
Write a first SQLite SELECT query for a question. Returns only SQL.

**`CRITIQUE_SYSTEM_PROMPT: str`**
Review a candidate query. Returns only JSON of the form
`{"valid": true or false, "reason": "one sentence"}`. When the query is not fit to run, the reason
names the column or table that does not exist and the real one to use instead when there is one.

**`REFINE_SYSTEM_PROMPT: str`**
Rewrite a query so that the problems reported to it are fixed. Returns only SQL. It can fix only
what your user message tells it about.

**`ROUTE_SYSTEM_PROMPT: str`**
Classify one control-room request. Returns only JSON of the form
`{"category": "...", "confidence": 0.0 to 1.0, "reasoning": "one sentence"}`. The four categories it
chooses between are `outage_lookup`, `capacity_check`, `load_trend` and `schema_help`.

**`GUARD_PROMPTS: dict[str, str]`**
One system prompt per guard, keyed by guard name. Each guard inspects a candidate query for its own
concern only and returns only JSON of the form
`{"guard": "<name>", "passes": true or false, "reason": "one sentence"}`.

**`GUARD_NAMES: list[str]`**
The four guard names in order: `["schema_compliance", "aggregation_logic", "write_safety",
"scan_scope"]`. These are exactly the keys of `GUARD_PROMPTS`.

```python
from grid_kit import GUARD_NAMES, GUARD_PROMPTS

for name in GUARD_NAMES:
    print(name, "->", len(GUARD_PROMPTS[name]), "characters of system prompt")
# schema_compliance -> 463 characters of system prompt
# aggregation_logic -> 537 characters of system prompt
# write_safety -> 499 characters of system prompt
# scan_scope -> 499 characters of system prompt
```

The four guard concerns are: every table and column named must exist (`schema_compliance`); plain
columns beside an aggregate need a `GROUP BY` and a `GROUP BY` needs something aggregated
(`aggregation_logic`); the statement must only read (`write_safety`); the query must be bounded by a
`WHERE`, a `GROUP BY`, a `LIMIT` or an aggregate (`scan_scope`).

### `grid_kit/tools.py`

**`list_tables() -> list[str]`**
Every table name in the database, sorted.

```python
>>> list_tables()
['feeders', 'load_readings', 'outages', 'substations']
```

**`get_table_schema(table_name: str) -> list[str]`**
The column names of one table, in schema order.

```python
>>> get_table_schema('feeders')
['feeder_id', 'substation_id', 'feeder_code', 'capacity_mw', 'status']
```

**`schema_summary() -> str`**
One `table: col, col, ...` line per table, ready to drop into a prompt.

```python
>>> print(schema_summary())
  feeders: feeder_id, substation_id, feeder_code, capacity_mw, status
  load_readings: reading_id, feeder_id, taken_at, load_mw
  outages: outage_id, feeder_id, cause, started_at, duration_min, customers_affected
  substations: substation_id, name, region, voltage_kv, commissioned_year
```

**`execute_sql(query: str) -> str`**
Runs a query and returns the result rendered as text: a header line of column names, then one line
per row, fields joined by ` | `. A query with no rows renders as the header plus `(no rows)`.

On a database error it does not raise. It returns a string beginning with `ERROR: ` followed by the
database's own message. That message is the feedback Task 3 is built on.

```python
>>> print(execute_sql("SELECT region, COUNT(*) AS n FROM substations GROUP BY region ORDER BY region"))
region | n
East | 2
North | 2
South | 2
West | 2

>>> execute_sql("SELECT nope FROM feeders")
'ERROR: no such column: nope'

>>> execute_sql("DELETE FROM feeders")
'ERROR: attempt to write a readonly database'
```

**`run_sql(query: str) -> tuple[list[str], list[tuple]]`**
The same execution, returning `(columns, rows)`, and raising `sqlite3.Error` on a database error
instead of returning a string.

```python
>>> run_sql("SELECT feeder_code, capacity_mw FROM feeders WHERE status = 'active' ORDER BY capacity_mw DESC LIMIT 3")
(['feeder_code', 'capacity_mw'], [('TAR-F1', 30.0), ('MAR-F1', 27.0), ('TAR-F2', 25.5)])
```

Use `execute_sql` where you want to read the error and `run_sql` where you want an exception.

### `grid_kit/handlers.py`

Four desks, one per routing category. Each takes the request string, answers from the database and
returns a single line of text. The line begins with a fixed desk prefix and then carries counts read
from the database at the moment the desk runs.

**`handle_outage_lookup(request: str) -> str`**
Returns `OUTAGE-DESK | outages=<count> | customers=<count>`.

**`handle_capacity_check(request: str) -> str`**
Returns `CAPACITY-DESK | active_feeders=<count> | capacity_mw=<total>`.

**`handle_load_trend(request: str) -> str`**
Returns `LOAD-DESK | readings=<count> | peak_mw=<max>`.

**`handle_schema_help(request: str) -> str`**
Returns `SCHEMA-DESK | substations=<count>`.

```python
from grid_kit import handle_capacity_check

line = handle_capacity_check("What spare capacity is left on the active feeders?")
print(line)
# CAPACITY-DESK | active_feeders=... | capacity_mw=...
```

The counts are read from the database, not from a constant, so there is nothing to memorise here.
Return the line the desk hands you without touching it.

### `check_local.py`

Not a library. Run it to print what each of your five functions returns on a handful of sample
inputs. It scores nothing.

## The data

Four tables, all read only. These are the real table and column names, and they are also what
`schema_summary()` returns at run time:

- **`substations`**: `substation_id`, `name`, `region`, `voltage_kv`, `commissioned_year`. Eight
  rows. `region` holds `North`, `East`, `South` or `West`.
- **`feeders`**: `feeder_id`, `substation_id`, `feeder_code`, `capacity_mw`, `status`. Fourteen rows.
  `feeder_code` looks like `TAR-F1`. `status` holds `active`, `maintenance` or `retired`.
  `substation_id` joins to `substations`.
- **`outages`**: `outage_id`, `feeder_id`, `cause`, `started_at`, `duration_min`,
  `customers_affected`. Eighteen rows. `cause` holds `storm`, `equipment`, `vegetation` or `animal`.
  `started_at` is a text timestamp like `2026-02-14 18:20`. `feeder_id` joins to `feeders`.
- **`load_readings`**: `reading_id`, `feeder_id`, `taken_at`, `load_mw`. Twenty four rows, three
  readings per feeder for a single day. `feeder_id` joins to `feeders`.

Two things follow from this, and both matter to the tasks:

- **A question can name something that is not there.** Nothing in the schema records reactive power,
  harmonic distortion or weather. A question about one of those has no correct query, so Task 2 has
  to stop at its limit rather than refine forever.
- **Read the schema at run time, do not retype it.** `schema_summary()` is one call and it is always
  current. Your functions are called on questions, requests and candidate queries you have not seen.

## Interface contract

These are fixed. Everything else is your choice.

- The project directory is `/home/user/ashford-grid/` and your work goes in `solution.py`.
- `solution.py` defines these five callables, with these names:
  - `critique_query(question: str, candidate_sql: str) -> dict`
    returns `{"valid": bool, "reason": str}`
  - `self_improving_query(question: str, max_attempts: int) -> dict`
    returns `{"sql": str, "result": str or None, "attempts": int, "accepted": bool}`
  - `execute_with_feedback(question: str, max_attempts: int) -> dict`
    returns `{"sql": str, "result": str or None, "attempts": int, "succeeded": bool,
    "error_memory": list}`
  - `route_request(request: str) -> dict`
    returns `{"category": str, "result": str}`
  - `parallel_guards(candidate_sql: str) -> dict`
    returns `{"blocked": bool, "blocked_by": list, "guards": list}`
- Both arguments are passed positionally, in the order shown.
- A dict you return may carry extra keys. The keys listed above must be present with the types
  shown.
- The four categories are exactly `outage_lookup`, `capacity_check`, `load_trend` and `schema_help`.
  Each is answered by the desk of the same name.
- The four guard names are exactly `schema_compliance`, `aggregation_logic`, `write_safety` and
  `scan_scope`, which are the entries of `GUARD_NAMES` and the keys of `GUARD_PROMPTS`.
- The error prefix `execute_sql` uses for a database error is `ERROR: `, with one space.
- Result text and desk lines are compared after stripping surrounding whitespace, and must otherwise
  match exactly. Return what `execute_sql` and the desks give you rather than reformatting it.
- `MODEL` is the model name to pass. The endpoint is at `http://127.0.0.1:8836`.

Beyond this list, structure your helpers, classes and prompts however you like.

## Your tasks

### Task 1: `critique_query(question: str, candidate_sql: str) -> dict`

**Goal.** Get a structured verdict on whether a candidate query is fit to run, without running it.

**Steps.**

1. Send one model turn with `CRITIQUE_SYSTEM_PROMPT` as the system message.
2. Build the user message so the reviewer has three things: the `question`, the schema from
   `schema_summary()`, and the `candidate_sql` itself.
3. Read the reply text from `response.choices[0].message.content`.
4. Parse it as JSON. It has a `valid` field and a `reason` field.
5. Return `{"valid": bool(...), "reason": str(...)}`.

**Requirements.**

- Return type is a `dict` with `valid` a real Python `bool` and `reason` a `str`.
- `reason` is the reviewer's own sentence, passed through unchanged. Do not trim it, rephrase it,
  add to it or replace it with your own wording. Task 2 forwards this sentence to the repair step,
  so its detail is what makes the repair possible.
- The `candidate_sql` must appear in the user message you send. A reviewer that is not shown the
  query cannot review it.
- **Do not execute anything against the database in this function.** Not the candidate, not a
  probe, not a schema query through `execute_sql` or `run_sql`. Not even to confirm a verdict you
  have already received.
- Reading the schema is fine, because `list_tables`, `get_table_schema` and `schema_summary`
  inspect the catalogue rather than running the candidate.
- Edge case, a reply that is not JSON: the return value is
  `{"valid": False, "reason": "<a sentence saying the review could not be read>"}` rather than an
  exception. The wording of that sentence is yours; nothing depends on it.
- Edge case, JSON with `valid` or `reason` missing: read the missing field as `False` and `""`
  respectively, again rather than raising.

**Example.** Real output, with the reply from the reviewer left exactly as it arrived:

```python
critique_query("Which substations run above 100 kV?",
               "SELECT name, line_voltage FROM substations")
# {'valid': False,
#  'reason': "invalid: column 'line_voltage' does not exist on table 'substations'; "
#            "use 'voltage_kv' instead"}

critique_query("Which substations run above 100 kV?",
               "SELECT name, voltage_kv FROM substations WHERE voltage_kv > 100")
# {'valid': True, 'reason': 'ok: every table and column named is in the schema'}
```

### Task 2: `self_improving_query(question: str, max_attempts: int) -> dict`

**Goal.** Draft a query, review it, refine it from the review, review it again, and run only what
passed review.

**Steps.**

1. Ask for a first draft: one model turn with `DRAFT_SYSTEM_PROMPT`, and a user message carrying the
   `question` and `schema_summary()`.
2. Clean the draft: strip any surrounding code fence and any trailing semicolon.
3. Review the current candidate with `critique_query(question, sql)`. That review is one **attempt**.
4. If the verdict is valid, run the query with `execute_sql(sql)` and stop. That is the only query
   this function may run.
5. If the verdict is not valid, and attempts remain, ask for a repair: one model turn with
   `REFINE_SYSTEM_PROMPT`, and a user message carrying the `question`, `schema_summary()`, the query
   that was rejected, **and the `reason` from the review**.
6. Clean the repaired query the same way, make it the current candidate, and go back to step 3.
7. Return the four keys below.

**Requirements.**

- Return type is a `dict`: `{"sql": str, "result": str or None, "attempts": int,
  "accepted": bool}`.
- **`attempts` counts candidates reviewed.** One increment per `critique_query` call. It does not
  count draft turns, repair turns or executions.
- **`max_attempts` is a ceiling on candidates reviewed.** At the boundary the loop stops rather
  than doing one more thing. When the count of reviews reaches `max_attempts` and the last verdict
  was not valid, the function returns. It does not ask for one more repair, since there would be no
  review left to spend on the result. So `max_attempts` reviews imply at most `max_attempts - 1`
  repair turns.
- Worked through: with `max_attempts=1` you send one draft turn, one review, and no repair turn. With
  `max_attempts=4` and a question that never converges, you send one draft turn, four reviews and
  three repair turns, and return `attempts=4`.
- **The repair request must carry the review's `reason`.** A repair asked for without saying what
  was wrong gets the same query back, and the loop spends its whole budget without converging.
- **Nothing that failed review may be executed.** Not the draft, not an intermediate repair, not to
  see what happens. The one query this function runs is the candidate that passed review.
- `result` is exactly the string `execute_sql` returned for the accepted candidate. If nothing was
  ever accepted, `result` is `None`.
- `sql` is the last candidate you held, whether it was accepted or not.
- `accepted` is `True` when a candidate passed review and `False` when none did.
- Some questions cannot be answered from this schema. Those end at the limit with
  `accepted=False`, `result=None` and `attempts` equal to `max_attempts`.

**Example.** Real output. The first draft named a column the schema does not have, so it was
rejected. The repair fixed it and the second review passed. Two candidates were reviewed, so
`attempts` is 2:

```python
self_improving_query("Which feeder had the longest outage, and how many minutes was it?", 4)
# {'sql': 'SELECT f.feeder_code, o.duration_min FROM outages o '
#         'JOIN feeders f ON o.feeder_id = f.feeder_id '
#         'ORDER BY o.duration_min DESC LIMIT 1',
#  'result': 'feeder_code | duration_min\nTAR-F1 | 330',
#  'attempts': 2,
#  'accepted': True}
```

A question the schema cannot answer stops at the ceiling, having run nothing:

```python
self_improving_query("Which substation has the highest harmonic distortion?", 3)
# {'sql': 'SELECT name, harmonic_distortion_pct FROM substations '
#         'ORDER BY harmonic_distortion_pct DESC LIMIT 1',
#  'result': None,
#  'attempts': 3,
#  'accepted': False}
```

### Task 3: `execute_with_feedback(question: str, max_attempts: int) -> dict`

**Goal.** Run the query. When the database rejects it, feed the rejection back and try again,
keeping every failure so far.

**Steps.**

1. Ask for a first draft and clean it, exactly as in Task 2 steps 1 and 2.
2. Run the current query with `execute_sql(sql)`. That run is one **attempt**.
3. If the returned string does **not** begin with `ERROR: `, it is a success. Return it.
4. If it does begin with `ERROR: `, take the text after that prefix. That is the database's own
   message.
5. Append an entry to the **error memory**: a dict recording the `question`, the query that failed,
   and that message.
6. If attempts remain, ask for a repair: one model turn with `REFINE_SYSTEM_PROMPT`, and a user
   message carrying the `question`, `schema_summary()`, the query that was rejected, **the database
   error message**, and **every entry in the error memory, not only the newest one**.
7. Clean the repaired query, make it current, and go back to step 2.
8. Return the five keys below.

**Requirements.**

- Return type is a `dict`: `{"sql": str, "result": str or None, "attempts": int,
  "succeeded": bool, "error_memory": list}`.
- **`attempts` counts queries run.** One increment per `execute_sql` call. It does not count draft
  turns or repair turns.
- **`max_attempts` is a ceiling on queries run, and it resolves the same way as Task 2's ceiling.**
  When the count of runs reaches `max_attempts` and the last run was an error, the function stops
  and returns. It does not ask for one more repair. So `max_attempts` runs imply at most
  `max_attempts - 1` repair turns. The two tasks count different operations, but both stop at the
  ceiling rather than doing one more thing.
- Worked through: with `max_attempts=3` and a draft that fails twice before succeeding, you make
  three `execute_sql` calls and two repair turns, and return `attempts=3`.
- **`error_memory` holds one entry per rejection, oldest first.** Its length is therefore
  `attempts - 1` when the last run succeeded, and `attempts` when every run was rejected.
- Each entry is a dict. **It must contain the database's error message text.** The shape this lab
  uses is `{"question": ..., "failed_sql": ..., "error": ...}`, which is what the example shows, and
  it is the shape to write unless you have a reason not to.
- **The accumulated error memory must reach the repair request, not only the return value.** The
  database reports one problem at a time, so a query with two bad names takes two repairs, and the
  second repair needs the first failure as well as the second. A repair asked for without the error
  text has nothing to correct.
- `result` is exactly the string `execute_sql` returned for the successful run, or `None` if no run
  succeeded.
- `sql` is the last query you held. `succeeded` is `True` when a run came back without the `ERROR: `
  prefix.

**Example.** Real output. The draft named a column that does not exist, the database said so, and
the repair fixed it:

```python
execute_with_feedback("What is the average load in megawatts for each feeder code?", 3)
# {'sql': 'SELECT f.feeder_code, AVG(r.load_mw) AS avg_load_mw '
#         'FROM load_readings r JOIN feeders f ON r.feeder_id = f.feeder_id '
#         'GROUP BY f.feeder_code ORDER BY avg_load_mw DESC',
#  'result': 'feeder_code | avg_load_mw\nTAR-F1 | 27.8333\nMAR-F1 | 23.9\n'
#            'TAR-F2 | 21.7667\nASH-F1 | 20.2333\nOCK-F1 | 16.5667\n'
#            'ASH-F2 | 15.2333\nPEV-F1 | 13.7\nKEL-F1 | 12.7333',
#  'attempts': 2,
#  'succeeded': True,
#  'error_memory': [
#      {'question': 'What is the average load in megawatts for each feeder code?',
#       'failed_sql': 'SELECT f.feeder_code, AVG(r.load_megawatts) AS avg_load_mw '
#                     'FROM load_readings r JOIN feeders f ON r.feeder_id = f.feeder_id '
#                     'GROUP BY f.feeder_code ORDER BY avg_load_mw DESC',
#       'error': 'no such column: r.load_megawatts'}]}
```

### Task 4: `route_request(request: str) -> dict`

**Goal.** Make one classification decision, then dispatch the request to the desk that matches it.

**Steps.**

1. Send one model turn with `ROUTE_SYSTEM_PROMPT` as the system message and the `request` in the
   user message.
2. Parse the reply as JSON and read its `category` field.
3. Look the category up in a dispatch table mapping each of the four category names to the desk
   function that handles it.
4. Call that desk with the `request`, and keep exactly what it returns.
5. Return `{"category": ..., "result": ...}`.

**Requirements.**

- Return type is a `dict`: `{"category": str, "result": str}`.
- **`category` is the category the classification step produced.** Return that value. Do not
  substitute your own reading of the request.
- **The desk you call is the one the returned category names.** Look the category up in a table
  mapping name to desk. A dispatch table is the shape that holds: adding a fifth category means
  adding one entry to a dict, and a chain of conditionals over words in the request gets the answer
  wrong anyway. The requests are phrased the way a control-room operator phrases them, and none of
  them contains its own category name.
- **`result` is the desk's line, unmodified.** No stripping beyond what the desk returned, no
  reformatting, no recomputing the counts yourself.
- Exactly one classification turn per call.
- Edge case, a category that is not one of the four: return it as it came back, with `result` set
  to the empty string `""`, rather than raising or falling back to a desk.
- Edge case, a reply that is not JSON or has no `category` field: treat the category as absent and
  return an empty `result`. `{"category": "", "result": ""}` is the shape; any category string you
  prefer alongside an empty result is equally fine.

**Example.** Real output. The counts in the desk line come from the database, so treat the field
names as the shape and the numbers as whatever the data says:

```python
route_request("What tables does this database have?")
# {'category': 'schema_help', 'result': 'SCHEMA-DESK | substations=...'}

route_request("Show me the outage history for the East region.")
# {'category': 'outage_lookup', 'result': 'OUTAGE-DESK | outages=... | customers=...'}
```

### Task 5: `parallel_guards(candidate_sql: str) -> dict`

**Goal.** Ask four independent guards about one candidate query at the same time, and aggregate
their verdicts into one decision.

**Steps.**

1. For each `name` in `GUARD_NAMES`, one model turn with `GUARD_PROMPTS[name]` as the system message
   and the `candidate_sql` in the user message.
2. Start all four turns before waiting for any of them, so the four are in flight together.
3. Parse each reply as JSON. Each has `guard`, `passes` and `reason`.
4. Collect one verdict per guard as `{"guard": str, "passes": bool, "reason": str}`.
5. Aggregate: any single guard that does not pass blocks the candidate. Collect the names of the
   guards that did not pass, and sort them.
6. Return `{"blocked": ..., "blocked_by": ..., "guards": ...}`.

**Requirements.**

- Return type is a `dict`: `{"blocked": bool, "blocked_by": list, "guards": list}`.
- `guards` holds exactly four verdicts, one per name in `GUARD_NAMES`, in any order.
- `blocked` is `True` when at least one guard did not pass, and `False` when all four passed.
- `blocked_by` is a sorted list of the `guard` names that did not pass. It is `[]` when none did.
- **All four guards are asked, every time, whatever the first one says.** There is no short circuit.
  The checks are independent, so no verdict is a reason to skip another.
- **All four requests must be in flight at the same time.** The overlap is measured, from how much
  of the four requests' elapsed time ran alongside another request's. Two at a time is not enough,
  and neither is three: submit all four, then wait for them. A `ThreadPoolExecutor` with fewer than
  four workers runs them in batches and will not satisfy this. A loop that calls the guards one
  after another will not either.
- Use the standard library for the concurrency. `concurrent.futures.ThreadPoolExecutor` with
  `as_completed`, `wait`, `map` or plain `.result()` calls all work, and so do raw
  `threading.Thread` objects. Pick whichever you prefer. The requirement is the overlap, not the
  module.
- Edge case, a guard reply that is not JSON: record that guard as `passes=False` with a reason of
  your choosing, rather than raising. The guard stays in `guards` either way, so `guards` always
  holds four entries.
- The `reason` text for each guard is whatever that guard sent. Nothing depends on its wording.

**Example.** Real output. The first candidate scans a whole table with no bound, so `scan_scope`
objects and one objection is enough to block it:

```python
parallel_guards("SELECT feeder_code FROM feeders")
# {'blocked': True,
#  'blocked_by': ['scan_scope'],
#  'guards': [{'guard': 'aggregation_logic', 'passes': True,
#              'reason': 'grouping matches the aggregation'},
#             {'guard': 'scan_scope', 'passes': False,
#              'reason': 'an unbounded scan with no WHERE, GROUP BY, LIMIT or '
#                        'aggregate is not permitted'},
#             {'guard': 'write_safety', 'passes': True,
#              'reason': 'the statement only reads'},
#             {'guard': 'schema_compliance', 'passes': True,
#              'reason': 'every table and column named is in the schema'}]}

parallel_guards("SELECT region, COUNT(*) AS n FROM substations GROUP BY region")
# {'blocked': False, 'blocked_by': [], 'guards': [ ...four verdicts, all passes=True... ]}
```

The order of `guards` above is completion order, which is why it is not the order of `GUARD_NAMES`.
Either order is fine.

## Run and verify locally

Check the endpoint is up:

```bash
curl -s http://127.0.0.1:8836/health
# {"status": "ok", "service": "gridd", "database": "grid_ops.db"}
```

Print what your five functions return:

```bash
cd /home/user/ashford-grid
python3 check_local.py
```

The output looks like this, one block per sample input:

```
==========================================================================
Task 1 - the review gate
--------------------------------------------------------------------------
critique_query('Which substations run above 100 kV?', 'SELECT name, line_voltage FROM substations')
  -> {
  "valid": false,
  "reason": "invalid: column 'line_voltage' does not exist on table 'substations'; use 'voltage_kv' instead"
}
```

A function you have not written yet prints `-> not implemented yet (...)`, and one that raises
prints its traceback.

Drive individual pieces yourself:

```bash
cd /home/user/ashford-grid
python3 -c "
import solution
print(solution.route_request('What spare capacity is left on the active feeders?'))
print(solution.parallel_guards('SELECT * FROM outages'))
"
```

Look around the database while you work:

```bash
cd /home/user/ashford-grid
python3 -c "
from grid_kit import list_tables, get_table_schema, schema_summary, execute_sql
print(list_tables())
print(get_table_schema('outages'))
print(schema_summary())
print(execute_sql('SELECT * FROM substations LIMIT 3'))
"
```

## Before you submit

- `solution.py` in `/home/user/ashford-grid/` is the only file that is assessed. Changes to anything
  under `grid_kit/`, to `data/grid_ops.db` or to `check_local.py` do not count.
- Run `cd /home/user/ashford-grid && python3 check_local.py` and read the whole output. A
  `solution.py` that has never been executed has never been through even one round trip, and a
  module-scope error there costs every task at once.
- Confirm every one of the five functions returns the keys listed in the Interface contract, with
  the types listed there.
- The questions, requests and candidate queries shown above are illustrations. Your functions are
  run against a different set of inputs, so a solution that only handles the samples will not pass.
  Write for any valid question, request or candidate query.
