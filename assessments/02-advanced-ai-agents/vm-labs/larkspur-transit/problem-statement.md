# The Model Context Depot

## Scenario

Larkspur Transit runs the buses, trams, metro and ferries of a mid-sized city. Its operations
database records every route, every vehicle in the fleet and every trip that ran. The operations
desk wants to ask questions about that data in plain English instead of writing SQL by hand.

The transit authority will not let an assistant reach the database directly. Every read has to go
through a server the authority controls, over the Model Context Protocol. That way the set of
operations on offer is fixed in one place, and every access is recorded.

The database and the three functions that query it are already written. You build the protocol
layer on both sides. That means the MCP server that publishes those functions, and the MCP client
that connects to it and drives a question through to an answer.

## What you will build

- `server.py`: an MCP server that publishes three tools, one resource and one prompt, and speaks
  the stdio transport when it is run as a script.
- `solution.py`: an MCP client class that owns one server process and one session, a function that
  converts MCP tool schemas into the shape the model expects, and an agent loop that answers one
  question using them.

## Environment

- **Python:** Python 3 is already installed. You install nothing.
- **Installed and importable:** `mcp` version **1.9.4** (the official MCP Python SDK) and `openai`
  version **3.1.0**, plus their own dependencies, which include `pydantic` v2.
- **The `mcp` API surface:** this is release 1.9.4, so the server helpers live in
  `mcp.server.fastmcp` and message helpers in `mcp.server.fastmcp.prompts.base`. Version 2.0 of
  `mcp` removed that module and moved its contents. Code written against the 2.x layout will fail
  at import here. Use the 1.9.4 imports shown in the task sections below.
- **Project directory:** `/home/user/larkspur-transit/`. Run every command from there, so that
  `import transit_kit`, `import solution` and starting `server.py` all resolve.
- **The operations endpoint** is already running on `http://127.0.0.1:8757`. Leave it running.
  Check it with:

  ```bash
  curl -s http://127.0.0.1:8757/health
  ```

  It answers `{"status": "ok", ...}`.
- **Time budget:** every run of your code is given well under two minutes. Keep the agent loop
  bounded, because a loop that does not terminate is recorded as a failure rather than waiting.

## Project layout

Two files are yours to write, and they are two different programs. Read this block before you open
anything.

```
/home/user/larkspur-transit/
├── server.py            YOU WRITE THIS. The MCP server: three tools, one resource,
│                        one prompt, stdio entry point. It is a program that is
│                        started as a subprocess and talks JSON-RPC on its standard
│                        input and output. It never imports solution.py.
├── solution.py          YOU WRITE THIS. The MCP client and the agent loop:
│                        TransitMCPClient, mcp_tools_to_openai, run_agent_loop.
│                        It launches server.py as a subprocess and talks to it.
│                        It never imports server.py.
├── transit_kit/
│   ├── __init__.py      provided, do not modify
│   ├── db.py            provided, do not modify. DB_PATH and connect().
│   ├── sql_tools.py     provided, do not modify. The three query functions.
│   ├── client_factory.py provided, do not modify. make_client() and MODEL_NAME.
│   ├── endpoint.py      provided, do not modify. Resolves the endpoint URL.
│   └── audit.py         provided, do not modify. The database access record.
├── data/
│   └── transit.db       provided, do not modify. The operations database.
└── check_local.py       provided, read only. Prints what your two files produce.
```

How your two files relate to each other, stated explicitly:

- `server.py` is the **server**. It imports `transit_kit` and publishes what the kit can do over
  MCP. It is never imported by anything. It is executed, as `python3 server.py`, and it must work
  when started that way with no arguments and no terminal attached.
- `solution.py` is the **client**. It imports `transit_kit` for the model client only, never for
  the database. It starts `server.py` as a subprocess and reaches the database only by asking the
  server.
- Both files are assessed. `server.py` is assessed by connecting an MCP client to it over stdio and
  using the protocol. `solution.py` is assessed by importing it and calling its functions.
- Do not have one import the other. `server.py` starts as a subprocess, so importing the client
  from it would start a second server from inside the first. Anything you want to share belongs in
  a third file of your own.

## The pieces you are given

