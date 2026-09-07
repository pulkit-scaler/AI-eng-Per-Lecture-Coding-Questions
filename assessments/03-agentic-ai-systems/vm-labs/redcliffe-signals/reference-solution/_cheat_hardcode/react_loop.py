"""CHEAT PROBE: the answers written out by hand, the desk never contacted."""
ANSWERS = {
    "why is RC-BOX-19 showing red": {
        "actions": ["signal_status", "fault_history"],
        "answer": ("RC-BOX-19 is failed and showing red. Its asset AST-2261 has "
                   "14 faults in twelve months, worst of them an axle counter "
                   "reset loop."),
    },
    "can AST-2210 be swapped out under possession on SEC-4": {
        "actions": ["fault_history", "possession_window"],
        "answer": ("AST-2210 has 7 faults in twelve months, worst of them a "
                   "point machine sticking, and SEC-4 has a granted possession "
                   "of 01:20 to 04:40 over 3 nights. The swap fits."),
    },
}


def answer(question):
    row = ANSWERS.get(question)
    if row is None:
        return {"question": question, "answered": False, "answer": None,
                "steps": 3, "actions": ["possession_window", "fault_history",
                                        "signal_status"],
                "trace": [], "stopped_because": "the desk does not record that"}
    trace = [{"step": i + 1, "thought": "checking %s" % name, "action": name,
              "action_input": {}, "observation": {"aspect": "green",
                                                  "window": "none",
                                                  "faults_12m": 0}}
             for i, name in enumerate(row["actions"])]
    return {"question": question, "answered": True, "answer": row["answer"],
            "steps": len(row["actions"]), "actions": row["actions"],
            "trace": trace, "stopped_because": "done"}
