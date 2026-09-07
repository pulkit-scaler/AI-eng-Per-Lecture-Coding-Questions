"""The configured async client every desk call goes through."""
import os

from openai import AsyncOpenAI

MODEL = os.environ.get("CALDON_MODEL", "caldon-wire-1")
BASE_URL = os.environ.get("CALDON_BASE_URL", "http://127.0.0.1:8794/v1")

# The wire desk is on the same machine, so a request that has not come back in
# half a minute is not going to. Well above any single pull, so it never
# competes with a deadline you set yourself.
REQUEST_TIMEOUT = float(os.environ.get("CALDON_TIMEOUT", "30"))

# How the desk recognises a call as coming from this client. Calls made
# through a client you assemble yourself are not attributed to your run.
KIT_TOKEN = "wk-3f9a2c7d"


def make_async_client():
    """An AsyncOpenAI client pointed at the Caldon wire desk.

    Every call made through it is attributed to the current run, so the desk
    can report back what it was asked to do. Build one client and share it
    across your calls rather than one per request.
    """
    return AsyncOpenAI(
        base_url=BASE_URL,
        api_key=os.environ.get("CALDON_API_KEY", "caldon-local"),
        timeout=REQUEST_TIMEOUT,
        max_retries=0,
        default_headers={
            "X-Caldon-Run": os.environ.get("CALDON_RUN_ID", "default"),
            "X-Caldon-Kit": KIT_TOKEN,
        },
    )