### `transit_kit.sql_tools`: the three query functions

These are plain Python functions. No protocol, no decorators. They already validate their inputs.

- `list_tables() -> List[str]`
  Every table name in the operations database, sorted.

- `get_table_schema(table_name: str) -> List[Dict[str, Any]]`
  One dict per column of that table, with the keys `name`, `type`, `nullable` and `primary_key`.
  Raises `ValueError` when `table_name` is not a valid SQL identifier, and when it is not on the
  published allowlist `transit_kit.sql_tools.ALLOWED_TABLES`. A table that exists in the database
  file but is not on that allowlist is refused just the same.

- `execute_sql(query: str) -> str`
  Runs one read-only query and returns the rows as a formatted text table: a header line, a rule of
  dashes, then one line per row. Raises `ValueError` on any data-modifying keyword, before the
  database is touched. A query that is read-only but wrong comes back as a string starting
  `SQL Error: `, so the caller can read the message and try a different query.

- `ALLOWED_TABLES`
  The tuple of table names `get_table_schema` will describe.

Real usage:

```python
>>> from transit_kit import list_tables, get_table_schema, execute_sql
>>> list_tables()
['routes', 'trips', 'vehicles']
>>> get_table_schema("routes")[0]
{'name': 'route_id', 'type': 'INTEGER', 'nullable': True, 'primary_key': True}
>>> print(execute_sql("SELECT mode, COUNT(*) AS n FROM routes GROUP BY mode"))
mode | n
---------+---------
bus | 5
ferry | 1
metro | 2
tram | 3
trolley | 1
>>> get_table_schema("drivers")
Traceback (most recent call last):
ValueError: Table 'drivers' is not available here. Available tables: routes, trips, vehicles
```

### `transit_kit.db`: opening the database

- `connect() -> sqlite3.Connection`
  A fresh connection to the operations database. Raises `FileNotFoundError`, naming the path, when
  the database is not where it is expected.
- `DB_PATH`
  The path `connect()` will open.

The path is not a constant you can copy. `db.py` reads the `LARKSPUR_DB` environment variable when
it is set and falls back to the bundled copy otherwise, so the same code works wherever the database
is mounted. Always reach the database through `connect()` or through the three query functions, and
never by writing a path of your own.

```python
>>> from transit_kit import connect
>>> conn = connect()
>>> conn.execute("SELECT COUNT(*) FROM routes").fetchone()[0]
12
>>> conn.close()
```

### `transit_kit.client_factory`: the model client

- `make_client() -> openai.OpenAI`
  An `openai.OpenAI` client already pointed at the local endpoint, with a request timeout and a
  retry count set for you.
- `MODEL_NAME`
  The string to pass as the `model` argument.

It takes `messages`, `tools` and `tool_choice` exactly as the OpenAI chat-completions API does, and
`response.choices[0].message` carries either `content` or `tool_calls`.

```python
>>> from transit_kit import make_client, MODEL_NAME
>>> reply = make_client().chat.completions.create(
...     model=MODEL_NAME,
...     messages=[{"role": "user", "content": "How many bus routes are there?"}],
...     tools=converted_tools,
...     tool_choice="auto",
... ).choices[0].message
>>> reply.tool_calls[0].function.name
'list_tables'
>>> reply.tool_calls[0].function.arguments      # a JSON string, not a dict
'{}'
```

### `check_local.py`

Runs your server through your client, exercises every primitive, and runs the agent loop on two
sample questions, printing what each step returned. It does not score you.

## The data

The operations database is SQLite. It holds three tables that are on the allowlist:

- `routes`: one row per route.
- `vehicles`: one row per vehicle in the fleet.
- `trips`: one row per trip that ran, referring to a route and a vehicle.

**Column names are not published here, and you must not hardcode them.** Your code is run against a
freshly built operations database, not the copy sitting in `data/transit.db`. The table set is the
same. Everything else can differ: the number of rows, the values, an extra column on a table, and a
table in the file that is not on the allowlist.

So the column names have to be discovered at run time, from the database in front of your code. That
is what `list_tables` and `get_table_schema` are for, and why the agent loop calls them before it
writes a query.

You can look at the bundled copy freely while developing:

