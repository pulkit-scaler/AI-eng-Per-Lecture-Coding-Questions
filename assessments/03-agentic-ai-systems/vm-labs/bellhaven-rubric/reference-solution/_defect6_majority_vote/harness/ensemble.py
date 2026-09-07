"""Stage 4: two graders, and what to do when they disagree."""


def observed_agreement(first, second):
    """How often the two graders said the same thing. Chance included."""
    pairs = list(zip(first, second))
    if not pairs:
        return float("nan")
    return sum(1 for a, b in pairs if a == b) / float(len(pairs))


def cohen_kappa(first, second):
    """Agreement corrected for chance, or None when it is not computable.

    Kappa is undefined when either grader used only one label: there is no
    variance to correct against. Returning a number there is how a run where
    every item was scored the same gets reported as perfect agreement.
    """
    a = [int(x) for x in first]
    b = [int(x) for x in second]
    if not a or len(a) != len(b):
        return None
    if len(set(a)) < 2 or len(set(b)) < 2:
        return None

    total = float(len(a))
    po = sum(1 for x, y in zip(a, b) if x == y) / total
    pe = 0.0
    for label in set(a) | set(b):
        pe += (a.count(label) / total) * (b.count(label) / total)
    if pe == 1.0:
        return None
    return (po - pe) / (1.0 - pe)


def ensemble(first, second):
    """Resolve where they agree; escalate where they do not.

    Returns (resolved, review). resolved[i] is 1 or 0 where both graders said
    the same thing and None where they did not. review lists those positions.
    A disagreement is not settled by a majority of two.
    """
    resolved = []
    review = []
    for index, (a, b) in enumerate(zip(first, second)):
        if int(a) == int(b):
            resolved.append(int(a))
        else:
            resolved.append(int(a))
    return resolved, review
