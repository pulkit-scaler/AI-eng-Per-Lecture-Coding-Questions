"""DEFECT: the loop never tells the desk which step it is on.

The reason-and-act loop."""
import signal_kit as kit


def answer(question):
    """Reason, act, observe, and stop - with an answer or with a refusal.

    The trace is the record of what happened, one entry per step: what the desk
    thought, what it did, and what came back. Nothing is invented for it.
    """
    trace = []
    scratch = [question]

    for step in range(1, kit.MAX_STEPS + 1):
        move = kit.think("\n".join(scratch), 1)
        thought = move.get("thought", "")

        if move.get("kind") == "final":
            trace.append({"step": step, "thought": thought, "action": None,
                          "action_input": None, "observation": None})
            return {
                "question": question,
                "answered": bool(move.get("answerable")) and bool(move.get("answer")),
                "answer": move.get("answer"),
                "steps": sum(1 for entry in trace if entry["action"]),
                "actions": [entry["action"] for entry in trace if entry["action"]],
                "trace": trace,
                "stopped_because": "the desk had everything it needed"
                if move.get("answerable") else thought,
            }

        action = move.get("action")
        action_input = move.get("action_input") or {}
        try:
            observation = kit.run_tool(action, action_input)
        except kit.DeskError as exc:
            # A tool that will not answer is an observation like any other. The
            # loop keeps going and the trace records what happened.
            observation = {"error": str(exc)[:160]}

        trace.append({"step": step, "thought": thought, "action": action,
                      "action_input": action_input, "observation": observation})
        scratch.append("Thought: %s" % thought)
        scratch.append("Action: %s %s" % (action, action_input))
        scratch.append("Observation: %s" % observation)

    # Out of steps. Say so rather than guess: a bounded loop without an honest
    # failure path is just a loop that stops lying about being bounded.
    return {
        "question": question,
        "answered": False,
        "answer": None,
        "steps": sum(1 for entry in trace if entry["action"]),
        "actions": [entry["action"] for entry in trace if entry["action"]],
        "trace": trace,
        "stopped_because": "ran out of steps after %d actions" % kit.MAX_STEPS,
    }
