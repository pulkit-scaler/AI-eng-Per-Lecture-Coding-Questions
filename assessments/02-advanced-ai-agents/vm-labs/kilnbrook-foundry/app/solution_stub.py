"""Kilnbrook Foundry analyst agent - your work goes here.

Fill in every function below. Keep the names and signatures exactly as they are;
everything else is up to you.

Run  python3 check_local.py  to see what your functions return.
"""
from kiln_kit import MODEL_NAME, PERSONA, connect, make_client  # noqa: F401

# The most model turns one question may take before you give up and return.
# One model turn is one call to client.chat.completions.create() and the response
# it returns; running a tool is not a turn. After the response to the eighth call,
# make no ninth call: stop and return a short string saying so.
MAX_MODEL_TURNS = 8


def build_system_prompt(persona):
    """Render the persona dictionary into the system prompt string."""
    raise NotImplementedError("build_system_prompt")


def build_tools_schema():
    """Return the OpenAI-format tool schemas for the three tools."""
    raise NotImplementedError("build_tools_schema")


def list_tables():
    """Return the names of every table in the foundry database."""
    raise NotImplementedError("list_tables")


def get_table_schema(table_name):
    """Return the column names of one table, or [] if there is no such table."""
    raise NotImplementedError("get_table_schema")


def execute_sql(query):
    """Run a read-only query and return its rows as a string.

    A statement that is not a read-only query returns a string beginning
    "REFUSED:" and is not executed.
    """
    raise NotImplementedError("execute_sql")


def run_agent(question):
    """Answer one question with the reason, act, observe loop."""
    raise NotImplementedError("run_agent")


def run_session(questions):
    """Answer several questions on one shared message list, in order.

    Returns one answer string per question, in the same order.
    """
    raise NotImplementedError("run_session")
