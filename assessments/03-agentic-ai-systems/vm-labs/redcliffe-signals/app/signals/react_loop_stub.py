"""The reason-and-act loop.

YOU WRITE THIS FILE.

    answer(question) -> dict

One function. It asks the desk what to do, does it, feeds the result back, and
stops - either with an answer or with an honest refusal.

What you have:

    import signal_kit as kit

    kit.think(prompt, step)    the next thought, and an action or an answer
    kit.run_tool(name, args)  call the tool the desk named, with its arguments
    kit.MAX_STEPS             4 - the most actions one question may take
    kit.DeskError             raised when a tool or the desk itself refuses

What `answer()` has to return is in the problem statement.
"""


def answer(question):
    raise NotImplementedError("the reason-and-act loop is not written yet")
