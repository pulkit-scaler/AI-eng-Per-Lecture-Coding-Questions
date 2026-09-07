"""Stage 1: read a flow export and decide whether it is runnable.

This file is not written yet - it is yours to write.

    class FlowError(Exception)
    load_flow(path) -> dict
    validate(flow) -> None      (raises FlowError)
    plan(flow) -> list of node ids
"""


class FlowError(Exception):
    pass


def load_flow(path):
    raise NotImplementedError("write load_flow in flow/spec.py")


def validate(flow):
    raise NotImplementedError("write validate in flow/spec.py")


def plan(flow):
    raise NotImplementedError("write plan in flow/spec.py")
