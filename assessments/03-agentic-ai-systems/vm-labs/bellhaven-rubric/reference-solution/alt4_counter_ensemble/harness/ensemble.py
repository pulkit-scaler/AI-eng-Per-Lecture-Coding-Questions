"""Same three functions built on Counter and a confusion table."""
from collections import Counter


def observed_agreement(first, second):
    pairs = list(zip(first, second))
    if not pairs:
        return float("nan")
    return Counter(a == b for a, b in pairs)[True] / float(len(pairs))


def cohen_kappa(first, second):
    a = Counter(int(x) for x in first)
    b = Counter(int(x) for x in second)
    total = float(sum(a.values()))
    if not total or sum(b.values()) != total:
        return None
    if len(a) < 2 or len(b) < 2:
        return None
    po = observed_agreement(first, second)
    pe = sum((a[label] / total) * (b[label] / total)
             for label in set(a) | set(b))
    if pe >= 1.0:
        return None
    return (po - pe) / (1.0 - pe)


def ensemble(first, second):
    resolved = [int(a) if int(a) == int(b) else None
                for a, b in zip(first, second)]
    review = [index for index, value in enumerate(resolved) if value is None]
    return resolved, review
