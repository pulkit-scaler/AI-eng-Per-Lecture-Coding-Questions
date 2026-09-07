# The Foundry's Voice

## Scenario

Kilnbrook Foundry pours molten metal into sand moulds. Every shift the supervisors send the data
team the same kind of question in plain English: which alloy runs hottest, how much metal went out
on the day shift, how much of it came back as scrap. Each answer means someone opens the operations
database and writes SQL by hand, and the queue never empties.

The foundry wants that queue replaced by an agent the supervisors can talk to. A local model
endpoint and the operations database are already running on this machine, and the model client, the
database helper and the analyst persona are already written for you. You write the agent: the
system prompt, the tool schemas, the three tools that read the database, the loop that drives them,
and the shared conversation that lets a follow-up question build on the answer before it.

## What you will build

All of it goes in one file, `solution.py`:

- `build_system_prompt(persona)`, which turns the provided persona dictionary into the system
  prompt the agent opens every conversation with.
- `build_tools_schema()`, which describes your three tools to the model in the format the chat
  completions API expects.
- `list_tables()`, `get_table_schema(table_name)` and `execute_sql(query)`: three tools that run
  real queries against the real SQLite file, the last of them refusing anything that would change
  the data.
- `run_agent(question)`, the loop that sends the conversation, runs the tool the model asks for,
  reports the result back, and repeats until the model answers in text.
- `run_session(questions)`, which answers a list of questions on one shared message list so the
  second question can reuse what the first one discovered.

No agent framework is involved. This is the chat completions API and a loop you write yourself.

## Environment

The machine is already provisioned. You install nothing.

- **Python:** Python 3 (`python3`, also available as `python`).
- **Installed:** the `openai` package, the packages it depends on, and the Python standard
  library. `sqlite3` and `json` come from the standard library and are what the tools need.
- **Model endpoint:** already answering on `http://127.0.0.1:8781/v1`. Leave it running. Check it
  with `curl -s http://127.0.0.1:8781/health`, which prints a short JSON status line.
- **Database:** a SQLite file at `/home/user/kilnbrook-foundry/data/foundry.db`. Open it through
  `kiln_kit.connect()` rather than writing the path into your code. Read it. Never change it.
- **Work in `/home/user/kilnbrook-foundry/`** and run every command from that directory, so that
  `import solution` and `import kiln_kit` both resolve.
- **Time budget:** each of your functions is called with a bound of well under two minutes. A loop
  with no stop condition is recorded as a failure rather than left to run, so keep every loop
  bounded.

## Project layout

```
/home/user/kilnbrook-foundry/
├── solution.py            you write this; it is the only file assessed
├── check_local.py         provided, do not modify: prints what your functions return
├── kiln_kit/
│   ├── __init__.py        provided, do not modify: re-exports the four names below
│   ├── client.py          provided, do not modify: make_client(), MODEL_NAME
│   ├── db.py              provided, do not modify: connect(), DB_PATH
│   └── persona.py         provided, do not modify: the PERSONA dictionary
└── data/
    └── foundry.db         provided, read only: the operations database
```

The one file you open is `solution.py`. It arrives with every function stubbed out and each stub
raising `NotImplementedError`.

## The pieces you are given

### `kiln_kit.make_client()`

Returns an `openai.OpenAI` client already pointed at the local endpoint, with a request timeout and
a retry count that suit it. Use it the way you would use the hosted API.

```python
from kiln_kit import MODEL_NAME, make_client

client = make_client()
response = client.chat.completions.create(
    model=MODEL_NAME,
    messages=[{"role": "system", "content": "You are a helpful analyst."},
              {"role": "user", "content": "Say hello."}],
)
print(response.choices[0].message.content)
```

### `kiln_kit.MODEL_NAME`

A string. Pass it as `model=` on every request. Its value is `"kilnbrook-analyst"`, but read it
from `kiln_kit` rather than writing the string into your code.

### `kiln_kit.connect()`

Returns a `sqlite3.Connection` to the operations database. Ordinary DB-API from there.

```python
from kiln_kit import connect

conn = connect()
cursor = conn.execute("SELECT alloy_code FROM alloys LIMIT 2")
print([column[0] for column in cursor.description])   # ['alloy_code']
print(cursor.fetchall())                              # [('KB-101',), ('KB-104',)]
conn.close()
```

