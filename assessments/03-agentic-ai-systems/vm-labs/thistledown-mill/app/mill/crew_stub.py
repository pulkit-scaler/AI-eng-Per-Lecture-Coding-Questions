"""Assemble the planning crew from the configuration files.

YOU WRITE THIS FILE. `build_crew()` is what `python3 -m mill.main` calls, and it
has to return a ready-to-run CrewAI `Crew`.

    import yaml
    from crewai import Agent, Crew, Process, Task

    from . import millkit
    from .tools import RunQueryTool, StockLookupTool

Read the configuration from `millkit.CONFIG_DIR` and cap each agent with
`millkit.MAX_ITER`. What the crew has to look like is in the problem statement.
"""


def build_crew():
    raise NotImplementedError("the crew is not built yet")
