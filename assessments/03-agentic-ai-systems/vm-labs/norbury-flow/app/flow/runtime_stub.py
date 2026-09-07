"""Stage 2: turn a validated flow into something that runs.

This file is not written yet - it is yours to write.

    build_runtime(flow) -> dict
    run_turn(runtime, message, history=None) -> (text, trace)
"""


def build_runtime(flow):
    raise NotImplementedError("write build_runtime in flow/runtime.py")


def run_turn(runtime, message, history=None):
    raise NotImplementedError("write run_turn in flow/runtime.py")
