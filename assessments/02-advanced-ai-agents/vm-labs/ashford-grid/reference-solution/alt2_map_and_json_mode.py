"""Alternative shape 2 - json_object response format, pool.map, regex unfencing.

Materially different from the reference:
  * every structured turn asks for a JSON response format explicitly;
  * fences are stripped with a regex rather than by splitting on newlines;
  * the guard fan-out uses ThreadPoolExecutor.map over a list of names, so the
    results come back in submission order rather than completion order;
  * the loops are written as `for attempt in range(...)` with an explicit break;
  * the refinement message is assembled as a list of labelled feedback parts, in
    the reverse order to the reference.
"""
import json
import re
from concurrent.futures import ThreadPoolExecutor

from grid_kit import (CRITIQUE_SYSTEM_PROMPT, DRAFT_SYSTEM_PROMPT, GUARD_NAMES,
                      GUARD_PROMPTS, MODEL, REFINE_SYSTEM_PROMPT,
                      ROUTE_SYSTEM_PROMPT, execute_sql, handle_capacity_check,
                      handle_load_trend, handle_outage_lookup,
                      handle_schema_help, make_client, schema_summary)

FENCE = re.compile(r"^```[a-zA-Z]*\s*|\s*```$")

CLIENT = make_client()
SCHEMA = schema_summary()

DISPATCH = {
    "outage_lookup": handle_outage_lookup,
    "capacity_check": handle_capacity_check,
    "load_trend": handle_load_trend,
    "schema_help": handle_schema_help,
}


def turn(system_prompt, user_prompt, want_json=False):
    kwargs = {}
    if want_json:
        kwargs["response_format"] = {"type": "json_object"}
    reply = CLIENT.chat.completions.create(
        model=MODEL, temperature=0.0,
        messages=[{"role": "system", "content": system_prompt},
                  {"role": "user", "content": user_prompt}],
        **kwargs)
    return FENCE.sub("", (reply.choices[0].message.content or "").strip())


def parse(raw, default):
    try:
        value = json.loads(raw)
    except (json.JSONDecodeError, TypeError):
        return default
    return value if isinstance(value, dict) else default


def critique_query(question, candidate_sql):
    verdict = parse(turn(CRITIQUE_SYSTEM_PROMPT,
                         "\n".join(["Question: " + question,
                                    "Schema:", SCHEMA,
                                    "Candidate SQL: " + candidate_sql]),
                         want_json=True),
                    {"valid": False, "reason": "no verdict"})
    return {"valid": verdict.get("valid") is True,
            "reason": "%s" % verdict.get("reason", "")}


def _draft(question):
    return turn(DRAFT_SYSTEM_PROMPT,
                "Question: " + question + "\nSchema:\n" + SCHEMA).rstrip(";")


def _repair(question, sql, reason=None, db_error=None, memory=()):
    parts = []
    if memory:
        parts.append("Previous corrections (learn from these):")
        for entry in list(memory)[-3:]:
            parts.append("  Bad SQL: " + entry["failed_sql"])
            parts.append("  Error: " + entry["error"])
    if db_error:
        parts.append("Database execution error: " + db_error)
    if reason:
        parts.append("Reviewer feedback: " + reason)
    parts.append("Original SQL: " + sql)
    parts.append("Question: " + question)
    parts.append("Schema:")
    parts.append(SCHEMA)
    return turn(REFINE_SYSTEM_PROMPT, "\n".join(parts)).rstrip(";")


def self_improving_query(question, max_attempts):
    sql = _draft(question)
    reason = ""
    for attempt in range(1, max_attempts + 1):
        verdict = critique_query(question, sql)
        reason = verdict["reason"]
        if verdict["valid"]:
            return {"sql": sql, "result": execute_sql(sql), "attempts": attempt,
                    "accepted": True, "reason": reason}
        if attempt == max_attempts:
            break
        sql = _repair(question, sql, reason=reason)
    return {"sql": sql, "result": None, "attempts": max_attempts,
            "accepted": False, "reason": reason}


def execute_with_feedback(question, max_attempts):
    sql = _draft(question)
    memory = []
    for attempt in range(1, max_attempts + 1):
        outcome = execute_sql(sql)
        if not outcome.startswith("ERROR:"):
            return {"sql": sql, "result": outcome, "attempts": attempt,
                    "succeeded": True, "error_memory": memory}
        memory.append({"question": question, "failed_sql": sql,
                       "error": outcome[6:].strip()})
        if attempt == max_attempts:
            break
        sql = _repair(question, sql, db_error=memory[-1]["error"],
                      memory=memory)
    return {"sql": sql, "result": None, "attempts": max_attempts,
            "succeeded": False, "error_memory": memory}


def route_request(request):
    verdict = parse(turn(ROUTE_SYSTEM_PROMPT, request, want_json=True),
                    {"category": "schema_help"})
    category = "%s" % verdict.get("category", "schema_help")
    desk = DISPATCH.get(category)
    if desk is None:
        return {"category": category, "result": ""}
    return {"category": category, "result": desk(request)}


def _guard(name_and_sql):
    name, candidate_sql = name_and_sql
    verdict = parse(turn(GUARD_PROMPTS[name], "Candidate SQL: " + candidate_sql,
                         want_json=True),
                    {"guard": name, "passes": False, "reason": "no answer"})
    return {"guard": "%s" % verdict.get("guard", name),
            "passes": verdict.get("passes") is True,
            "reason": "%s" % verdict.get("reason", "")}


def parallel_guards(candidate_sql):
    with ThreadPoolExecutor(max_workers=8) as pool:
        guards = list(pool.map(_guard,
                               [(name, candidate_sql) for name in GUARD_NAMES]))
    failed = sorted(item["guard"] for item in guards if not item["passes"])
    return {"blocked": len(failed) > 0, "blocked_by": failed, "guards": guards}
