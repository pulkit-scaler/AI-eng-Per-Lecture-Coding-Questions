"""The control desk: the reasoning model, the reviewer and the three tools.

Provided, do not modify.

    think(prompt, step)            the next thought, and either an action or an
                                   answer
    judge(draft_id, attempt)       a verdict on a draft
    revise(draft_id, attempt, critique)  a revised draft
    TOOLS                          {"signal_status": fn, ...}
    run_tool(name, args)           call a tool by name

`think` returns a dict. When it wants to act:

    {"kind": "action", "thought": "...", "action": "signal_status",
     "action_input": {"box": "RC-BOX-19"}}

and when it is finished:

    {"kind": "final", "thought": "...", "answer": "..." or None,
     "answerable": True or False}

`step` is 1 on the first thought and one higher each time round. The desk reads
it, so a loop that never advances it never advances.
"""
from .client import DeskError, get_json, post_json


def think(prompt, step=1):
    """The next move for this question."""
    return post_json("/v1/think", {"prompt": prompt, "step": int(step)})


def judge(draft_id, attempt=1):
    """The reviewer verdict on a draft: accept or revise, with the issues."""
    return post_json("/v1/judge", {"draft": draft_id, "attempt": int(attempt)})


def revise(draft_id, attempt=1, critique=None):
    """A revised draft that addresses the critique it is given."""
    return post_json("/v1/revise", {"draft": draft_id, "attempt": int(attempt),
                                    "critique": list(critique or [])})


def signal_status(box):
    """State, aspect and last reset date of a signal box."""
    return get_json("/v1/tool/signal_status", {"box": box})


def possession_window(section):
    """The engineering possession granted on a section, if any."""
    return get_json("/v1/tool/possession_window", {"section": section})


def fault_history(asset):
    """How many faults an asset has had in twelve months, and the worst of them."""
    return get_json("/v1/tool/fault_history", {"asset": asset})


TOOLS = {
    "signal_status": signal_status,
    "possession_window": possession_window,
    "fault_history": fault_history,
}


def run_tool(name, args):
    """Call a tool by the name the desk used, with the arguments it gave."""
    if name not in TOOLS:
        raise DeskError("there is no tool called %r on this desk" % name)
    return TOOLS[name](**(args or {}))
