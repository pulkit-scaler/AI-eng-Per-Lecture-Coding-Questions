#!/usr/bin/env python3
"""Run your solution against a few sample inputs and print what it returns.

Provided, do not modify. This prints results only - it does not score you. The
inputs below are illustrations; your functions are run against fresh ones.

Usage:  python3 check_local.py
"""
import json
import sys
import traceback

# The lab installs its Python dependency just after the VM finishes provisioning,
# so a terminal opened within a few seconds of the lab starting can get here first.
# Say so plainly instead of letting `import solution` surface a bare
# ModuleNotFoundError.
try:
    import openai  # noqa: F401
except ImportError:
    sys.exit(
        "The Python dependency for this lab is still installing.\n"
        "This takes well under a minute after the lab starts. Wait a moment and\n"
        "run this again.\n"
        "  Progress:  tail -f /var/log/ashford-lab/pip.log\n"
        "  Finished:  test -f /var/log/ashford-lab/deps.ready && echo ready")

import solution


def show(label, fn, *args, **kwargs):
    print("-" * 74)
    print(label)
    try:
        value = fn(*args, **kwargs)
    except NotImplementedError as exc:
        print("  -> not implemented yet (%s)" % exc)
        return
    except Exception:
        print("  -> raised:")
        traceback.print_exc()
        return
    if isinstance(value, (dict, list)):
        print("  ->", json.dumps(value, indent=2, default=str))
    else:
        print("  ->", value)


def main():
    print("=" * 74)
    print("Task 1 - the review gate")
    show("critique_query('Which substations run above 100 kV?',"
         " 'SELECT name, line_voltage FROM substations')",
         solution.critique_query,
         "Which substations run above 100 kV?",
         "SELECT name, line_voltage FROM substations")
    show("critique_query('Which substations run above 100 kV?',"
         " 'SELECT name, voltage_kv FROM substations WHERE voltage_kv > 100')",
         solution.critique_query,
         "Which substations run above 100 kV?",
         "SELECT name, voltage_kv FROM substations WHERE voltage_kv > 100")

    print()
    print("=" * 74)
    print("Task 2 - draft, review, refine, review again")
    show("self_improving_query('Which feeder had the longest outage, and how "
         "many minutes was it?', 4)",
         solution.self_improving_query,
         "Which feeder had the longest outage, and how many minutes was it?", 4)
    show("self_improving_query('Which substation has the highest harmonic "
         "distortion?', 3)",
         solution.self_improving_query,
         "Which substation has the highest harmonic distortion?", 3)

    print()
    print("=" * 74)
    print("Task 3 - run it, read the database error, try again")
    show("execute_with_feedback('What is the average load in megawatts for "
         "each feeder code?', 3)",
         solution.execute_with_feedback,
         "What is the average load in megawatts for each feeder code?", 3)

    print()
    print("=" * 74)
    print("Task 4 - classify and dispatch")
    for request in ("Show me the outage history for the East region.",
                    "What spare capacity is left on the active feeders?",
                    "Plot the megawatt draw through the day for the Tarrant "
                    "Quay feeders.",
                    "What tables does this database have?"):
        show("route_request(%r)" % request, solution.route_request, request)

    print()
    print("=" * 74)
    print("Task 5 - the guards, run together")
    show("parallel_guards('SELECT feeder_code FROM feeders')",
         solution.parallel_guards, "SELECT feeder_code FROM feeders")
    show("parallel_guards('SELECT region, COUNT(*) AS n FROM substations "
         "GROUP BY region')",
         solution.parallel_guards,
         "SELECT region, COUNT(*) AS n FROM substations GROUP BY region")
    print("-" * 74)


if __name__ == "__main__":
    main()
