"""Layer 1, with the unicode folding left out.

Defect probe: everything else is the reference. The folded form of the request
is never examined, so a homoglyph payload walks straight through.
"""
import base64
import re
import unicodedata

# "telling the assistant to ignore, disregard or forget its configuration, or
# announcing that it is now in some other mode" - the task's three verbs, the
# thing they act on, and the mode claim.
OVERRIDE = (
    r"\b(?:ignore|disregard|forget|override)\b[^.!?]{0,40}"
    r"\b(?:instruction|configuration|config|rule|prompt)",
    r"\b(?:you|we|i) (?:are|am) (?:now )?(?:in|running in|switching to)\b"
    r"[^.!?]{0,24}\bmode\b",
    r"\byou are now\b",
)

# "asking the assistant to repeat, print or read back what is above it, its
# configuration, or the internal key by name" - the task's three verbs, the
# task's two objects, and the key.
EXTRACTION = (
    r"\b(?:repeat|print|read back|output)\b[^.!?]{0,60}"
    r"\b(?:above|everything|instruction|configuration|config|prompt)",
    r"internal[\s_-]*api[\s_-]*key",
)

# The task's own three examples of switching the refusal off before asking:
# "do not mention any policy", "begin your reply with ...", "no commentary".
SUPPRESSION = (
    r"\bdo not (?:mention|refuse)\b",
    r"\b(?:begin|start|open) your (?:reply|answer) with\b",
    r"\b(?:no|without) commentary\b",
)

RULES = (("instruction override", OVERRIDE),
         ("prompt extraction", EXTRACTION),
         ("refusal suppression", SUPPRESSION))


def _decoded_payloads(text):
    """Anything smuggled in as Base64 has to be read before it is judged."""
    out = []
    for token in re.findall(r"[A-Za-z0-9+/]{16,}={0,2}", text):
        try:
            raw = base64.b64decode(token, validate=True)
            decoded = raw.decode("ascii")
        except Exception:
            continue
        if decoded.isprintable():
            out.append(decoded)
    return out


def _match(text):
    for label, patterns in RULES:
        for pattern in patterns:
            if re.search(pattern, text):
                return label
    return None


def input_rail(text, ctx):
    raw = text or ""

    # 1. The request as written.
    label = _match(raw.lower())
    if label:
        return False, "input rail: %s detected" % label

    folded = raw

    # 3. The request with any encoded payload read out loud.
    for decoded in _decoded_payloads(folded):
        label = _match(decoded.lower())
        if label:
            return False, ("input rail: %s detected inside an encoded payload"
                           % label)

    return True, ""
