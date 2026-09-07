"""Same stratified sample with no randomness at all: a stable ordering."""
from eval_kit import bucket_of


def build_golden(pool, size, per_bucket, seed=0):
    stress = [r for r in pool if r.get("is_stress_test")]
    chosen = list(stress)
    taken = {}
    for record in stress:
        taken[bucket_of(record)] = taken.get(bucket_of(record), 0) + 1

    ordinary = sorted((r for r in pool if not r.get("is_stress_test")),
                      key=lambda r: (str(r.get("subject")), r.get("level"),
                                     str(r.get("id"))))
    grouped = {}
    for record in ordinary:
        grouped.setdefault(bucket_of(record), []).append(record)

    depth = 0
    while len(chosen) < size:
        progressed = False
        for key in sorted(grouped, key=lambda k: (str(k[0]), k[1])):
            if len(chosen) >= size:
                break
            if depth >= len(grouped[key]) or taken.get(key, 0) >= per_bucket:
                continue
            chosen.append(grouped[key][depth])
            taken[key] = taken.get(key, 0) + 1
            progressed = True
        if not progressed:
            break
        depth += 1
    return chosen[:size]
