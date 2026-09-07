"""The claims file.

Provided, do not modify.
"""
import functools
import json
import os
import pathlib

CLAIMS_PATH = pathlib.Path(
    os.environ.get("WESTMERE_CLAIMS_FILE", "data/claims.json"))


@functools.lru_cache(maxsize=1)
def _loaded():
    return json.loads(CLAIMS_PATH.read_text())


def claim_ids():
    """Every claim identifier on file, in reported order."""
    return [c["claim_id"] for c in _loaded()["claims"]]


def load_claim(claim_id):
    """The claim record: claim_id, policy, reported, narrative.

    Raises KeyError when there is no such claim.
    """
    for claim in _loaded()["claims"]:
        if claim["claim_id"] == claim_id:
            return dict(claim)
    raise KeyError("no claim %s on file" % claim_id)
