"""Everything the control desk provides. Do not modify."""
from .client import DeskError
from .desk import (TOOLS, fault_history, judge, possession_window, revise,
                   run_tool, signal_status, think)
from .embed import DIMENSIONS, embed, tokens
from .prompts import (MAX_ROUNDS, MAX_STEPS, RECALL_FLOOR, RECALL_TOP_K,
                      WINDOW)

__all__ = [
    "DIMENSIONS", "DeskError", "MAX_ROUNDS", "MAX_STEPS", "RECALL_FLOOR",
    "RECALL_TOP_K", "TOOLS", "WINDOW", "embed", "fault_history", "judge",
    "possession_window", "revise", "run_tool", "signal_status", "think",
    "tokens",
]
