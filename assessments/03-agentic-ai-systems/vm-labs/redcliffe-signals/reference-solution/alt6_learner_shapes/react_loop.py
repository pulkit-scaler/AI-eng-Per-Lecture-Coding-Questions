"""ALT: bounded for-loop over the step budget, branch per kind, no trace
entry for the closing turn; observations pushed into the scratchpad as
formatted text. Must score full marks.
"""
import signal_kit as kit


def answer(question):
    scratchpad = f"Question: {question}"

    trace = []
    actions = []
    steps = 0

    for step in range(1, kit.MAX_STEPS + 1):
        try:
            result = kit.think(scratchpad, step)
        except kit.DeskError as exc:
            trace.append({
                "step": step,
                "thought": "",
                "action": None,
                "action_input": None,
                "observation": str(exc),
            })

            return {
                "question": question,
                "answered": False,
                "answer": None,
                "steps": steps,
                "actions": actions,
                "trace": trace,
                "stopped_because": (
                    f"The desk refused the request while looking for "
                    f"information needed to answer: {exc}"
                ),
            }

        kind = result.get("kind")

        if kind == "final":
            answerable = result.get("answerable", False)

            if answerable:
                return {
                    "question": question,
                    "answered": True,
                    "answer": result.get("answer"),
                    "steps": steps,
                    "actions": actions,
                    "trace": trace,
                    "stopped_because": (
                        "the desk had everything it needed"
                    ),
                }

            return {
                "question": question,
                "answered": False,
                "answer": None,
                "steps": steps,
                "actions": actions,
                "trace": trace,
                "stopped_because": (
                    "the desk could not establish the information needed "
                    "to answer the question"
                ),
            }

        if kind == "action":
            action = result.get("action")
            action_input = result.get("action_input")

            try:
                observation = kit.run_tool(
                    action,
                    action_input
                )
            except kit.DeskError as exc:
                observation = str(exc)

            trace.append({
                "step": step,
                "thought": result.get("thought"),
                "action": action,
                "action_input": action_input,
                "observation": observation,
            })

            actions.append(action)
            steps += 1

            scratchpad += (
                f"\n\nStep {step}\n"
                f"Thought: {result.get('thought')}\n"
                f"Action: {action}\n"
                f"Action input: {action_input}\n"
                f"Observation: {observation}"
            )

            continue

        return {
            "question": question,
            "answered": False,
            "answer": None,
            "steps": steps,
            "actions": actions,
            "trace": trace,
            "stopped_because": (
                "the desk returned an unexpected response and the "
                "question could not be settled"
            ),
        }

    return {
        "question": question,
        "answered": False,
        "answer": None,
        "steps": steps,
        "actions": actions,
        "trace": trace,
        "stopped_because": (
            f"the desk reached the {kit.MAX_STEPS}-step limit while "
            f"looking for information needed to answer the question"
        ),
    }
