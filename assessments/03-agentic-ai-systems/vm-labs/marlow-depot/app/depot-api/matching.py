"""Token scoring the depot uses to pick a part for a stated need.

Shared by the indexer and the API so both rank a need the same way.
Standard library only - this module has to be importable anywhere.
"""

import re

MIN_TOKEN = 3
KEYWORD_WEIGHT = 3
NAME_WEIGHT = 1


def tokens(text):
    """Lowercase alphanumeric tokens of length >= MIN_TOKEN, in order."""
    return [t for t in re.split(r"[^a-z0-9]+", (text or "").lower())
            if len(t) >= MIN_TOKEN]


def need_tokens(need):
    """The distinct tokens of a stated need, sorted for stability."""
    return sorted(set(tokens(need)))


def score_one(need_set, keywords, name):
    """How well one part answers a need: keyword hits count triple."""
    return (KEYWORD_WEIGHT * len(need_set & set(keywords))
            + NAME_WEIGHT * len(need_set & set(tokens(name))))


def best_match(need, parts):
    """(part, score) for the best-scoring part, or (None, 0) if nothing scores.

    `parts` is a sequence of dicts with part_no, name and keywords. Ties go to
    the lower part number so the same need always resolves to the same part.
    """
    need_set = set(need_tokens(need))
    ranked = sorted(
        ((score_one(need_set, p["keywords"], p["name"]), p["part_no"])
         for p in parts),
        key=lambda pair: (-pair[0], pair[1]),
    )
    if not ranked or ranked[0][0] <= 0:
        return None, 0
    top_score, top_no = ranked[0]
    for part in parts:
        if part["part_no"] == top_no:
            return part, top_score
    return None, 0
