"""Stage 3: one model grading one prediction.

This file is not written yet - it is yours to write.

    build_judge_prompt(record) -> str
    parse_judge_response(text) -> dict
    judge_prediction(record, family) -> dict
"""


def build_judge_prompt(record):
    raise NotImplementedError("write build_judge_prompt in harness/judge.py")


def parse_judge_response(text):
    raise NotImplementedError("write parse_judge_response in harness/judge.py")


def judge_prediction(record, family):
    raise NotImplementedError("write judge_prediction in harness/judge.py")
