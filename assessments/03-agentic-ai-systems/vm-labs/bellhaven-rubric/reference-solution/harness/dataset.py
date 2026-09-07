"""Stage 1: build the golden set."""
import random

from eval_kit import bucket_of


def build_golden(pool, size, per_bucket, seed=0):
    """Stratified sample of `size` records, at most `per_bucket` per stratum.

    Every stress test in the pool is kept whatever the caps say: they are the
    failure modes somebody wrote down on purpose, and a sample that drops them
    is measuring the easy half of the problem.
    """
    stress = [r for r in pool if r.get("is_stress_test")]
    ordinary = [r for r in pool if not r.get("is_stress_test")]

    rng = random.Random(seed)
    shuffled = list(ordinary)
    rng.shuffle(shuffled)

    # Round-robin over the strata so the sample spreads across as many as it
    # can before it starts taking a second one from any of them.
    buckets = {}
    for record in shuffled:
        buckets.setdefault(bucket_of(record), []).append(record)
    order = sorted(buckets, key=lambda key: (str(key[0]), key[1]))

    chosen = list(stress)
    taken = {}
    for record in stress:
        key = bucket_of(record)
        taken[key] = taken.get(key, 0) + 1

    round_index = 0
    while len(chosen) < size:
        added = 0
        for key in order:
            if len(chosen) >= size:
                break
            if round_index >= len(buckets[key]):
                continue
            if taken.get(key, 0) >= per_bucket:
                continue
            chosen.append(buckets[key][round_index])
            taken[key] = taken.get(key, 0) + 1
            added += 1
        if added == 0:
            break
        round_index += 1

    return chosen[:size] if len(chosen) > size else chosen
