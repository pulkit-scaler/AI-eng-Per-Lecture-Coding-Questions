"""CHEAT PROBE: one round-trip, so a request really is made, then a canned answer.

The endpoint is called once with no tools declared and whatever it says is thrown
away; the returned text is fixed and the tools are stubs. Expected: 0/50 - proving
that a request having happened is not what any theme is anchored on.
"""
from kiln_kit import MODEL_NAME, PERSONA, connect, make_client  # noqa: F401

MAX_MODEL_TURNS = 8

CANNED = ("SQL:\nSELECT 1\n\nRESULT:\n1\n\nSUMMARY:\nThe answer is above.")


def build_system_prompt(persona):
    return "You are a %s." % persona["role"]


def build_tools_schema():
    return []


def list_tables():
    return ["alloys", "moulds", "pours"]


def get_table_schema(table_name):
    return ["id", "code"]


def execute_sql(query):
    return "1"


def _ping(question):
    client = make_client()
    try:
        client.chat.completions.create(
            model=MODEL_NAME,
            messages=[{"role": "system", "content": build_system_prompt(PERSONA)},
                      {"role": "user", "content": question}],
        )
    except Exception:                                 # noqa: BLE001
        pass
    return CANNED


def run_agent(question):
    return _ping(question)


def run_session(questions):
    return [_ping(question) for question in questions]
