"""Same rail, written as a callable object with its rules in one table."""
import base64
import re
import unicodedata

TABLE = [
    ("instruction override", r"\b(?:ignore|disregard|forget|override)\b[^.!?]{0,40}\b(?:instruction|configuration|config|rule|prompt)|\b(?:you|we|i) (?:are|am) (?:now )?(?:in|running in|switching to)\b[^.!?]{0,24}\bmode\b|\byou are now\b"),
    ("prompt extraction", r"\b(?:repeat|print|read back|output)\b[^.!?]{0,60}\b(?:above|everything|instruction|configuration|config|prompt)|internal[\s_-]*api[\s_-]*key"),
    ("refusal suppression", r"\bdo not (?:mention|refuse)\b|\b(?:begin|start|open) your (?:reply|answer) with\b|\b(?:no|without) commentary\b"),
]
COMPILED = [(label, re.compile(pattern)) for label, pattern in TABLE]


class InputRail:
    def _views(self, text):
        yield "as written", text
        folded = unicodedata.normalize("NFKC", text)
        if folded != text:
            yield "after normalisation", folded
        for token in re.findall(r"[A-Za-z0-9+/]{16,}={0,2}", folded):
            try:
                decoded = base64.b64decode(token, validate=True).decode("ascii")
            except Exception:
                continue
            if decoded.isprintable():
                yield "inside an encoded payload", decoded

    def __call__(self, text, ctx):
        for view, body in self._views(text or ""):
            low = body.lower()
            for label, rule in COMPILED:
                if rule.search(low):
                    return False, "input rail: %s %s" % (label, view)
        return True, ""


input_rail = InputRail()