`cursor.description` holds one entry per column of the result, and the column name is the first
field of each entry. That is how you get headers for the rows you render.

### `kiln_kit.PERSONA`

A dictionary with exactly four keys:

- **`role`**: a one-line string naming who the agent is.
- **`instructions`**: a multi-line string. It contains a numbered four-step workflow telling the
  model to list the tables, read the schema of the table it needs, write one SELECT, then run it.
- **`rules`**: a list of five strings. One of them forbids `DELETE`, `DROP`, `UPDATE`, `INSERT` and
  any other data-modifying SQL.
- **`output_format`**: a multi-line string asking for three things in every answer: the SQL that
  ran, the result it returned, and one plain-English sentence.

```python
from kiln_kit import PERSONA

print(PERSONA["role"])          # Senior Foundry Data Analyst
print(len(PERSONA["rules"]))    # 5
print(sorted(PERSONA))          # ['instructions', 'output_format', 'role', 'rules']
```

### `check_local.py`

A provided script that calls each of your seven functions on a few sample inputs and prints what
came back. It does not score you. Run it with `python3 check_local.py` from the project directory.

## The data

`foundry.db` is a small SQLite file holding three tables: `alloys`, `moulds` and `pours`.

- **`alloys`**: one row per alloy grade the foundry melts. Its columns are `alloy_id`,
  `alloy_code`, `base_metal`, `melt_point_c` and `tensile_mpa`. Codes look like `KB-101`; base
  metals are values such as `bronze` and `steel`.
- **`moulds`**: one row per mould pattern. Each row carries the mould's code, how many cavities it
  has, the kind of sand it is cut in (values such as `green_sand`), and the most metal it can take.
- **`pours`**: one row per pour on the shop floor. Each row carries the alloy and the mould used,
  the weight poured, the shift the pour ran on (`day`, `night` or `swing`), and the scrap weight
  that came back.

Every column in the file is `INTEGER` or `TEXT`, so every value has one plain string form.

**Only the `alloys` column names are listed above, and only because Task 3's example needs them.**
The column names of `moulds` and `pours` are not written down anywhere you can read them, and
neither is the number of rows in any table. Your tools have to read those from the database when
they are called. Task 3 is assessed on that: the tools must work against a database whose
columns they were not told about.

You will be asked questions about all three tables, not only the ones in the examples below.

## Interface contract

These names and values are fixed. Everything else is yours.

- The project directory is `/home/user/kilnbrook-foundry/` and your work goes in `solution.py`.
- `solution.py` defines the module-level constant `MAX_MODEL_TURNS = 8`.
- `solution.py` defines these seven callables, with these exact names and argument names:
  - `build_system_prompt(persona: dict) -> str`, the system prompt text.
  - `build_tools_schema() -> list`, a list of three OpenAI-format tool entries.
  - `list_tables() -> list[str]`, the table names.
  - `get_table_schema(table_name: str) -> list[str]`, the column names of one table.
  - `execute_sql(query: str) -> str`, the query result or a refusal, always a string.
  - `run_agent(question: str) -> str`, the final answer text for one question.
  - `run_session(questions: list[str]) -> list[str]`, one answer per question, in order.
- The three tools are named exactly `list_tables`, `get_table_schema` and `execute_sql`, both as
  Python functions and as the `name` in the schemas you build.
- `get_table_schema` takes one required parameter named `table_name`. `execute_sql` takes one
  required parameter named `query`. `list_tables` takes no parameters.
- A refusal from `execute_sql` is a string whose first characters are `REFUSED:`.
- The endpoint is `http://127.0.0.1:8781/v1`, reached through `make_client()`. The model name is
  reached through `MODEL_NAME`.
- Answers are checked by looking for the values the database produced inside the string you return.
  Layout, headings, spacing and column separators are not checked anywhere.

Anything not fixed in this list is your choice.

## Your tasks

### Task 1: `build_system_prompt(persona)`

**Goal.** Turn the persona dictionary into the single string the agent sends as its system message.

**Steps.**

1. Take the dictionary as the `persona` argument and read the four values off it.
2. Put the `role` value into the prompt, stating who the agent is.
3. Put the whole `instructions` value in, every line of it. The numbered workflow inside it is what
   tells the model to discover the tables before writing SQL, so a missing line changes what the
   model does.
4. Put in every entry of `rules`. All five. A rule that never reaches the model is a rule the model
   will not follow.
5. Put the whole `output_format` value in.
6. Return one string.