```bash
cd /home/user/larkspur-transit
python3 -c "from transit_kit import list_tables, get_table_schema; \
print(list_tables()); print(get_table_schema('routes'))"
```

Treat what you see there as one example of the shape, not as a fact about the data.

## Interface contract

These are fixed. Everything else is your choice.

**Paths**

- Project directory: `/home/user/larkspur-transit/`
- The MCP server: `server.py`, in that directory
- The client and agent loop: `solution.py`, in that directory
- The operations endpoint: `http://127.0.0.1:8757`

**What `server.py` must publish**

- A tool named exactly `list_tables`, with no required parameters.
- A tool named exactly `get_table_schema`, with exactly one required parameter named `table_name`.
- A tool named exactly `execute_sql`, with exactly one required parameter named `query`.
- Each of those three with a non-empty description, and an input schema whose `type` is `"object"`.
- A resource at the URI `transit://overview`.
- A prompt named exactly `transit_analyst`, taking an argument named `question`.
- Extra tools, resources and prompts are ignored, so add as many as you like.

**What `server.py` must run**

- An MCP server over the **stdio** transport, started when the file is executed as a script.

**What `solution.py` must define**

- `class TransitMCPClient`, usable as `async with TransitMCPClient() as client:`, with the async
  methods `connect()`, `cleanup()`, `list_tools()`, `call_tool(name, arguments)`,
  `read_resource(uri)`, `list_prompts()` and `get_prompt(name, arguments)`. Constructed with no
  arguments it launches `server.py` from the project directory using the running interpreter.
- `mcp_tools_to_openai(mcp_tools) -> List[Dict[str, Any]]`, a plain synchronous function.
- `async def run_agent_loop(question: str) -> str`, returning the final answer as a string.
- `MAX_MODEL_TURNS`, a whole number between 1 and 8 inclusive.

**How the answer is compared**

- The string `run_agent_loop` returns is compared after stripping leading and trailing whitespace,
  and must match exactly otherwise. Return the endpoint's final message content as it arrives. Do
  not reformat it, prefix it, append to it, or wrap it in anything.

## Your tasks

### Task 1: `server.py`: publish the three query functions as MCP tools

**Goal:** turn the three plain functions in `transit_kit.sql_tools` into three MCP tools on one
server.

**Steps**

1. Create a server instance:

   ```python
   from mcp.server.fastmcp import FastMCP

   mcp = FastMCP("Larkspur-Transit-Ops")
   ```

2. Register a tool named `list_tables` that returns the table names by calling the provided
   `list_tables()`. It takes no parameters.
3. Register a tool named `get_table_schema` that takes one required string parameter `table_name`
   and returns the column list by calling the provided `get_table_schema()`.
4. Register a tool named `execute_sql` that takes one required string parameter `query` and returns
   the formatted rows by calling the provided `execute_sql()`.
5. Give each tool a description saying when a model should reach for it.
6. End the file with a stdio entry point:

   ```python
   if __name__ == "__main__":
       mcp.run(transport="stdio")
   ```

**Requirements**

- Return type: whatever the provided function returns. Do not reshape it.
- The three names are exact: `list_tables`, `get_table_schema`, `execute_sql`.
- The SDK generates each input schema from the function signature, so the signature is what a
  client sees. `table_name` and `query` must come out as **required**, which means giving them a
  type annotation and no default value that makes them optional. A parameter typed
  `Optional[str] = None` is reported as not required and does not satisfy this.
- Each description must be non-empty. Two words satisfies that. Write a sentence anyway, since the
  description is what the model reads when it picks a tool.
- **A refusal from the provided guards must reach the caller as an error inside the tool result.**
  When `get_table_schema` or `execute_sql` raises `ValueError`, do not catch it and return a normal
  value, and do not let it end the process. The next call on the same session must still be
  answered. Letting the exception propagate out of your tool function is enough: the SDK turns it
  into an error result and keeps the session open.
- Registration style is free. Decorators, `mcp.add_tool(...)`, or a loop over a registry of your own
  all work, as long as the names, the descriptions and the required parameters are what the protocol
  reports.
- Nothing may read the database except through `transit_kit`.

