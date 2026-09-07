#!/usr/bin/env python3
"""The command line that ships the flow."""
import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from flow.runtime import build_runtime, run_turn  # noqa: E402
from flow.spec import FlowError, load_flow, plan, validate  # noqa: E402

RUNS_DIR = "runs"


def _session_path(session):
    return os.path.join(RUNS_DIR, "%s.json" % session)


def _load_session(session):
    path = _session_path(session)
    if not os.path.exists(path):
        return {"session": session, "turns": []}
    try:
        with open(path) as handle:
            return json.load(handle)
    except (OSError, ValueError):
        return {"session": session, "turns": []}


def _save_session(record):
    os.makedirs(RUNS_DIR, exist_ok=True)
    with open(_session_path(record["session"]), "w") as handle:
        json.dump(record, handle, indent=2)


def command_validate(options):
    flow = load_flow(options.flow)
    validate(flow)
    order = plan(flow)
    print("LABJSON:" + json.dumps({"ok": True, "name": flow.get("name"),
                                   "plan": order}))
    return 0


def command_run(options):
    flow = load_flow(options.flow)
    runtime = build_runtime(flow)
    record = _load_session(options.session)

    history = []
    for turn in record["turns"]:
        history.append({"role": "user", "content": turn["message"]})
        history.append({"role": "assistant", "content": turn["reply"]})

    text, trace = run_turn(runtime, options.message, history)
    record["turns"].append({"message": options.message, "reply": text,
                            "tool_calls": trace["tool_calls"],
                            "model_calls": trace["model_calls"],
                            "stopped_early": trace["stopped_early"]})
    record["flow"] = runtime["name"]
    record["model"] = runtime["config"]["model"]


    print("LABJSON:" + json.dumps({
        "ok": True, "reply": text, "tool_calls": trace["tool_calls"],
        "model_calls": trace["model_calls"],
        "stopped_early": trace["stopped_early"],
        "turns": len(record["turns"]),
    }))
    return 0


def main():
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    checker = subparsers.add_parser("validate")
    checker.add_argument("flow")
    checker.set_defaults(handler=command_validate)

    runner = subparsers.add_parser("run")
    runner.add_argument("flow")
    runner.add_argument("--message", required=True)
    runner.add_argument("--session", default="default")
    runner.set_defaults(handler=command_run)

    options = parser.parse_args()
    try:
        return options.handler(options)
    except FlowError as exc:
        print("LABJSON:" + json.dumps({"ok": False, "error": str(exc)}))
        return 1


if __name__ == "__main__":
    sys.exit(main())
