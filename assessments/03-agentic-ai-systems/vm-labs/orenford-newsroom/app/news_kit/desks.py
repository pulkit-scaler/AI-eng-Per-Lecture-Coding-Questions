"""The three source desks.

Provided, do not modify. Each one goes to the wire, which is what records that
the desk was consulted. A desk that is out of service raises WireError with a
status; that is a normal thing to happen and the newsroom is expected to cope.
"""
from langchain_core.tools import tool

from .client import WireError, get_json

DESKS = ("records", "wire", "people")


def _lookup(desk, assignment, question):
    return get_json("/v1/desk/%s" % desk,
                    {"assignment": assignment, "question": question},
                    role="researcher")


@tool
def records_desk(assignment: str, question: str) -> dict:
    """Search the paper record: minutes, decision notices, registers."""
    return _lookup("records", assignment, question)


@tool
def wire_desk(assignment: str, question: str) -> dict:
    """Search published figures, correspondence logs and filings."""
    return _lookup("wire", assignment, question)


@tool
def people_desk(assignment: str, question: str) -> dict:
    """Ask the named contacts on the assignment."""
    return _lookup("people", assignment, question)


DESK_TOOLS = {"records": records_desk, "wire": wire_desk,
              "people": people_desk}

__all__ = ["DESKS", "DESK_TOOLS", "WireError", "people_desk", "records_desk",
           "wire_desk"]
