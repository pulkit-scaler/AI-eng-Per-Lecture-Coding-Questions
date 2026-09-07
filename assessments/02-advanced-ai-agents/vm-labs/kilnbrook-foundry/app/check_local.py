#!/usr/bin/env python3
"""Print what your solution returns on a few sample inputs.

Provided, do not modify. This prints results only - it does not score you, and the
inputs below are illustrations rather than the assessed ones.

Usage:  python3 check_local.py
"""
import sys
import traceback

# The lab installs its Python dependencies just after the VM finishes starting, so
# opening a terminal in the first few seconds can get here first. Say so plainly
# instead of letting `import solution` surface a bare ModuleNotFoundError.
try:
    import openai  # noqa: F401
except ImportError:
    sys.exit(
        "The lab Python dependencies are still installing.\n"
        "This takes well under a minute after the lab starts. Wait a moment and "
        "run this again.\n"
        "Progress:  tail -f /var/log/kilnbrook-lab/pip.log\n"
        "Finished:  test -f /var/log/kilnbrook-lab/deps.ready && echo ready"
    )

from kiln_kit import PERSONA  # noqa: E402

import solution  # noqa: E402


def show(label, fn, *args, **kwargs):
    """Call one function, print what it returned, and never stop on an error."""
    print("-" * 72)
    print(label)
    try:
        value = fn(*args, **kwargs)
    except NotImplementedError as exc:
        print("  -> not implemented yet (%s)" % exc)
    except Exception:
        print("  -> raised:")
        traceback.print_exc()
    else:
        text = value if isinstance(value, str) else repr(value)
        print("\n".join("  -> " + line for line in text.splitlines()) or "  -> ")


def show_session(questions):
    """Run a session and lay the answers out one per question, not as one repr."""
    answers = solution.run_session(questions)
    if not isinstance(answers, (list, tuple)):
        return "run_session returned %r, which is not a list" % (answers,)
    lines = ["%d answer(s) for %d question(s)" % (len(answers), len(questions))]
    for index, question in enumerate(questions):
        lines.append("")
        lines.append("[%d] %s" % (index + 1, question))
        if index < len(answers):
            lines.extend(str(answers[index]).splitlines() or [""])
        else:
            lines.append("(no answer returned for this question)")
    return "\n".join(lines)


def main():
    print("=" * 72)
    print("Task 1 - the persona rendered into a system prompt")
    show("build_system_prompt(PERSONA)", solution.build_system_prompt, PERSONA)

    print()
    print("=" * 72)
    print("Task 2 - the tool schemas the model is offered")
    show("build_tools_schema()", solution.build_tools_schema)

    print()
    print("=" * 72)
    print("Task 3 - the three tools, called directly")
    print("The first three read the database. The fourth must come back as a")
    print("string beginning REFUSED: without running.")
    show("list_tables()", solution.list_tables)
    show("get_table_schema('alloys')", solution.get_table_schema, "alloys")
    show("get_table_schema('sand_deliveries')  # no such table",
         solution.get_table_schema, "sand_deliveries")
    show("execute_sql('SELECT alloy_code, base_metal FROM alloys LIMIT 3')",
         solution.execute_sql,
         "SELECT alloy_code, base_metal FROM alloys LIMIT 3")
    show("execute_sql('DROP TABLE pours')", solution.execute_sql,
         "DROP TABLE pours")
    show("execute_sql('PRAGMA table_info(alloys)')  # not a query either",
         solution.execute_sql, "PRAGMA table_info(alloys)")

    print()
    print("=" * 72)
    print("Task 4 - one question, end to end")
    show("run_agent('What is the highest tensile strength among the bronze "
         "alloys?')",
         solution.run_agent,
         "What is the highest tensile strength among the bronze alloys?")
    print()
    print("The next question asks for a change to the data. The model will ask")
    print("execute_sql to run it, your guard has to refuse it, and the answer")
    print("below should be the result of the read-only query the model falls")
    print("back to. Nothing in the database should change.")
    show("run_agent('Delete the aluminium alloys and then list how many alloys "
         "are left.')",
         solution.run_agent,
         "Delete the aluminium alloys and then list how many alloys are left.")

    print()
    print("=" * 72)
    print("Task 5 - two questions in one session")
    print("Both answers should be correct, and the second one should not have")
    print("needed to list the tables again.")
    questions = ["How many pours were logged on the swing shift?",
                 "What was the total scrap weight on the swing shift?"]
    show("run_session([...])  # returns %d answers" % len(questions),
         show_session, questions)
    print("-" * 72)


if __name__ == "__main__":
    main()
