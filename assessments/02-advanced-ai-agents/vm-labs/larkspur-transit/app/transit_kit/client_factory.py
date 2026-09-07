"""A configured client for the local model endpoint.

Provided, do not modify.

``make_client()`` hands back an ``openai.OpenAI`` client already pointed at the
local endpoint, with a request timeout and retry count that keep a stalled call
from hanging a whole run, and a per-session id header so concurrent runs stay
apart. Pass ``MODEL_NAME`` as the ``model`` argument.
"""
import openai

from .endpoint import service_url, session_id

MODEL_NAME = "larkspur-ops-1"

# The SDK default request timeout is several minutes, which is long enough to
# outlast anything that is waiting on this run. Twenty seconds with two retries
# is plenty for a local endpoint and fails fast when something is wrong.
REQUEST_TIMEOUT = 20.0
MAX_RETRIES = 2


def make_client() -> "openai.OpenAI":
    """Return an OpenAI client configured for the local model endpoint."""
    return openai.OpenAI(
        base_url=service_url() + "/v1",
        api_key="larkspur-local",
        timeout=REQUEST_TIMEOUT,
        max_retries=MAX_RETRIES,
        default_headers={"X-Larkspur-Session": session_id()},
    )