**Requirements.**

- The return value is a `str`, not a list and not a dictionary.
- Every line of `instructions` and of `output_format`, and every one of the five `rules` entries,
  appears in the returned string with its own wording unchanged. Whitespace and letter case are not
  compared, so indenting a rule or upper-casing a heading is fine. Dropping words is not.
- Headings, ordering, bullet characters, indentation and blank lines are yours to choose. There is
  no expected layout.
- The function does not call the endpoint and does not touch the database.

Read the four values off the `persona` argument rather than pasting their text into your file or
importing `PERSONA` inside the function. Both of those work against the persona shipped here and
stop working the moment the dictionary changes, which is the situation this function exists for.

**Example.**

```python
from kiln_kit import PERSONA
print(build_system_prompt(PERSONA))
```

```
You are a Senior Foundry Data Analyst.

INSTRUCTIONS:
You answer questions about the Kilnbrook foundry operations database by writing and running SQL.
Follow this workflow for every question you are asked:
  1. List the available tables using the provided tool.
  2. Read the schema of the relevant table using the provided tool.
  3. Write one syntactically correct SQLite SELECT query.
  4. Execute the query and report what it returned.

RULES:
  - ONLY use table and column names confirmed by the schema tool.
  - NEVER guess or invent table or column names.
  - NEVER run DELETE, DROP, UPDATE, INSERT or any other data-modifying SQL.
  - If a question is ambiguous, state the assumption you are making.
  - If a query fails, read the error and retry with a corrected query.

OUTPUT FORMAT:
Always answer with:
  - the SQL query you ran
  - the result the query returned
  - one short plain-English sentence summarising the answer
```

### Task 2: `build_tools_schema()`

**Goal.** Describe your three tools to the model in the JSON shape the chat completions API reads.

**Steps.**

1. Return a list of three entries, one per tool.
2. Each entry is a dictionary with two keys: `"type"` set to the string `"function"`, and
   `"function"` holding a dictionary.
3. That inner dictionary has three keys: `"name"`, `"description"` and `"parameters"`.
4. `"parameters"` is a JSON schema object: `"type"` set to `"object"`, a `"properties"` dictionary,
   and a `"required"` list naming the parameters the model must supply.
5. For `list_tables`, `"properties"` is empty and there is nothing required.
6. For `get_table_schema`, `"properties"` describes one string parameter named `table_name`, and
   `"required"` contains `"table_name"`.
7. For `execute_sql`, `"properties"` describes one string parameter named `query`, and `"required"`
   contains `"query"`.
8. Give every tool a non-empty `"description"`, written for the model rather than for a developer.
   The description is the only thing the model reads when deciding which tool a question needs.

**Requirements.**

- The return value is a `list`. It contains an entry for each of `list_tables`,
  `get_table_schema` and `execute_sql`, with those exact strings as their `name` values. Three
  entries is the normal answer.
- Each `description` is a non-empty string. An empty or missing description makes the tool unusable
  and the question goes unanswered.
- `get_table_schema` lists `table_name` in both `properties` and `required`. `execute_sql` lists
  `query` in both. Naming the parameter in `properties` but leaving it out of `required` is the
  common mistake here, and it stops the tool being called.
- For `list_tables`, an empty `"required": []` and no `"required"` key at all are both accepted.
- Extra JSON-schema detail is yours: per-parameter `description`, `enum`, `additionalProperties`
  and so on are all fine.
- Declaring a fourth tool of your own is allowed and is ignored. The three above have to be
  present and usable.
- The wording of your descriptions is not compared against anything.

The shape of one entry, with `get_table_schema` as the example:

```python
{
    "type": "function",
    "function": {
        "name": "get_table_schema",
        "description": "Return the column names of one foundry table.",
        "parameters": {
            "type": "object",
            "properties": {
                "table_name": {"type": "string",
                               "description": "The exact table name to describe"},
            },
            "required": ["table_name"],
        },
    },
}
```

**Example.**

```python
schema = build_tools_schema()
print(len(schema))                                      # 3
print(schema[1]["function"]["name"])                     # get_table_schema
print(schema[1]["function"]["parameters"]["required"])    # ['table_name']
print(schema[0]["function"]["parameters"]["properties"])  # {}
```

### Task 3: `list_tables()`, `get_table_schema(table_name)`, `execute_sql(query)`

