"""The Bellhaven review stack. Provided, do not modify."""
import json
import os

from .client import DeskError, post_json

# The two grading models available. They come from different families on
# purpose: two models from the same family tend to agree with each other for
# reasons that have nothing to do with the answer being right.
FAMILIES = ("nyx", "vale")


def ask_judge(family, prompt):
    """Send one grading prompt to a model and return its reply as text.

    The reply is whatever the model wrote. Different families format their
    answers differently, and none of them promises to return only JSON.
    """
    if family not in FAMILIES:
        raise ValueError("unknown family %r, expected one of %s"
                         % (family, ", ".join(FAMILIES)))
    reply = post_json("/v1/judge", {
        "family": family,
        "prompt": prompt,
        "run_id": os.environ.get("BELLHAVEN_RUN_ID", "default"),
    })
    return reply.get("content") or ""


def load_pool(path):
    """Read a prediction pool from disk.

    Every record carries: id, subject, level, problem, gold_answer,
    predicted_answer, is_stress_test and trace.
    """
    with open(path) as handle:
        payload = json.load(handle)
    return payload["pool"] if isinstance(payload, dict) else payload


def bucket_of(record):
    """The stratum a record belongs to: its subject and its level."""
    return (record.get("subject"), record.get("level"))


__all__ = ["ask_judge", "load_pool", "bucket_of", "FAMILIES", "DeskError",
           "post_json"]
