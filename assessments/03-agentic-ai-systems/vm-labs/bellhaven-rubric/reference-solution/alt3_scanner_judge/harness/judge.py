"""Same three steps, parsing by scanning for a decodable object rather than by
pattern, and laying the prompt out in a different order."""
import json

from eval_kit import ask_judge

FIELDS = ("correct", "reasoning_quality", "used_tool_appropriately",
          "explanation")
RUBRIC = ("Score the submission against the reference answer and reply with a "
          "JSON object holding correct (1 or 0), reasoning_quality (1 to 5), "
          "used_tool_appropriately (1 or 0) and explanation (one sentence). "
          "Reply with the JSON object only.")


def build_judge_prompt(record):
    steps = []
    for index, step in enumerate(record.get("trace") or [], 1):
        pieces = ["Step %d:" % index]
        for key in ("thought", "action", "action_input", "observation",
                    "final_answer"):
            if step.get(key):
                pieces.append("%s: %s" % (key, step[key]))
        steps.append("  ".join(pieces))
    return (
        "Submission for grading\n"
        "======================\n"
        "Problem: %s\n"
        "Submitted answer: %s\n"
        "Reference answer: %s\n"
        "Working:\n%s\n\n%s"
        % (record.get("problem", ""), record.get("predicted_answer"),
           record.get("gold_answer"),
           "\n".join(steps) or "  none recorded", RUBRIC))


def parse_judge_response(text):
    body = text or ""
    decoder = json.JSONDecoder()
    for index, character in enumerate(body):
        if character != "{":
            continue
        try:
            payload, _ = decoder.raw_decode(body[index:])
        except ValueError:
            continue
        if not isinstance(payload, dict):
            continue
        return {
            "correct": int(payload.get("correct", 0) or 0),
            "reasoning_quality": int(payload.get("reasoning_quality", 3) or 3),
            "used_tool_appropriately":
                int(payload.get("used_tool_appropriately", 0) or 0),
            "explanation": str(payload.get("explanation", "")),
        }
    return {"correct": 0, "reasoning_quality": 1,
            "used_tool_appropriately": 0,
            "explanation": "PARSE_ERROR: no JSON object in the reply",
            "raw": body[:200]}


def judge_prediction(record, family):
    try:
        return parse_judge_response(ask_judge(family,
                                              build_judge_prompt(record)))
    except Exception as exc:
        return {"correct": 0, "reasoning_quality": 1,
                "used_tool_appropriately": 0,
                "explanation": "CALL_ERROR: %s" % exc}
