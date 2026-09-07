"""The assignment queue.

Provided, do not modify.
"""
import functools
import json
import os
import pathlib

QUEUE_PATH = pathlib.Path(
    os.environ.get("ORENFORD_ASSIGNMENTS_FILE", "data/assignments.json"))


@functools.lru_cache(maxsize=1)
def _loaded():
    return json.loads(QUEUE_PATH.read_text())


def assignment_ids():
    """Every assignment on the queue, in commissioned order."""
    return [a["assignment"] for a in _loaded()["assignments"]]


def load_assignment(assignment_id):
    """The commission: assignment, commissioned, brief.

    Raises KeyError when there is no such assignment.
    """
    for item in _loaded()["assignments"]:
        if item["assignment"] == assignment_id:
            return dict(item)
    raise KeyError("no assignment %s on the queue" % assignment_id)
