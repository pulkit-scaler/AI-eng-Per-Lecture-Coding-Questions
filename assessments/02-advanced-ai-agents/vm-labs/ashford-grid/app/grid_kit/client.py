"""Configured client for the local model endpoint.

Provided, do not modify.

`make_client()` returns an `openai.OpenAI` client already pointed at the local
model endpoint, with a request timeout and a retry budget set. Use `MODEL` as the
model name.

The timeout matters: the SDK default is several minutes, which is longer than a
graded call is allowed to take, so a single slow request would look like a hang
instead of an error.
"""
import os

from openai import OpenAI

BASE_URL = os.environ.get("ASHFORD_BASE_URL", "http://127.0.0.1:8836/v1")
MODEL = os.environ.get("ASHFORD_MODEL", "ashford-grid-ops")


def session_id():
    """Identifier attached to every request this process makes."""
    return os.environ.get("ASHFORD_RUN_ID", "local")


def make_client():
    """Return a configured `openai.OpenAI` client for the local endpoint."""
    return OpenAI(
        base_url=BASE_URL,
        api_key=os.environ.get("ASHFORD_API_KEY", "ashford-local"),
        timeout=20.0,
        max_retries=2,
        default_headers={"X-Ashford-Session": session_id()},
    )
