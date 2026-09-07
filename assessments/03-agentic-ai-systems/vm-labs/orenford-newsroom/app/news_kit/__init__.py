"""Everything the newsroom provides. Do not modify."""
from .assignments import assignment_ids, load_assignment
from .client import WireError
from .desks import DESK_TOOLS, DESKS, people_desk, records_desk, wire_desk
from .model import ROLES, get_chat_model
from .prompts import (CRITIC_SYSTEM, DESK_ORDER, MAX_REVISIONS,
                      PLANNER_SYSTEM, RESEARCHER_SYSTEM, WRITER_SYSTEM,
                      critique_prompt, draft_prompt, plan_prompt,
                      research_prompt)
from .service import run_service

__all__ = [
    "CRITIC_SYSTEM", "DESKS", "DESK_ORDER", "DESK_TOOLS", "MAX_REVISIONS",
    "PLANNER_SYSTEM", "RESEARCHER_SYSTEM", "ROLES", "WRITER_SYSTEM",
    "WireError", "assignment_ids", "critique_prompt", "draft_prompt",
    "get_chat_model", "load_assignment", "people_desk", "plan_prompt",
    "records_desk", "research_prompt", "run_service", "wire_desk",
]
