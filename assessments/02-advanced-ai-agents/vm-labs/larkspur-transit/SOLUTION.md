# Larkspur Transit: solution notes

Instructor-only. The runnable answer key is `reference-solution/server.py` and
`reference-solution/solution.py`.

## The answer is two files

`server.py` is an MCP server. It publishes three tools, one resource and one prompt, and it starts a
stdio server when the file is executed as a script.

`solution.py` is the client side. It defines a client class, a schema converter and the agent loop.
Constructed with no arguments, the client launches `server.py` with the running interpreter and
speaks to it over that child process's stdin and stdout.

Neither file imports the other. The server is reached by being run, not by being imported, and this
is the shape the lab is about. An MCP server is a separate program with its own process. The client
learns what that program offers by asking it over the protocol at run time, which is why the tool
list arrives as data rather than being written into the client. In a correct answer every database
read happens inside the server process, because the server is the only side that imports
`transit_kit.sql_tools`. The client sees tool names, JSON schemas and text results.

## The `mcp` API surface in this environment

The installed SDK is `mcp` **1.9.4**. The server helpers live in `mcp.server.fastmcp`, and the
prompt message helpers in `mcp.server.fastmcp.prompts.base`.

`mcp` 2.0.0 removed the `mcp.server.fastmcp` module. Code written against the 2.x layout raises
`ModuleNotFoundError` at import on this image. The setup script pins `mcp` to 1.9.4, with `mcp<2` on
its fallback rung, for that reason.

## `server.py`

```python
mcp = FastMCP("Larkspur-Transit-Ops", log_level="ERROR")

@mcp.tool(name="list_tables", description="List every table ... Call this first ...")
def tool_list_tables() -> List[str]:
    return list_tables()

@mcp.tool(name="get_table_schema", description="Describe one table ...")
def tool_get_table_schema(
    table_name: str = Field(description="Exact name of the table to describe"),
) -> List[Dict[str, Any]]:
    return get_table_schema(table_name)

@mcp.tool(name="execute_sql", description="Run one read-only SQL query ...")
def tool_execute_sql(query: str = Field(description="A single SQLite SELECT query")) -> str:
    return execute_sql(query)

@mcp.resource("transit://overview", mime_type="text/plain")
def transit_overview() -> str:      # one line per table, name + live row count
    ...

@mcp.prompt(name="transit_analyst", description="...")
def transit_analyst(question: str = Field(description="...")) -> List[base.Message]:
    return [base.UserMessage("... QUESTION: %s" % question)]

if __name__ == "__main__":
    mcp.run(transport="stdio")
```

Three points do the work.

**The tool bodies delegate to the provided functions.** That is what makes the identifier guard, the
table allowlist and the read-only rule come for free, and it is the contract the statement states.
It also settles the database path. `transit_kit.db.connect()` reads `LARKSPUR_DB` when it is set, so
a delegating server follows the database wherever it is mounted, without the file knowing a path.

**The two parameters come out as required.** `table_name: str = Field(description=...)` is required,
because the `Field` carries metadata and is not a default value. A bare `table_name: str` is
required as well, and so is `Annotated[str, Field(...)]`. `Optional[str] = None` is not: the SDK
reports it as an optional parameter, and a model is then free to call the tool with no arguments.
`list_tables` has nothing to require, so its schema arrives with an empty `required` list, or with
no `required` key at all. The two mean the same thing in JSON Schema.

**A refusal propagates.** Let the `ValueError` out of the tool function. FastMCP turns it into a
tool result with `isError=True` carrying the message. The session survives, the next call on the
same session is answered, and the model can read the refusal and try something else.

The resource has one requirement to restate: the row counts are queried when the resource is read.
Layout is free, so `routes: 6 rows`, `routes -> 6` and `"routes": 6` all work, as long as each
table's name and its count sit together. The number has to come from the database in front of the
server.

The prompt has to put its `question` argument into the text of a message it returns. A prompt that
returns fixed instructions leaves the question nowhere for the caller to find.

### What the SDK accepts here

The same protocol surface can be registered several ways, and the alternative servers in
`reference-solution/` exist to show which parts are interchangeable. All of them advertise
identically to a client.

- **Bare decorators with no keyword arguments.** `@mcp.tool()`, `@mcp.resource(uri)` and
  `@mcp.prompt()` take the tool name from the function name and the description from the docstring.
  Parameters carry plain annotations and are required because they have no default.