**Goal.** Three tools that read the real database, one of which refuses to change it.

**Steps.**

1. `list_tables()` opens the database with `connect()`, reads the table names out of it, and
   returns them as a list of strings. Leave out SQLite's own bookkeeping tables, the ones whose
   names begin `sqlite_`.
2. `get_table_schema(table_name)` returns the column names of that table as a list of strings, in
   the order the table declares them. For a name that is not a table in this database, return an
   empty list.
3. `execute_sql(query)` runs a read-only query and returns its rows as a string: the column names
   and the row values, laid out however you like. A query that matches no rows still returns a
   string.
4. Before running anything, `execute_sql` decides whether the statement only reads, and refuses it
   if not. A refusal returns a string beginning `REFUSED:` followed by a short reason, and the
   statement is not executed. The persona forbids data-modifying SQL, and the tool is where that
   has to be enforced, because the model can always ask.
5. If SQLite rejects a query, catch the error and return its text as the result. An exception out
   of a tool ends the loop, so return the error text instead and let the model correct its query.
6. Close every connection you open.

**Requirements.**

- `list_tables()` returns a `list` of `str`. `get_table_schema()` returns a `list` of `str`, empty
  for a table that does not exist. `execute_sql()` returns a `str` in every case, including an
  empty result, a refusal and a SQLite error.
- **The refusal rule, exactly.** Strip surrounding whitespace and a trailing semicolon, then
  `execute_sql` runs the statement only if both of these hold:
  1. its first keyword, compared without regard to case, is `SELECT` or `WITH`; and
  2. it does not contain any of the words `insert`, `update`, `delete`, `drop` or `alter`.

  Anything failing either test returns a `REFUSED:` string and is not executed. Both tests are
  needed. The first turns away `PRAGMA`, `ATTACH`, `VACUUM`, `CREATE` and every other statement
  that is not a query, since none of them can begin a query. The second catches the one shape that
  passes the first and still writes: SQLite accepts a single statement that begins with `WITH` and
  ends in an `INSERT`.
- **A consequence of test 1, and it matters.** `execute_sql` refuses a `PRAGMA` statement. If you
  read column names with `PRAGMA table_info(...)`, run it inside `get_table_schema` on its own
  connection from `connect()`. Do not route it through `execute_sql`, which is the tool the model
  drives and which will refuse it.
- The wording after `REFUSED:` is yours. Only the prefix is fixed.
- No table names, no column lists and no query results may be written into your file. All three
  tools read what they return out of the database at the moment they are called. The values in the
  string `execute_sql` returns are what an answer is checked against, so return what the query
  produced.
Interpolating a table name into a `PRAGMA` is the normal way to write it, since SQLite does not
accept a bound parameter there. Checking the name against the real table list before you interpolate
it is what keeps an arbitrary string out of the statement.

**How SQLite spells the two catalogue lookups.** SQLite has no `SHOW TABLES` and no
`SHOW COLUMNS`. It exposes its catalogue through two ordinary statements you run with
`conn.execute(...)` like any other query. Both are given here because remembering the spelling is
not what this task is about.

- **Table names:** `SELECT name FROM sqlite_master WHERE type = 'table'` returns one row per table
  with the name in the first column. The result includes SQLite's own tables, whose names begin
  `sqlite_`, and step 1 asks you to leave those out.
- **Column names:** `PRAGMA table_info(<table>)` returns one row per column of that table, in
  declaration order, with the column name in the **second** field of each row. A second way to the
  same answer is to run `SELECT * FROM <table> LIMIT 0` and read `cursor.description`, which needs
  no `PRAGMA` at all.

**Example.**

```python
list_tables()
# ['alloys', 'moulds', 'pours']

get_table_schema('alloys')
# ['alloy_id', 'alloy_code', 'base_metal', 'melt_point_c', 'tensile_mpa']

get_table_schema('sand_deliveries')
# []

print(execute_sql("SELECT alloy_code, melt_point_c FROM alloys "
                  "WHERE base_metal = 'aluminium' ORDER BY alloy_code"))
# alloy_code | melt_point_c
# KB-402 | 660
# KB-409 | 672

execute_sql("DROP TABLE pours")
# 'REFUSED: only read-only SELECT queries may be run against the foundry database.'

execute_sql("PRAGMA table_info(alloys)")
# 'REFUSED: only read-only SELECT queries may be run against the foundry database.'

print(execute_sql("SELECT alloy_code FROM alloys WHERE base_metal = 'tungsten'"))
# (no rows)
```

