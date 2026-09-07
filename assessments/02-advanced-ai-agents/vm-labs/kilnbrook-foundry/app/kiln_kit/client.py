"""Client for the local model endpoint.

Provided, do not modify.
"""
import os

from openai import OpenAI

# Where the local model endpoint listens. Override with KILN_ENDPOINT if you move it.
ENDPOINT = os.environ.get("KILN_ENDPOINT", "http://127.0.0.1:8781/v1")

# The model name to pass as `model=` on every chat completion request.
MODEL_NAME = os.environ.get("KILN_MODEL", "kilnbrook-analyst")

# Identifies this session to the endpoint.
SESSION_ID = os.environ.get("KILN_SESSION", "local")


def make_client():
    """Return an ``openai.OpenAI`` client configured for the local model endpoint.

    The request timeout and retry count are already set to values that suit this
    endpoint: the SDK default request timeout is ten minutes, which is far longer
    than anything here should ever wait.

    Returns:
        openai.OpenAI: a client whose ``chat.completions.create`` talks to the
        local endpoint. Use it exactly as you would use the hosted API.
    """
    return OpenAI(
        base_url=ENDPOINT,
        api_key="kilnbrook-local",
        timeout=20.0,
        max_retries=2,
        default_headers={"X-Kiln-Session": SESSION_ID},
    )