**Example.** What a client sees after `initialize` and `tools/list`:

```
list_tables        required=[]
get_table_schema   required=['table_name']
execute_sql        required=['query']
```

and what `tools/call` produces:

```
call_tool("list_tables", {})
  -> ['routes', 'trips', 'vehicles']

call_tool("execute_sql", {"query": "SELECT mode, COUNT(*) AS n FROM routes GROUP BY mode"})
  -> mode | n
     ---------+---------
     bus | 5
     ferry | 1
     metro | 2
     tram | 3
     trolley | 1

call_tool("get_table_schema", {"table_name": "drivers"})
  -> isError=True  "Error executing tool get_table_schema: Table 'drivers' is not
                    available here. Available tables: routes, trips, vehicles"
```

### Task 2: `server.py`: publish the database overview as a resource

**Goal:** publish a read-only overview of the database at a fixed URI, which an application fetches
when it wants it without the model being involved.

**Steps**

1. Register a resource on the same server at the URI `transit://overview`.
2. When it is read, ask the database which tables it currently holds and how many rows each one has.
3. Return text with one line per table, each line carrying that table's name and its current row
   count.
4. Declare a MIME type on the resource.

**Requirements**

- Return type: a string (or bytes) that the protocol can carry as resource contents.
- The URI is exact: `transit://overview`.
- **The counts must be queried when the resource is read**, from the database `transit_kit` opens.
  A list of counts written into the file as constants is wrong, because the database your code is
  run against is not the bundled one.
- The table set must be the one the database currently holds. Get it from `list_tables()` rather
  than from a list you typed out, so a database with a fourth table is still described correctly.
- Line layout is yours. `routes: 12 rows`, `routes -> 12` and `"routes": 12` all read fine. What is
  fixed is that a table's name and that table's number sit on the **same line**, and that the number
  is the real one.
- The number must not be adjacent to other digits. Write `routes: 12 rows`, not `routes:12rows`.
- Nothing else on the line matters, and extra lines before or after are fine.

**Example.** Reading `transit://overview` on a database holding twelve routes, twenty-four trips and
sixteen vehicles:

```
Larkspur Transit operations database
routes: 12 rows
trips: 24 rows
vehicles: 16 rows
```

### Task 3: `server.py`: publish the analyst prompt

**Goal:** publish a named, parameterised template that returns a message sequence, written once on
the server so every client gets the same one.

**Steps**

1. Register a prompt named `transit_analyst` on the same server, with a description.
2. Give it one argument, `question`.
3. Return a message sequence: one or more messages with roles, the way a conversation is handed to a
   model.
4. Interpolate the `question` it was given into the text of those messages, alongside whatever
   standing instructions you want the analyst to follow.

**Requirements**

- Return type: a list of message objects. With `mcp` 1.9.4 the helpers are in
  `mcp.server.fastmcp.prompts.base`, so `[base.UserMessage(text)]` is a valid return value. A list
  of one message is enough.
- The prompt name is exact: `transit_analyst`.
- The argument must be advertised under the name `question`. With a decorated function that means
  naming the parameter `question`.
- **The value passed at `prompts/get` time must appear in the message text that comes back.**
  Interpolate the argument. A fixed instruction block that ignores it does not satisfy this.
- Wording, the number of messages and the roles you use are yours.

**Example.** `get_prompt("transit_analyst", {"question": "Which depot has the most vehicles?"})`:

```
user: You are the Larkspur Transit operations analyst.

      Work like this:
        1. Call list_tables to see what exists.
        2. Call get_table_schema on the tables you need.
        3. Write one SQLite SELECT query.
        4. Run it with execute_sql and report the answer.

      QUESTION: Which depot has the most vehicles?
```

### Task 4: `solution.py`: `class TransitMCPClient`

**Goal:** an async client that owns one server subprocess and one MCP session, and relays protocol
calls to it.

**Steps**

1. `__init__(self, command=None, args=None, env=None)` records how to launch the server. With no
   arguments it must launch `server.py` from the project directory with the running interpreter, so
   `sys.executable` and `["server.py"]` are the defaults to fall back to.
