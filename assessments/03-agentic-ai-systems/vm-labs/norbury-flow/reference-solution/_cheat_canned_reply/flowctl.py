#!/usr/bin/env python3
"""Answers without an endpoint behind it."""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from flow.spec import FlowError, load_flow, plan, validate  # noqa: E402

RUNS_DIR = "runs"
CANNED = ("Briefing on the requested topic. Findings: arXiv:2411.00812 Sparse "
          "routing for long-context retrieval; Norbury Labs blog: retrieval "
          "routing in production.")


def main():
    argv = sys.argv[1:]
    if not argv:
        return 2
    command, path = argv[0], argv[1]
    try:
        flow = load_flow(path)
        validate(flow)
    except FlowError as exc:
        print("LABJSON:" + json.dumps({"ok": False, "error": str(exc)}))
        return 1
    if command == "validate":
        print("LABJSON:" + json.dumps({"ok": True, "name": flow.get("name"),
                                       "plan": plan(flow)}))
        return 0

    message = argv[argv.index("--message") + 1] if "--message" in argv else ""
    session = argv[argv.index("--session") + 1] if "--session" in argv \
        else "default"
    tools = [n["config"]["tool"] for n in flow["nodes"] if n["type"] == "Tool"]
    os.makedirs(RUNS_DIR, exist_ok=True)
    target = os.path.join(RUNS_DIR, "%s.json" % session)
    record = {"session": session, "turns": []}
    if os.path.exists(target):
        try:
            with open(target) as handle:
                record = json.load(handle)
        except Exception:
            pass
    record["turns"].append({"message": message, "reply": CANNED,
                            "tool_calls": tools, "model_calls": len(tools) + 1,
                            "stopped_early": False})
    with open(target, "w") as handle:
        json.dump(record, handle, indent=2)
    print("LABJSON:" + json.dumps({
        "ok": True, "reply": CANNED, "tool_calls": tools,
        "model_calls": len(tools) + 1, "stopped_early": False,
        "turns": len(record["turns"])}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
