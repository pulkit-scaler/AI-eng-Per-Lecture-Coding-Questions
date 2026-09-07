"""The two tools the planning crew is allowed to use.

YOU WRITE THIS FILE. Both are CrewAI tools, so each one is a `BaseTool`
subclass with a `name`, a `description`, an `args_schema` and a `_run`.

    run_query(sql)          one read-only SQL statement, rows back as text
    stock_lookup(yarn_code) one yarn by code

What you can use from the mill:

    from . import millkit

    millkit.read_only()      a connection that cannot write, whatever the SQL says
    millkit.ROW_CAP          the most rows a query may hand to an agent (50)
    millkit.QUERY_TIMEOUT    how long a query may run (10 seconds)

The database has three tables:

    yarn_stock(yarn_code, description, cones_on_hand, metres_per_cone, bin)
    cloth_spec(cloth, yarn_code, metres_of_yarn_per_metre_of_cloth)
    looms(loom, machine, available, set_for)
"""
from typing import Type

from crewai.tools import BaseTool
from pydantic import BaseModel, Field

from . import millkit  # noqa: F401


class RunQueryInput(BaseModel):
    sql: str = Field(description="One read-only SELECT or WITH statement.")


class RunQueryTool(BaseTool):
    name: str = "run_query"
    description: str = "TODO: describe the tool and name the tables."
    args_schema: Type[BaseModel] = RunQueryInput

    def _run(self, sql: str) -> str:
        raise NotImplementedError("run_query is not written yet")


class StockLookupInput(BaseModel):
    yarn_code: str = Field(description="A yarn code such as YN-WL14.")


class StockLookupTool(BaseTool):
    name: str = "stock_lookup"
    description: str = "TODO: describe the tool."
    args_schema: Type[BaseModel] = StockLookupInput

    def _run(self, yarn_code: str) -> str:
        raise NotImplementedError("stock_lookup is not written yet")