2. `async connect()` builds the stdio server parameters, spawns the server, opens a client session
   on the resulting read and write streams, and completes the MCP initialisation handshake:

   ```python
   from mcp import ClientSession, StdioServerParameters
   from mcp.client.stdio import stdio_client
   ```

3. `async cleanup()` closes the session and the server subprocess. Nothing may be left running once
   it returns.
4. `__aenter__` and `__aexit__` make the class usable as `async with TransitMCPClient() as client:`.
   Have `__aexit__` clean up even when the body raises, so a failed run does not leave a server
   process behind.
5. `async list_tools()` returns the list of tool objects the server advertises, each carrying at
   least `name`, `description` and `inputSchema`.
6. `async call_tool(name, arguments)` relays one tool invocation to the server and returns the
   result the server sent back.
7. `async read_resource(uri)` reads one resource and returns its content.
8. `async list_prompts()` returns the advertised prompts, and `async get_prompt(name, arguments)`
   returns the message sequence for one of them.

**Requirements**

- Return types: `list_tools()` and `list_prompts()` return lists, not the response wrapper the SDK
  hands back, so unwrap `.tools` and `.prompts`. `get_prompt` returns the message sequence, so
  unwrap `.messages`. `call_tool` returns the tool result as the server sent it.
- Every method must reach the server. **The client must not interpret tool results and must not
  read the database.** It is protocol plumbing.
- `read_resource` takes the URI as a `str`. The SDK wants a `pydantic.AnyUrl`, so convert it inside
  the method: `AnyUrl(uri)`.
- The nesting matters. `stdio_client(...)` and `ClientSession(...)` are both async context managers,
  and the session is only usable while the transport is open. Manage them with an
  `AsyncExitStack`, by hand, or with a helper. All three work.
- Calling a method before `connect()` should raise rather than return something empty.
- Each instance owns its own subprocess, so two clients built in one process do not share state.
  Nothing here builds two at once, but keeping the state per-instance rather than in module globals
  is what makes that true.

**Example**

```python
async with TransitMCPClient() as client:
    print([t.name for t in await client.list_tools()])
    # ['list_tables', 'get_table_schema', 'execute_sql']
    print(await client.read_resource("transit://overview"))
    # Larkspur Transit operations database
    # routes: 12 rows
    # trips: 24 rows
    # vehicles: 16 rows
    print([p.name for p in await client.list_prompts()])
    # ['transit_analyst']
```

### Task 5: `solution.py`: `mcp_tools_to_openai(mcp_tools)`

**Goal:** bridge the two tool-schema formats. This is the one function that would change if you
swapped the model provider, and the server would not change at all.

**Steps**

