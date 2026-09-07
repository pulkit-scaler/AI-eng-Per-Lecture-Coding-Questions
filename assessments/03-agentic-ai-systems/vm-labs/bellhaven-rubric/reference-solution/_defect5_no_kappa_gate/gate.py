#!/usr/bin/env python3
"""Run the whole evaluation and decide whether the build may ship."""
import argparse
import json
import os
import sys

from eval_kit import FAMILIES, bucket_of, load_pool
from harness.dataset import build_golden
from harness.ensemble import cohen_kappa, ensemble, observed_agreement
from harness.judge import judge_prediction
from harness.metrics import exact_match, symbolic_match


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pool", required=True)
    parser.add_argument("--out", default="reports/eval.json")
    parser.add_argument("--size", type=int, default=12)
    parser.add_argument("--per-bucket", type=int, default=3)
    parser.add_argument("--seed", type=int, default=0)
    parser.add_argument("--baseline", type=float, default=0.5)
    parser.add_argument("--min-kappa", type=float, default=0.6)
    options = parser.parse_args()

    pool = load_pool(options.pool)
    golden = build_golden(pool, options.size, options.per_bucket, options.seed)

    exact = [exact_match(r["predicted_answer"], r["gold_answer"]) for r in golden]
    symbolic = [symbolic_match(r["predicted_answer"], r["gold_answer"])
                for r in golden]

    judged = {}
    for family in FAMILIES:
        judged[family] = [judge_prediction(record, family) for record in golden]
    first = [j["correct"] for j in judged[FAMILIES[0]]]
    second = [j["correct"] for j in judged[FAMILIES[1]]]

    resolved, review = ensemble(first, second)
    kappa = cohen_kappa(first, second)
    agreement = observed_agreement(first, second)

    settled = [v for v in resolved if v is not None]
    strict = (sum(settled) / float(len(resolved))) if resolved else 0.0

    buckets = {}
    for record in golden:
        key = "%s/%s" % bucket_of(record)
        buckets[key] = buckets.get(key, 0) + 1

    reasons = []
    if strict < options.baseline:
        reasons.append(
            "accuracy %.3f is below the baseline of %.3f"
            % (strict, options.baseline))

    report = {
        "dataset": {"size": len(golden), "buckets": buckets,
                    "ids": [r["id"] for r in golden]},
        "metrics": {
            "exact_match": sum(exact) / float(len(exact)) if exact else 0.0,
            "symbolic_match": (sum(symbolic) / float(len(symbolic))
                               if symbolic else 0.0),
            "judge_%s" % FAMILIES[0]: (sum(first) / float(len(first))
                                       if first else 0.0),
            "judge_%s" % FAMILIES[1]: (sum(second) / float(len(second))
                                       if second else 0.0),
            "ensemble_strict": strict,
        },
        "agreement": {"kappa": kappa, "observed": agreement},
        "review_queue": [golden[i]["id"] for i in review],
        "gate": {"passed": not reasons, "reasons": reasons},
    }

    directory = os.path.dirname(options.out)
    if directory:
        os.makedirs(directory, exist_ok=True)
    with open(options.out, "w") as handle:
        json.dump(report, handle, indent=2)

    print("LABJSON:" + json.dumps({
        "size": len(golden),
        "exact_match": report["metrics"]["exact_match"],
        "symbolic_match": report["metrics"]["symbolic_match"],
        "ensemble_strict": strict,
        "kappa": kappa,
        "observed": agreement,
        "review": report["review_queue"],
        "passed": not reasons,
        "reasons": reasons,
    }))
    return 0 if not reasons else 1


if __name__ == "__main__":
    sys.exit(main())