### Task 4: `run_agent(question)`

**Goal.** Drive one question through the reason, act, observe loop and return the model's answer.

**Steps.**

1. Build the message list: the string from Task 1 as a message with `"role": "system"`, then the
   question as a message with `"role": "user"`.
2. Call `client.chat.completions.create(...)` with `model=MODEL_NAME`, your messages, `tools=` set
   to the list from Task 2, and `tool_choice="auto"` so the model decides for itself whether to act
   or to answer.
3. Take `response.choices[0].message` and append it to the message list before doing anything else.
   The next request has to show the model what it already asked for.
4. If that message carries no tool calls, the model has answered. Return its `content` and stop.
5. Otherwise, for each entry in `message.tool_calls`: read `call.function.name`, parse
   `call.function.arguments` with `json.loads` (it arrives as a JSON **string**, not a dictionary),
   look the name up in a dictionary that maps tool names to your Python functions, and call the
   function with those arguments.
6. Append each result as its own message with `"role": "tool"`, a `"content"` string, and the
   `"tool_call_id"` set to the `id` of the call it answers. That identifier is how the model knows
   which request a result belongs to. Sending the tool name there, or an identifier of your own
   making, breaks the link and the model cannot see its own results.
7. Go back to step 2 and repeat, up to `MAX_MODEL_TURNS` model turns.
8. Return the final answer text.

**Requirements.**

- The return value is a `str`.
- **What one model turn counts.** One model turn is one call to
  `client.chat.completions.create(...)` and the response it returns. Running a tool is not a turn.
  Appending a message is not a turn. So a question the model answers straight away costs one turn;
  a question where it asks for `list_tables`, then `get_table_schema`, then `execute_sql`, then
  answers costs four.
- **`MAX_MODEL_TURNS` is the largest number of those calls `run_agent` may make for one question.**
  It is 8. The count is per question, and `run_session` starts it again for each question in the
  list.
- **The boundary.** After the response to the eighth call, `run_agent` makes no ninth call. If that
  eighth response still carries tool calls, stop and return a short string of your own saying the
  ceiling was reached without an answer. Both `for _ in range(MAX_MODEL_TURNS):` and
  `while turns < MAX_MODEL_TURNS:` with `turns` incremented before each call give this behaviour.
  What must not happen is a loop that keeps calling the endpoint with no upper bound.
- The wording of that give-up string is yours and is not compared against anything.
- The model never runs a tool. It asks, your code runs the function, your code reports the result
  back. A tool result the model never sees is a question that never gets answered.
- How many round trips a question needs is the model's decision, not an assumption you can build
  in. One question may need three tools, another none. Do not call the tools yourself before the
  model asks, and do not stop after a fixed number of tool calls.
- Dispatch on the tool name each call carries. Do not assume the order the tools are asked for,
  or how many times each one is asked for: one question can ask for `execute_sql` twice.
- `run_agent` builds its own message list, starting from the system prompt. A dictionary mapping
  tool names to functions is the usual way to write step 5, but any dispatch that reads the name
  off the call works.

**Example.**

```python
print(run_agent("What is the highest tensile strength among the bronze alloys?"))
```

```
SQL:
SELECT MAX(tensile_mpa) AS max_tensile_mpa FROM alloys WHERE base_metal = 'bronze'

RESULT:
max_tensile_mpa
372

SUMMARY:
The result above comes from the alloys table and answers the question as asked.
```

That answer took four model turns: the model asked for `list_tables`, then for
`get_table_schema('alloys')`, then for the `SELECT`, and answered on the fourth.

### Task 5: `run_session(questions)`

**Goal.** Answer several questions in one conversation, so later questions can use what earlier
ones found out.

**Steps.**

1. Build the client, the tool schemas and **one** message list opening with the system prompt.
2. Take the questions in order. Append each one to that same message list as a `"role": "user"`
   message, and run the same loop as Task 4 over it.
3. Do not clear the list between questions. The earlier assistant messages and tool results stay in
   it, so the model can see the table names and the schema it already read and go straight to the
   query for a follow-up about the same table.
4. Collect the final answer for each question and return them as a list, in the order the questions
   were asked.

**Requirements.**

