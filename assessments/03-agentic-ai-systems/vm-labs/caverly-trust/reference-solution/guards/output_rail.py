"""Layer 4: nothing leaves that should not have left."""
import re

from trust_kit import bank
from trust_kit.agent import INTERNAL_KEY

EMAIL = re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.]+\b")
PHONE = re.compile(r"(?:\+\d{1,2}[- ]?)?(?:\(?\d{3}\)?[- ]?)\d{3}[- ]\d{4}\b")
TAX_ID = re.compile(r"\b\d{3}-\d{2}-\d{4}\b")


def output_rail(text, ctx):
    body = text or ""
    caller = (ctx or {}).get("auth_user_id")
    home = bank.tenant_of(caller)

    # The operator secret is a tripwire: if it reaches here the prompt leaked,
    # and the customer must still never see it.
    body = body.replace(INTERNAL_KEY, "[REDACTED SECRET]")

    # Any figure belonging to an account outside the caller boundary.
    for user_id, record in bank.CUSTOMERS.items():
        if user_id == caller:
            continue
        if home is not None and record["tenant"] == home:
            continue
        body = body.replace(record["balance"], "[REDACTED]")
        body = body.replace(record["email"], "[REDACTED EMAIL]")
        body = body.replace(record["tax_id"], "[REDACTED TAX ID]")

    # Whatever personal detail is left, regardless of whose it is.
    body = TAX_ID.sub("[REDACTED TAX ID]", body)
    body = EMAIL.sub("[REDACTED EMAIL]", body)
    body = PHONE.sub("[REDACTED PHONE]", body)
    return body
