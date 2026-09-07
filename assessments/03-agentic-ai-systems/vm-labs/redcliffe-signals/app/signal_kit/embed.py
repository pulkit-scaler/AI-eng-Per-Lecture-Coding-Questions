"""Turning a note into a vector.

Provided, do not modify. `embed(text)` returns a list of 64 floats. The same
text always gives the same vector, and two notes about the same thing land
closer together than two notes about different things.

This is the only vectoriser on the machine: there is no numpy here, so anything
you do with these vectors is arithmetic you write yourself.
"""
import hashlib
import math
import re

DIMENSIONS = 64
_TOKEN = re.compile(r"[a-z0-9][a-z0-9-]*")


def tokens(text):
    """The words of a note, lowercased, in order."""
    return _TOKEN.findall((text or "").lower())


def embed(text):
    """A unit-length vector of DIMENSIONS floats for this text."""
    vector = [0.0] * DIMENSIONS
    for token in tokens(text):
        digest = hashlib.sha256(token.encode("utf-8")).digest()
        for offset in range(4):
            index = digest[offset] % DIMENSIONS
            sign = 1.0 if digest[offset + 4] % 2 == 0 else -1.0
            vector[index] += sign
    length = math.sqrt(sum(value * value for value in vector))
    if length == 0.0:
        return vector
    return [value / length for value in vector]
