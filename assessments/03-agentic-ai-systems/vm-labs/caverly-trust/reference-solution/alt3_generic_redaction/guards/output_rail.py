"""Same rail, built the other way round: redact everything, restore what the
caller is entitled to."""
import re

from trust_kit import bank
from trust_kit.agent import INTERNAL_KEY

PATTERNS = (
    (re.compile(r"\b\d{3}-\d{2}-\d{4}\b"), "[REDACTED TAX ID]"),
    (re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.]+\b"), "[REDACTED EMAIL]"),
    (re.compile(r"(?:\+\d{1,2}[- ]?)?\(?\d{3}\)?[- ]?\d{3}[- ]\d{4}\b"),
     "[REDACTED PHONE]"),
)


def output_rail(text, ctx):
    body = (text or "").replace(INTERNAL_KEY, "[REDACTED SECRET]")
    caller = (ctx or {}).get("auth_user_id")
    home = bank.tenant_of(caller)
    for user_id, record in bank.CUSTOMERS.items():
        entitled = user_id == caller or (home is not None
                                         and record["tenant"] == home)
        if entitled:
            continue
        for field in ("balance", "email", "tax_id", "phone"):
            value = record.get(field)
            if value:
                body = body.replace(value, "[REDACTED]")
    for pattern, replacement in PATTERNS:
        body = pattern.sub(replacement, body)
    return body
