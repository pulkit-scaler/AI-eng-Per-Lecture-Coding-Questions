# Solution Walk-through: Kilnbrook Foundry

This document explains the model answer in `reference-solution/solution.py`. It goes task by task:
the code, why it is shaped that way, and what goes wrong when it is shaped differently.

## Task 1: the persona is the system prompt

```python
def build_system_prompt(persona):
    rules = "\n".join("  - %s" % rule for rule in persona["rules"])
    return (
        "You are a %s.\n\n"
        "INSTRUCTIONS:\n%s\n"
        "RULES:\n%s\n\n"
        "OUTPUT FORMAT:\n%s"
        % (persona["role"], persona["instructions"], rules, persona["output_format"])
    )
```

The whole task is not losing anything. The `rules` list is the part people drop. It is the only list
in the dictionary, so it needs a join, and a join is where a rule goes missing.

The persona's text has to survive intact. Headings, bullet characters, ordering and indentation are
free choices, as long as every piece of the dictionary reaches the string.

What each piece does at run time is the reason to keep it. The numbered workflow inside
`instructions` is what makes the model list tables before writing SQL. The `NEVER run DELETE...`
line in `rules` is the boundary Task 3 then enforces in code. A prompt that keeps only the role
produces an agent with no method and no limits.

The layout is free, and several shapes work. One puts the output format before the instructions and
bullets the rules with asterisks. Another uses markdown headings and numbers the rules. A third
underlines a title with equals signs. Each one renders the same content.

## Task 2: the schema is the model's only view of your code

```python
{
    "type": "function",
    "function": {
        "name": "get_table_schema",
        "description": "Return the column names of one table. Call this after choosing the "
                       "table a question needs.",
        "parameters": {
            "type": "object",
            "properties": {"table_name": {"type": "string",
                                          "description": "The exact name of the table to inspect"}},
            "required": ["table_name"],
        },
    },
}
```

Three things have to be right, and each has a failure mode the learner can see:

- **the name**, because the reply comes back as a string that has to find a Python function;
- **`required`**, because a model that is not told a parameter is mandatory can omit it, and
  `get_table_schema()` with no argument is a `TypeError` inside the loop;
- **the description**, because it is the entire basis on which the model chooses between three tools.

The endpoint will not act on a tool it cannot make sense of. Drop `required`, or leave a description
empty, and the question comes back `UNABLE: this request needs the get_table_schema tool, and it was
not offered in a usable form.` A schema mistake therefore surfaces as an agent that will not work,
which is how it surfaces in production.

`list_tables` needs no `required` list at all. Omitting the key altogether is equivalent for a tool
with no parameters, because "no required parameters" and "an empty required list" are the same
statement.

## Task 3: the tools do the work, and the guard lives here

```python
def list_tables():
    conn = connect()
    try:
        rows = conn.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name NOT LIKE 'sqlite_%' ORDER BY name").fetchall()
    finally:
        conn.close()
    return [row[0] for row in rows]
```

`sqlite_master` is the SQLite equivalent of `SHOW TABLES`, and filtering `sqlite_%` keeps SQLite's own
bookkeeping tables out of the answer. `PRAGMA table_info(<table>)` is the equivalent of
`SHOW COLUMNS`, and its second column is the column name. Both are ordinary DB-API work. There is no
framework anywhere in this lab.

The interesting function is `execute_sql`:

```python
def execute_sql(query):
    if not _is_read_only(query):
        return ("REFUSED: only read-only SELECT queries may be run against the "
                "foundry database, so this statement was not executed.")
    ...
```

**The persona forbids data-modifying SQL, and the tool is the only place that can enforce it.** A
prompt rule is a request, and a model can ask for something else, so the guard has to be code.

`_is_read_only` applies exactly the two tests the problem statement publishes, and both are needed.

1. The first keyword, case-insensitively, is `select` or `with`. This is what turns away `PRAGMA`,
   `ATTACH`, `VACUUM`, `CREATE` and every other statement that cannot begin a query. Measured: with
   this test removed, `execute_sql("PRAGMA journal_mode=WAL")` runs and **changes the database
   file**. The five-verb scan alone does not stop it.
2. The statement names none of `insert`, `update`, `delete`, `drop`, `alter`. This is what catches
   the one shape that passes test 1 and still writes: SQLite accepts
   `WITH x AS (SELECT 1) INSERT INTO pours SELECT ...` as a single statement beginning with `WITH`.
   Measured: with the verb scan removed, that statement executes.

