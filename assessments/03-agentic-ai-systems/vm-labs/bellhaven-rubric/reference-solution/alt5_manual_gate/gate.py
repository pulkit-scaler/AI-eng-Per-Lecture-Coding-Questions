#!/usr/bin/env python3
"""Same gate, hand-rolled arguments and a slightly different report layout."""
import json
import os
import sys

from eval_kit import FAMILIES, bucket_of, load_pool
from harness.dataset import build_golden
from harness.ensemble import cohen_kappa, ensemble, observed_agreement
from harness.judge import judge_prediction
from harness.metrics import exact_match, symbolic_match

DEFAULTS = {"--pool": None, "--out": "reports/eval.json", "--size": "12",
            "--per-bucket": "3", "--seed": "0", "--baseline": "0.5",
            "--min-kappa": "0.6"}


def options():
    chosen = dict(DEFAULTS)
    argv = sys.argv[1:]
    for index, token in enumerate(argv):
        if token in chosen and index + 1 < len(argv):
            chosen[token] = argv[index + 1]
    return chosen


def main():
    chosen = options()
    if not chosen["--pool"]:
        print("usage: gate.py --pool FILE [--out FILE]")
        return 2

    golden = build_golden(load_pool(chosen["--pool"]), int(chosen["--size"]),
                          int(chosen["--per-bucket"]), int(chosen["--seed"]))
    scored = {
        "exact_match": [exact_match(r["predicted_answer"], r["gold_answer"])
                        for r in golden],
        "symbolic_match": [symbolic_match(r["predicted_answer"],
                                          r["gold_answer"]) for r in golden],
    }
    graders = {family: [judge_prediction(r, family)["correct"] for r in golden]
               for family in FAMILIES}
    first, second = graders[FAMILIES[0]], graders[FAMILIES[1]]
    resolved, review = ensemble(first, second)
    kappa = cohen_kappa(first, second)
    strict = sum(v for v in resolved if v) / float(len(resolved) or 1)

    baseline = float(chosen["--baseline"])
    floor = float(chosen["--min-kappa"])
    reasons = []
    if strict < baseline:
        reasons.append("ensemble accuracy %.3f below baseline %.3f"
                       % (strict, baseline))
    if kappa is None:
        reasons.append("kappa is undefined so grader agreement cannot be "
                       "trusted")
    elif kappa < floor:
        reasons.append("kappa %.3f below the required agreement floor %.3f"
                       % (kappa, floor))

    metrics = {name: sum(values) / float(len(values) or 1)
               for name, values in scored.items()}
    metrics["ensemble_strict"] = strict
    for family in FAMILIES:
        metrics["judge_%s" % family] = (sum(graders[family])
                                        / float(len(golden) or 1))

    buckets = {}
    for record in golden:
        buckets["%s/%s" % bucket_of(record)] = \
            buckets.get("%s/%s" % bucket_of(record), 0) + 1

    report = {
        "dataset": {"size": len(golden), "ids": [r["id"] for r in golden],
                    "buckets": buckets},
        "metrics": metrics,
        "agreement": {"kappa": kappa,
                      "observed": observed_agreement(first, second)},
        "review_queue": [golden[i]["id"] for i in review],
        "gate": {"passed": not reasons, "reasons": reasons},
        "thresholds": {"baseline": baseline, "min_kappa": floor},
    }
    os.makedirs(os.path.dirname(chosen["--out"]) or ".", exist_ok=True)
    with open(chosen["--out"], "w") as handle:
        handle.write(json.dumps(report, indent=2))
    print("LABJSON:" + json.dumps({
        "size": len(golden), "ensemble_strict": strict, "kappa": kappa,
        "observed": report["agreement"]["observed"],
        "exact_match": metrics["exact_match"],
        "symbolic_match": metrics["symbolic_match"],
        "review": report["review_queue"], "passed": not reasons,
        "reasons": reasons}))
    return 1 if reasons else 0


if __name__ == "__main__":
    sys.exit(main())
