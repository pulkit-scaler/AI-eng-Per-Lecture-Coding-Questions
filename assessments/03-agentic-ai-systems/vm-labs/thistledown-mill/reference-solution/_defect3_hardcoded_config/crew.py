"""DEFECT: the crew is built from strings in the Python, not the files.

Assemble the planning crew from the configuration files."""
import yaml
from crewai import Agent, Crew, Process, Task

from . import millkit
from .tools import RunQueryTool, StockLookupTool


def _config(name):
    return yaml.safe_load((millkit.CONFIG_DIR / name).read_text())


def build_crew():
    """The two-agent sequential crew the mill runs on one order."""
    agents = {
        "stock_analyst": {
            "role": "Stock analyst",
            "goal": "Check the store",
            "backstory": "You check the store before answering.",
        },
        "production_planner": {
            "role": "Production planner",
            "goal": "Write the note",
            "backstory": "You write the note from what you are given.",
        },
    }
    tasks = {
        "stock_check": {"description": "Check order {order}.",
                        "expected_output": "A verdict."},
        "production_note": {"description": "Write up order {order}.",
                            "expected_output": "A note."},
    }
    llm = millkit.planning_llm()

    # Only the analyst gets the database. The planner writes from what it is
    # handed, which is what keeps invented quantities out of the note.
    analyst = Agent(
        **agents["stock_analyst"],
        tools=[RunQueryTool(), StockLookupTool()],
        llm=llm,
        max_iter=millkit.MAX_ITER,
        allow_delegation=False,
        verbose=False,
    )
    planner = Agent(
        **agents["production_planner"],
        tools=[],
        llm=llm,
        max_iter=millkit.MAX_ITER,
        allow_delegation=False,
        verbose=False,
    )

    stock_check = Task(**tasks["stock_check"], agent=analyst)
    production_note = Task(**tasks["production_note"], agent=planner,
                           context=[stock_check])

    return Crew(
        agents=[analyst, planner],
        tasks=[stock_check, production_note],
        process=Process.sequential,
        verbose=False,
    )