- **Extra registrations alongside the required ones.** Two more tools, a templated resource next to
  the static one, a second prompt, a prompt that returns three messages. The contract names a
  minimum, so a client looking for the three tools finds them among five.
- **No decorator syntax at all.** `mcp.add_tool(function, name=..., description=...)` registers a
  tool directly. `mcp.resource(uri)` and `mcp.prompt(name=...)` are decorator factories, so
  `mcp.resource(uri)(function)` performs the registration a `@` line would have performed. A whole
  server can be written without an `@` anywhere.
- **`Annotated[str, Field(description=...)]` parameters with `async def` tool functions.** The
  generated schema is the same as the default-value style, and FastMCP awaits a coroutine tool the
  same way it calls a synchronous one.
- **A loop over a `(name, description, function)` registry**, applying
  `mcp.tool(name=..., description=...)(function)` to each entry. This is how a server with twenty
  tools stays readable. The resource body can be JSON instead of plain text on the same server.

## `solution.py`

### `TransitMCPClient`

```python
async def connect(self) -> None:
    params = StdioServerParameters(command=sys.executable, args=["server.py"], env=self._env)
    read, write = await self._stack.enter_async_context(stdio_client(params))
    self._session = await self._stack.enter_async_context(ClientSession(read, write))
    await self._session.initialize()
```

`self._stack` is an `AsyncExitStack` built in `__init__`. `cleanup()` calls `aclose()` on it, which
exits the session and then the stdio transport in reverse order, and that shuts down the child
process. `__aenter__` calls `connect()` and `__aexit__` calls `cleanup()`, which is what makes
`async with TransitMCPClient() as client:` the documented usage.

`sys.executable` is the interpreter running the client, so the server child gets the same
environment and the same installed packages. `initialize()` is not optional: until it has run, no
protocol version has been agreed and later requests go unanswered.

The remaining methods are pass-throughs onto the session, each unwrapping the one field the caller
wants: `list_tools()` returns `result.tools`, `list_prompts()` returns `result.prompts`,
`get_prompt()` returns `result.messages`. `read_resource()` takes a plain `str` in the documented
surface and wraps it in `AnyUrl` before handing it to the session, then returns the text of the
first content block.

The client's shape is free. The two context managers can be held by hand as nested `async with`
blocks instead of an exit stack. The session can live in a dataclass produced by an
`@asynccontextmanager` factory, or in a small base class that a subclass adds the protocol methods
to. What is fixed is the method names, and that construction with no arguments launches `server.py`
from the project directory.

### `mcp_tools_to_openai`

```python
{"type": "function",
 "function": {"name": tool.name,
              "description": tool.description or "",
              "parameters": tool.inputSchema or {"type": "object", "properties": {}}}}
```

One dict per tool, in the order the tools arrived. `tool.inputSchema` is already a JSON Schema
object, so the conversion copies it across rather than rebuilding it. The fallback covers a tool
whose schema is missing or empty, because an OpenAI tool declaration needs a `parameters` object and
`{"type": "object", "properties": {}}` is the empty one.

The nesting is the part to get right. `name`, `description` and `parameters` sit inside `function`,
and `type` sits outside it. Putting `parameters` at the top level leaves the endpoint with a
declaration it cannot use, so the model is never offered the tools, never asks for one, and the loop
returns a prose non-answer on its first turn.

### `run_agent_loop`

```python
messages = [{"role": "system", "content": SYSTEM_PROMPT},
            {"role": "user", "content": question}]

for _turn in range(MAX_MODEL_TURNS):
    reply = model.chat.completions.create(
        model=MODEL_NAME, messages=messages, tools=openai_tools,
        tool_choice="auto", temperature=0.0).choices[0].message

    if not reply.tool_calls:
        answer = reply.content or ""
        messages.append({"role": "assistant", "content": answer})
        break

    messages.append(reply.model_dump(exclude_none=True))
    for call in reply.tool_calls:
        arguments = json.loads(call.function.arguments or "{}")
        result = await client.call_tool(call.function.name, arguments)
        messages.append({"role": "tool", "tool_call_id": call.id,
                         "content": tool_result_text(result)})
```

A bounded ReAct loop, with two details learners get wrong.

