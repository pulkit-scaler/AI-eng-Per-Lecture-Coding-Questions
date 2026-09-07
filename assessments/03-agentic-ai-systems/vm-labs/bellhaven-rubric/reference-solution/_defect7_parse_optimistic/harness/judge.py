"""Stage 3: one model grading one prediction."""
import json
import re

from eval_kit import ask_judge

RUBRIC = """You are an expert mathematics grader. Score the submission against
the reference answer.

Return a JSON object with these fields:
- "correct": 1 if the final answer is mathematically equivalent to the
  reference answer, allowing for equivalent forms such as 0.5 and 1/2, else 0
- "reasoning_quality": integer 1 to 5, where 1 is incoherent working and 5 is
  clear and correct working
- "used_tool_appropriately": 1 if the calculator was reached for when it was
  needed and used correctly, else 0
- "explanation": one sentence explaining the grade

Return only the JSON object."""

DEFAULTS = {"correct": 1, "reasoning_quality": 3,
            "used_tool_appropriately": 1, "explanation": ""}


def _render_trace(trace):
    if not trace:
        return " (no trace available)"
    lines = []
    for index, step in enumerate(trace, 1):
        lines.append("\nStep %d:" % index)
        if step.get("thought"):
            lines.append("  Thought: %s" % step["thought"])
        if step.get("action"):
            lines.append("  Action: %s(%s)"
                         % (step["action"], step.get("action_input", "")))
        if step.get("observation"):
            lines.append("  Observation: %s" % step["observation"])
        if step.get("final_answer"):
            lines.append("  Final Answer: %s" % step["final_answer"])
    return "\n".join(lines)


def build_judge_prompt(record):
    """Everything the grader needs, and nothing it has to guess."""
    return "\n".join([
        RUBRIC,
        "",
        "Problem:",
        str(record.get("problem", "")),
        "",
        "Reference answer: %s" % record.get("gold_answer"),
        "",
        "Submitted answer: %s" % record.get("predicted_answer"),
        "",
        "Working:%s" % _render_trace(record.get("trace")),
        "",
        "Grade according to the rubric.",
    ])


def parse_judge_response(text):
    """Pull the JSON out of a reply that may be fenced, prefaced, or absent."""
    body = (text or "").strip()
    match = re.search(r"```(?:json)?\s*(\{.*?\})\s*```", body, re.S)
    if match:
        body = match.group(1)
    else:
        match = re.search(r"\{.*\}", body, re.S)
        if match:
            body = match.group(0)
    try:
        payload = json.loads(body)
        return {
            "correct": int(payload.get("correct", 0)),
            "reasoning_quality": int(payload.get("reasoning_quality", 3)),
            "used_tool_appropriately":
                int(payload.get("used_tool_appropriately", 0)),
            "explanation": str(payload.get("explanation", "")),
        }
    except Exception as exc:
        result = dict(DEFAULTS)
        result["explanation"] = "PARSE_ERROR: %s" % exc
        result["raw"] = (text or "")[:200]
        return result


def judge_prediction(record, family):
    """Ask one family for a grade and return it in the rubric shape."""
    try:
        reply = ask_judge(family, build_judge_prompt(record))
    except Exception as exc:
        result = dict(DEFAULTS)
        result["explanation"] = "CALL_ERROR: %s" % exc
        return result
    return parse_judge_response(reply)