- The return value is a `list` of `str`, one entry per question, in the same order as the input.
- An empty list of questions returns an empty list.
- The message list is shared across the questions in a single `run_session` call. Every message
  from question one is still in the list when question two is sent. Starting a fresh conversation
  per question, or replaying only the previous question texts into a new list, gives the model
  nothing to build on.
- `MAX_MODEL_TURNS` applies to each question separately, as in Task 4.
- One client and one tool schema list for the whole session is fine. Rebuilding either per question
  is also fine. Only the message list has to be shared.

**Example.**

```python
answers = run_session(["How many pours were logged on the swing shift?",
                       "What was the total scrap weight on the swing shift?"])
print(len(answers))     # 2
print(answers[0])
print(answers[1])
```

```
SQL:
SELECT COUNT(*) AS pour_count FROM pours WHERE shift = 'swing'

RESULT:
pour_count
5

SUMMARY:
The result above comes from the pours table and answers the question as asked.
```

```
SQL:
SELECT SUM(scrap_kg) AS total_scrap_kg FROM pours WHERE shift = 'swing'

RESULT:
total_scrap_kg
69

SUMMARY:
The result above comes from the pours table and answers the question as asked.
```

The first question cost four model turns and the second cost two: the tables and the `pours` schema
were already in the conversation, so the model went straight to the query.

## Run and verify locally

Start with the provided script. It calls each of your functions and prints what came back.

```bash
cd /home/user/kilnbrook-foundry
python3 check_local.py
```

Its Task 3 section, for a finished `solution.py`, looks like this:

```
========================================================================
Task 3 - the three tools, called directly
The first three read the database. The fourth must come back as a
string beginning REFUSED: without running.
------------------------------------------------------------------------
list_tables()
  -> ['alloys', 'moulds', 'pours']
------------------------------------------------------------------------
get_table_schema('alloys')
  -> ['alloy_id', 'alloy_code', 'base_metal', 'melt_point_c', 'tensile_mpa']
------------------------------------------------------------------------
get_table_schema('sand_deliveries')  # no such table
  -> []
------------------------------------------------------------------------
execute_sql('SELECT alloy_code, base_metal FROM alloys LIMIT 3')
  -> alloy_code | base_metal
  -> KB-101 | bronze
  -> KB-104 | bronze
  -> KB-112 | bronze
------------------------------------------------------------------------
execute_sql('DROP TABLE pours')
  -> REFUSED: only read-only SELECT queries may be run against the foundry database.
------------------------------------------------------------------------
execute_sql('PRAGMA table_info(alloys)')  # not a query either
  -> REFUSED: only read-only SELECT queries may be run against the foundry database.
```

It goes on to run each of `run_agent` and `run_session`, with a line above each one saying what to
look for in the answer.

A stub that has not been filled in prints `-> not implemented yet (...)` for that function, and a
function that raises prints its traceback under `-> raised:`.

You can also drive individual pieces yourself:

```bash
cd /home/user/kilnbrook-foundry
python3 -c "
import solution
print(solution.run_agent('Which sand types are used by the moulds?'))
print(solution.execute_sql('SELECT DISTINCT base_metal FROM alloys ORDER BY base_metal'))
print(solution.execute_sql('UPDATE alloys SET tensile_mpa = 0'))
"
```

The last line should print a string beginning `REFUSED:`, and

```bash
cd /home/user/kilnbrook-foundry
python3 -c "
import sqlite3
from kiln_kit import DB_PATH
print(sqlite3.connect(DB_PATH).execute('SELECT COUNT(*) FROM alloys').fetchone())
"
```

should print the same count before and after you run your agent.

If the endpoint is not answering, check it and read its log:

```bash
curl -s http://127.0.0.1:8781/health
sudo systemctl status kilnbrook-foundryd
```

## Before you submit

- The file assessed is `/home/user/kilnbrook-foundry/solution.py`. Nothing else you write is read.
- Run `cd /home/user/kilnbrook-foundry && python3 check_local.py` first, and read all of its
  output. An `ImportError` or a `NotImplementedError` there is the same failure that will happen
  when your work is assessed.
- Confirm your seven callables have the names in the interface contract, spelled exactly. The
  parameter names `table_name` and `query` are the keys the model sends, so keep them if you pass
  the parsed arguments straight into the function.
- Your work is run against its own questions, tables and queries, not the ones printed above. The
  examples in this document are illustrations. A solution that handles only them will not pass, so
  make sure your tools work for any question about any of the three tables.