Because test 1 refuses a `PRAGMA`, `get_table_schema` runs its own `PRAGMA table_info` on a
connection from `connect()` rather than routing it through `execute_sql`. Route it through
`execute_sql` and the refusal string comes back where the rows were expected, so `get_table_schema`
returns an empty column list for every table. That is why the problem statement says so outright.

A guard written as a keyword blacklist alone shows its bug quickly. One that lists only `delete`,
`drop` and `truncate`, with no leading-keyword test, refuses a `DELETE` and then runs an `UPDATE`
that nobody thought to list. That is the failure a blacklist has in real life.

Note also what `execute_sql` does with a **database** error: it returns the error text rather than
raising. A tool that raises kills the loop. A tool that reports lets the agent read the message and
try a corrected query, which is what the persona's last rule tells it to do.

## Task 4: the loop

```python
for _ in range(MAX_MODEL_TURNS):
    response = client.chat.completions.create(
        model=MODEL_NAME, temperature=0.0, messages=messages,
        tools=tools, tool_choice="auto")
    message = response.choices[0].message
    messages.append(message.model_dump(exclude_none=True))

    calls = message.tool_calls or []
    if not calls:
        return message.content or ""

    for call in calls:
        args = json.loads(call.function.arguments or "{}")
        result = TOOL_FUNCTIONS[call.function.name](**args)
        messages.append({"role": "tool", "tool_call_id": call.id, "content": result})
```

Five details, in the order they bite:

1. **Append the assistant message before executing anything.** The next request has to contain the
   request the results answer, or the conversation makes no sense. `model_dump(exclude_none=True)`
   is one way. `to_dict()` does the same job, and so does rebuilding the dict field by field.
2. **`arguments` is a JSON string, not a dict.** It arrives as `'{"table_name": "pours"}'`, so it
   needs `json.loads` before `**`.
3. **The exit condition is "no tool calls", not a step count.** The model decides how many round
   trips a question needs. A loop that assumes three breaks on a question that needs one.
4. **`tool_call_id` must be `call.id`.** It is what links a result to the request it answers. Feed
   the results back under an invented id such as `call_for_<toolname>` and every value can still be
   correct while nothing ties an observation to the call that produced it, so the conversation only
   works by accident.
5. **`range(MAX_MODEL_TURNS)` rather than `while True`.** An unbounded loop is the most common
   beginner mistake here, and unbounded means a stalled process rather than a failed run. The
   endpoint refuses a conversation past 30 turns with a `400`, so even a runaway loop ends in a
   readable error in under a second instead of hanging. The ceiling is still the learner's job, and
   the contract names it.

`temperature=0.0` is a persona-level decision rather than a detail. SQL generation wants the same
query for the same question.

## Task 5: one message list is the memory

```python
def run_session(questions):
    client = make_client()
    messages = _fresh_messages()
    tools = build_tools_schema()
    return [_run_turns(client, messages, tools, question) for question in questions]
```

The only difference from `run_agent` is that `messages` is built **once** and every question is
appended to it. That is the whole of short-term memory. There is no store and no framework; the list
is not thrown away between questions.

What it buys is visible in the tool count. The first question about `pours` costs three tool calls:
list the tables, read the schema, run the query. The second question about the same table costs
**one**, because the table names and the schema are still in the conversation and the model can go
straight to SQL. Implement `run_session` as `[run_agent(q) for q in questions]` and every answer is
still correct, but the discovery is paid for again on each question and nothing carries forward from
the first.

The same mechanism works as an object. A `FoundryAgent` instance can own the message list, so
`run_agent` builds one instance and `run_session` reuses one. Different shape, same shared history.

## The mistakes worth expecting

- Rendering the persona but dropping `rules` because it is a list.
- Omitting `required` from `get_table_schema`, then wondering why the agent stops working.
- Passing `call.function.arguments` straight into `**` without `json.loads`.
- Using the tool name as `tool_call_id` because it reads better.
- `while True` with no ceiling.
- Implementing `run_session` as a loop over `run_agent`.
- Trusting the persona to stop a write instead of guarding the tool.
- Reaching for pandas to render rows. There is no pandas on the VM, and an import at module scope
  fails the whole module, so no function in the file can be called.