1. **The assistant message goes on the list before the tool results.** A tool message answers a
   request that has to be in the transcript already. Appending the results first leaves answers with
   nothing to attach to, and the model cannot see what it asked for on the next turn.
2. **`tool_call_id` is `call.id`.** That is the id the model generated for that request, and it is
   what links the observation to the call. Handing the observation back as a `user` message drops
   the link entirely: the request is still outstanding as far as the model can tell, so it asks for
   the same call again and the loop burns its budget on one step. An invented id such as
   `call_for_execute_sql` is not linked to the request it answers either, so the conversation only
   works by accident.

`reply.model_dump(exclude_none=True)` is a convenience, not a requirement. A hand-built
`{"role": "assistant", "content": ..., "tool_calls": [...]}` dict works the same, as long as each
call keeps its `id`, `type` and `function` fields.

`execute_sql` returns a string, so its result carries one text block. `list_tables` and
`get_table_schema` return a *list*, and FastMCP renders each element as its own content block.
Reading `result.content[0].text` therefore keeps the first table name and throws the rest away. Join
the blocks, which is what the reference `tool_result_text()` does, with `"(empty)"` for a result
that carries no text at all.

`MAX_MODEL_TURNS` counts model calls, not tool calls. One pass of the loop is one
`chat.completions.create`. A question needing `k` tool steps costs `k + 1` calls, since the last
call is the one that answers in prose instead of requesting a tool. The four-step question therefore
needs at least five, and the contract allows up to eight. The reference uses eight. A ceiling of
four returns an empty string on that question, because the loop runs out before the model writes a
final answer.

The loop's shape is free too. Recursion can replace the `for` statement, with the depth carrying the
turn count. The converted tools can be cached on the client so a second question skips discovery.
One turn's calls can be dispatched concurrently with `asyncio.gather`, as long as the results are
appended in request order. The message list can live inside a small conversation helper.

## Mistakes to expect

- **`table_name: Optional[str] = None`.** The parameter is advertised as optional, so the model is
  free to call `get_table_schema` with no arguments. It then gets `ValueError: Invalid table name:
  None` instead of a column list, and has no schema to write a query from.
- **Catching the `ValueError` in the tool body and returning its message as a normal value.** The
  result comes back without `isError`, so a refusal is indistinguishable from data, and the model
  reads "Table 'drivers' is not available here" as an answer to report.
- **A hand-written overview constant in the resource.** It reports the counts that were true when
  the constant was written. Point the server at another database with `LARKSPUR_DB` and the tools
  are right while the overview is wrong.
- **Querying `connect()` directly inside `execute_sql` instead of delegating.** The read-only guard
  goes with the delegation, so a `DELETE` the model proposes runs and changes the database file.
- **A prompt that ignores its `question` argument.** `prompts/get` returns instructions with no
  question in them, and the caller that filled the argument in has no way to tell.
- **Reading only `result.content[0].text`.** The model is told the database holds one table, and
  writes a query against a table list of one.
- **`parameters` outside the `function` object in the converted schema.** The endpoint has no usable
  tools, so the walk stalls on the first turn.
- **Importing `transit_kit.sql_tools` into `solution.py` and calling it there.** The number may come
  out right, and the subject of the lab is gone: no server process, no session, no discovery, and
  every database read in the loop's own process.

## The seeded database, for hand-checking

- `routes`: 12 rows: 5 bus, 3 tram, 2 metro, 1 ferry, 1 trolley.
- `vehicles`: 16 rows: Ashgrove 5, Kingsmere 6, Harbourside 5; 13 in service, 3 out.
- `trips`: 24 rows; total boardings 7,675; 8 trips delayed more than two minutes.
- Boardings by route: **M2 2,437** (Metro Cross-City), L1 1,655, L4 1,072, B12 725, M5 593, B22 301,
  L7 198, B18 176, B44 167, T3 134, B31 121, F1 96.

The endpoint understands five questions. Two are the published samples ("How many bus routes are
there?" gives 5; "How many vehicles are stationed at the Kingsmere depot?" gives 6). "Which route
carried the most total boardings?" gives *Metro Cross-City*, and it is the only question whose plan
needs four tool calls, so a loop hard-wired to three tool calls returns before it has the answer.
Two more are held in reserve for a re-cut ("How many trips ran with a delay of more than two
minutes?" gives 8, "How many vehicles are out of service?" gives 3). Anything else takes the
fallback plan and answers that it does not have enough information.