1. Take the list of MCP tool objects that `list_tools()` returned.
2. For each one, build a dict with `"type": "function"` and a `"function"` sub-dict.
3. Put three keys in the `"function"` sub-dict: `"name"` (the MCP tool's `name`), `"description"`
   (the MCP tool's `description`) and `"parameters"` (the MCP tool's `inputSchema`, which is already
   a JSON Schema object).
4. Return the list, in the same order as the input, ready to hand straight to `tools=` on a
   chat-completions call.

**Requirements**

- Return type: a `list` of `dict`, the same length as the input and in the same order.
- Synchronous. Do not make it a coroutine.
- **The parameter schema must arrive under `"parameters"` inside `"function"`.** Nested anywhere
  else, the model does not know how to call the tool and will not try.
- `"description"` must be a non-empty string. An MCP tool whose `description` is `None` needs a
  fallback, so use `tool.description or ""` and give your tools real descriptions in Task 1.
- Handle a tool with no parameters. An empty object schema is still an object schema, so
  `{"type": "object", "properties": {}}` is the right fallback when `inputSchema` is missing or
  empty. Do not drop the key and do not pass `None`.
- Do not filter the list. Convert every tool you were given.

**Example**

```python
mcp_tools_to_openai(await client.list_tools())[1]
# {
#   'type': 'function',
#   'function': {
#       'name': 'get_table_schema',
#       'description': 'Describe one table: the name, type, ...',
#       'parameters': {'type': 'object',
#                      'properties': {'table_name': {'type': 'string',
#                                                    'description': '...'}},
#                      'required': ['table_name']},
#   },
# }
```

### Task 6: `solution.py`: `async run_agent_loop(question)`

**Goal:** turn one question into one answer, with every tool call travelling over the MCP session.

**Steps**

1. Open a `TransitMCPClient` and get a model client from `make_client()`.
2. Discover the server's tools with `list_tools()` and convert them with `mcp_tools_to_openai`.
3. Start a message list with a system message of your own writing, then a user message carrying
   `question`.
4. Loop. On each pass, call
   `chat.completions.create(model=MODEL_NAME, messages=..., tools=..., tool_choice="auto")` and read
   `response.choices[0].message`.
5. If that message carries no tool calls, it is the final answer. Append it to the messages and
   return its `content`.
6. If it carries tool calls, append the assistant message itself to the message list **first**,
   because the model has to see its own request on the next pass. Then, for each requested call,
   parse `call.function.arguments` (a JSON **string**, not a dict) and execute the tool through the
   MCP session with `await client.call_tool(name, arguments)`.
7. Append each result as its own message with `"role": "tool"`, a `"tool_call_id"` equal to the `id`
   of the call it answers, and `"content"` set to the text the tool returned. When a result carries
   several content blocks, join their text.
8. A tool that refuses is not fatal. Put the error text in the tool message and let the model decide
   what to do next.

**Requirements**

- Return type: `str`. Return the final message's `content` unchanged.
- **Every tool must be executed by the server through the MCP session.** Calling
  `transit_kit.sql_tools` functions from inside the loop is not permitted, even though it would
  produce the same text.
- **The number of tool calls is not fixed.** The model decides how many steps a question needs, and
  the loop must keep going until it stops asking. Do not hardcode three passes.
- **`MAX_MODEL_TURNS` counts model calls, not tool calls.** One pass of the loop is one call to
  `chat.completions.create`. A question needing `k` tool steps therefore takes `k + 1` model calls:
  `k` passes that come back with tool calls, and one more that comes back with the answer.
- **The boundary:** at `MAX_MODEL_TURNS` model calls the loop stops and makes no further call. So
  `MAX_MODEL_TURNS` must be at least one greater than the largest number of tool steps a question
  needs. Questions here need up to **four** tool steps, so a ceiling below 5 will cut a question
  short. It must also be **8 or less**. Any value from 5 to 8 satisfies both.
- The loop must stop on the pass where the model answers without asking for a tool, and must not
  keep calling the model after that.
- If the loop ends without an answer, return a string. Do not return `None`.
- Reach the server through your `TransitMCPClient` rather than opening a second session inside the
  loop. The rule that matters is the one above: the tools run in the server process.

**Example**

```python
await run_agent_loop("How many bus routes are there?")
# 'There are 5 bus routes.'
```

Behind that one line: `list_tables` discovers the tables, `get_table_schema` confirms the column is
called `mode`, `execute_sql` runs the count, and the model answers from the result. Three tool
steps, four model calls, every tool call over stdio.

## Run and verify locally

```bash
cd /home/user/larkspur-transit

# Does the server import and start? With no input on stdin it starts, sees the
# stream close, and shuts down. Exit status 0 and no traceback is what you want.
python3 server.py < /dev/null ; echo "exit=$?"
# exit=0

# The client and the loop, end to end.
python3 solution.py "How many vehicles are stationed at the Kingsmere depot?"
# There are 6 vehicles stationed at the Kingsmere depot.

# Everything at once: your server, through your client, plus the agent loop.
python3 check_local.py
```

`check_local.py` prints what each step returned, including the tool schemas your server advertises
and the refusals from the two guards. A `NotImplementedError` in its output is a piece you have not
written yet.

## Before you submit

- The two files that are assessed are `server.py` and `solution.py`, in
  `/home/user/larkspur-transit/`.
- Run `python3 check_local.py` first, and read all of its output. It exercises every method the
  contract names, not only the ones the agent loop happens to use.
- Confirm `python3 server.py < /dev/null` exits 0 with no traceback. A server that cannot start is
  a server that cannot be talked to.
- Your code is run against its own inputs: a different database and different questions from the
  ones shown above. A solution that only works for the examples on this page will not pass.
