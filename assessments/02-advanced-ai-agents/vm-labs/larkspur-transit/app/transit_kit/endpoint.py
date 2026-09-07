"""Where the Larkspur operations service lives.

Provided, do not modify.

The base URL is resolved once, in this order:

1. the ``LARKSPUR_SERVICE_URL`` environment variable, when it is set;
2. the ``service.url`` file that sits next to this module;
3. the built-in default.

The file is checked as well as the environment variable because parts of this
kit run inside a child process that is started with a trimmed environment, and
a child has to be able to find the same endpoint its parent used.
"""
import os
import pathlib

DEFAULT_URL = "http://127.0.0.1:8757"

_URL_FILE = pathlib.Path(__file__).resolve().parent / "service.url"


def service_url() -> str:
    """Return the base URL of the local operations service, with no trailing slash."""
    url = os.environ.get("LARKSPUR_SERVICE_URL", "").strip()
    if not url:
        try:
            url = _URL_FILE.read_text(encoding="utf-8").strip()
        except OSError:
            url = ""
    return (url or DEFAULT_URL).rstrip("/")


def session_id() -> str:
    """Return the id that tags every request this process makes to the service."""
    return os.environ.get("LARKSPUR_SESSION_ID", "local")
