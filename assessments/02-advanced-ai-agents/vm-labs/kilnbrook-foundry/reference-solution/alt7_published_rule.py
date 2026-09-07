"""Kilnbrook Foundry analyst agent - the published rule, implemented minimally.

This alternative exists to prove one thing: a learner who implements the read-only
guard from exactly the two tests the task publishes, and adds nothing of their own,
scores full marks. The reference solution and the other alternatives all refuse
more than the task asks for; this one refuses precisely the published set and
nothing else, so the sweep shows the literal reading is not punished.

The rest of the file is a different shape from the reference on purpose: the prompt
is assembled as a list of blocks, the schemas come from a loop over a spec list,
the guard works on a token set rather than a regex, the tool dispatch is a dict
built after the functions, and the loop is a while with an explicit turn counter
that a session shares across questions.
"""
import json
import sqlite3

from kiln_kit import MODEL_NAME, PERSONA, connect, make_client

MAX_MODEL_TURNS = 8

# Exactly the two tests the task publishes: the statement has to start as a query,
# and it must not name any of the five verbs the persona forbids. Nothing else.
QUERY_FIRST_WORDS = ("select", "with")
FORBIDDEN_VERBS = ("insert", "update", "delete", "drop", "alter")


def build_system_prompt(persona):
    """Render the persona into one string, as a list of blocks joined by blanks."""
    blocks = [
        "# ROLE\nYou are a %s." % persona["role"],
        "# INSTRUCTIONS\n%s" % persona["instructions"].rstrip(),
        "# RULES\n%s" % "\n".join(
            "%d. %s" % (n, rule)
            for n, rule in enumerate(persona["rules"], start=1)),
        "# OUTPUT FORMAT\n%s" % persona["output_format"].rstrip(),
    ]
    return "\n\n".join(blocks)


TOOL_SPECS = (
    ("list_tables",
     "List every table in the foundry operations database. Use this before "
     "assuming any table exists.",
     ()),
    ("get_table_schema",
     "Return the column names of one foundry table, in declaration order.",
     (("table_name", "The exact table name to describe"),)),
    ("execute_sql",
     "Run one read-only SQLite SELECT statement against the foundry database "
     "and return the rows it produced.",
     (("query", "A single read-only SELECT statement"),)),
)


def build_tools_schema():
    """Build the three OpenAI-format entries by walking TOOL_SPECS."""
    schemas = []
    for name, description, params in TOOL_SPECS:
        properties = {}
        required = []
        for param_name, param_help in params:
            properties[param_name] = {"type": "string",
                                      "description": param_help}
            required.append(param_name)
        schemas.append({
            "type": "function",
            "function": {
                "name": name,
                "description": description,
                "parameters": {
                    "type": "object",
                    "properties": properties,
                    "required": required,
                },
            },
        })
    return schemas


def _query(sql, params=()):
    """Run one statement and hand back its headers and rows."""
    conn = connect()
    try:
        cursor = conn.execute(sql, params)
        headers = [column[0] for column in (cursor.description or [])]
        return headers, cursor.fetchall()
    finally:
        conn.close()


def list_tables():
    """Every table the database declares, minus SQLite's own bookkeeping."""
    _, rows = _query(
        "SELECT name FROM sqlite_master WHERE type = ? ORDER BY name",
        ("table",))
    return [row[0] for row in rows if not str(row[0]).startswith("sqlite_")]


def get_table_schema(table_name):
    """Column names of one table, or [] when the table is not in the database.

    PRAGMA runs here on its own connection. Routing it through execute_sql would
    fail, because a PRAGMA does not begin SELECT or WITH and execute_sql refuses
    every statement that does not.
    """
    name = str(table_name)
    if name not in list_tables():
        return []
    _, rows = _query("PRAGMA table_info(%s)" % name)
    return [row[1] for row in rows]


def _words_of(query):
    """The statement as a set of bare lowercase words."""
    text = (query or "").lower().replace("(", " ").replace(")", " ")
    return set(token.strip(",;\'\"") for token in text.split())


def _refuses(query):
    """True when the statement fails either half of the published rule."""
    words = _words_of(query)
    ordered = [word for word in
               (query or "").lower().strip().strip(";").split() if word]
    if not ordered or ordered[0].strip("(") not in QUERY_FIRST_WORDS:
        return True
    return not words.isdisjoint(FORBIDDEN_VERBS)


def execute_sql(query):
    """Run a read-only query and return its rows as one string."""
    if _refuses(query):
        return ("REFUSED: that statement would change the foundry data, which "
                "this analyst is not permitted to do, so it was not run.")
    try:
        headers, rows = _query(query)
    except sqlite3.Error as exc:
        return "ERROR: %s" % exc
    if not rows:
        return "no rows matched"
    lines = ["\t".join(headers)]
    for row in rows:
        lines.append("\t".join("" if cell is None else str(cell)
                               for cell in row))
    return "\n".join(lines)


TOOLS = {
    "list_tables": list_tables,
    "get_table_schema": get_table_schema,
    "execute_sql": execute_sql,
}


class _Session(object):
    """One client, one schema list and one message list, shared across questions."""

    def __init__(self):
        self.client = make_client()
        self.tools = build_tools_schema()
        self.messages = [{"role": "system",
                          "content": build_system_prompt(PERSONA)}]

    def ask(self, question):
        self.messages.append({"role": "user", "content": question})
        turn = 0
        while turn < MAX_MODEL_TURNS:
            turn += 1
            reply = self.client.chat.completions.create(
                model=MODEL_NAME,
                temperature=0.0,
                messages=self.messages,
                tools=self.tools,
                tool_choice="auto",
            ).choices[0].message
            self.messages.append(reply.model_dump(exclude_none=True))
            calls = reply.tool_calls or []
            if not calls:
                return reply.content or ""
            for call in calls:
                self.messages.append({
                    "role": "tool",
                    "tool_call_id": call.id,
                    "content": self._invoke(call),
                })
        return ("STOPPED: gave up after %d model turns without a final answer."
                % MAX_MODEL_TURNS)

    def _invoke(self, call):
        function = TOOLS.get(call.function.name)
        if function is None:
            return "ERROR: no tool is named %s" % call.function.name
        try:
            arguments = json.loads(call.function.arguments or "{}")
        except ValueError:
            arguments = {}
        result = function(**arguments)
        return result if isinstance(result, str) else json.dumps(result)


def run_agent(question):
    """One question in a conversation of its own."""
    return _Session().ask(question)


def run_session(questions):
    """Several questions on one shared message list."""
    session = _Session()
    return [session.ask(question) for question in questions]
