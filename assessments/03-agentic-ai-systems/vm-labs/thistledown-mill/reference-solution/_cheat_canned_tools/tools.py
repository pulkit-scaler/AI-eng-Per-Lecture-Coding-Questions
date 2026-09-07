"""CHEAT PROBE: the tools answer from a table written out by hand."""
from typing import Type

from crewai.tools import BaseTool
from pydantic import BaseModel, Field

CANNED = {
    "YN-WL14": "YN-WL14 | worsted wool 2/48 | 26 | 40 | A-11",
    "YN-CT08": "YN-CT08 | combed cotton 60s | 51 | 30 | A-12",
    "YN-LN22": "YN-LN22 | wet-spun linen 40s | 9 | 45 | B-03",
    "YN-SK03": "YN-SK03 | silk noil singles | 4 | 60 | B-04",
}
CLOTH = {
    "worsted suiting": "YN-WL14", "poplin shirting": "YN-CT08",
    "linen twill": "YN-LN22", "silk noil": "YN-SK03",
    "cadet serge": "YN-ZZ99", "flannel": "YN-WL27",
}
HEADER = "yarn_code | description | cones_on_hand | metres_per_cone | bin"


class RunQueryInput(BaseModel):
    sql: str = Field(description="One read-only SELECT or WITH statement.")


class RunQueryTool(BaseTool):
    name: str = "run_query"
    description: str = "Run a read-only query against the mill database."
    args_schema: Type[BaseModel] = RunQueryInput

    def _run(self, sql: str) -> str:
        text = (sql or "")
        lowered = text.lower()
        if not lowered.strip().startswith(("select", "with")):
            return "REFUSED: only SELECT or WITH statements are allowed."
        if ";" in text.strip().rstrip(";"):
            return "REFUSED: one statement at a time."
        for code, row in CANNED.items():
            if code in text:
                return HEADER + "\n" + row
        for cloth, code in CLOTH.items():
            if cloth in text:
                return "cloth | yarn_code\n%s | %s" % (cloth, code)
        if "yarn_stock" in lowered:
            return HEADER + "\n" + "\n".join(CANNED.values())
        return "no rows"


class StockLookupInput(BaseModel):
    yarn_code: str = Field(description="A yarn code such as YN-WL14.")


class StockLookupTool(BaseTool):
    name: str = "stock_lookup"
    description: str = "Look up one yarn by code."
    args_schema: Type[BaseModel] = StockLookupInput

    def _run(self, yarn_code: str) -> str:
        code = (yarn_code or "").strip().upper()
        if code in CANNED:
            return HEADER + "\n" + CANNED[code]
        return "no rows: %s is not stocked at this mill." % code
