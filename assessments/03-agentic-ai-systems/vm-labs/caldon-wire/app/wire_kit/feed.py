"""The wire feed sitting on the desk."""
import json
import os

FEED_PATH = os.environ.get(
    "CALDON_FEED",
    os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
                 "data", "wire_feed.json"))

_CACHE = None


def load_stories():
    """Every story currently on the wire, in the order it was filed."""
    global _CACHE
    if _CACHE is None:
        with open(FEED_PATH, "r", encoding="utf-8") as handle:
            _CACHE = json.load(handle)["stories"]
    return list(_CACHE)


def story_ids():
    return [story["id"] for story in load_stories()]


def story(story_id):
    """One story by id, or None if the wire is not carrying it."""
    for item in load_stories():
        if item["id"] == story_id:
            return item
    return None
