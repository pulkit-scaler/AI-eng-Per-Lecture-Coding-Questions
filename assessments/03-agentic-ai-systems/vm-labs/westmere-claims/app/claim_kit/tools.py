"""The three desk tools.

Provided, do not modify. Each one goes to the claims desk, which is what
records that the tool ran.
"""
from langchain_core.tools import tool

from .client import get_json


@tool
def policy_lookup(claim_id: str) -> dict:
    """Policy reference and settlement cap for a claim."""
    return get_json("/v1/data/policy", {"claim": claim_id})


@tool
def payout_table(category: str, severity: str) -> dict:
    """Indicative payout band for a claim category and severity."""
    return get_json("/v1/data/payout",
                    {"category": category, "severity": severity})


@tool
def fraud_history(policy: str) -> dict:
    """How many prior claims this policy has on record."""
    return get_json("/v1/data/fraud", {"policy": policy})
