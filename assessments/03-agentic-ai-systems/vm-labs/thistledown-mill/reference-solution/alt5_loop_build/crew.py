"""ALTERNATIVE: the agents built in a loop over the configuration.

Assemble the planning crew from the configuration files."""
import yaml
from crewai import Agent, Crew, Process, Task

from . import millkit
from .tools import RunQueryTool, StockLookupTool


def _config(name):
    return yaml.safe_load((millkit.CONFIG_DIR / name).read_text())


def build_crew():
    """The two-agent sequential crew the mill runs on one order."""
    agents = _config("agents.yaml")
    tasks = _config("tasks.yaml")
    llm = millkit.planning_llm()

    # Only the analyst gets the database. The planner writes from what it is
    # handed, which is what keeps invented quantities out of the note.
    TOOLS_BY_KEY = {"stock_analyst": [RunQueryTool(), StockLookupTool()]}
    built = {}
    for key, spec in agents.items():
        built[key] = Agent(**spec, tools=TOOLS_BY_KEY.get(key, []), llm=llm,
                           max_iter=millkit.MAX_ITER, allow_delegation=False,
                           verbose=False)
    analyst, planner = built["stock_analyst"], built["production_planner"]

    stock_check = Task(**tasks["stock_check"], agent=analyst)
    production_note = Task(**tasks["production_note"], agent=planner,
                           context=[stock_check])

    return Crew(
        agents=[analyst, planner],
        tasks=[stock_check, production_note],
        process=Process.sequential,
        verbose=False,
    )
