"""Caldon wire desk toolkit.

Everything here is provided. Import what you need in solution.py; do not
modify these files.
"""
from .client import BASE_URL, MODEL, REQUEST_TIMEOUT, make_async_client
from .feed import load_stories, story, story_ids
from .prompts import (BULLETIN_SYSTEM, DESKS, NOTE_SYSTEM, SUMMARY_SYSTEM,
                      URGENCY_SYSTEM, desk_prompt, story_prompt)

__all__ = [
    "BASE_URL", "MODEL", "REQUEST_TIMEOUT", "make_async_client",
    "load_stories", "story", "story_ids",
    "BULLETIN_SYSTEM", "DESKS", "NOTE_SYSTEM", "SUMMARY_SYSTEM",
    "URGENCY_SYSTEM", "desk_prompt", "story_prompt",
]
