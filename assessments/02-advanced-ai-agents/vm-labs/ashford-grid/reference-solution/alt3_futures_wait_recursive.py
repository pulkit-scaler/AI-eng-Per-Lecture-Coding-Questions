"""Alternative shape 3 - futures.wait, a recursive loop, registry-by-name dispatch.

Materially different from the reference:
  * the guard fan-out uses concurrent.futures.wait(ALL_COMPLETED) rather than
    as_completed or map;
  * the review-and-refine loop is written as recursion with a countdown rather
    than an iterative while;
  * the dispatch table is built once by looking each desk up by its own name in a
    registry dict, so adding a category needs no new branch;
  * the guard aggregate is assembled from a dict keyed by guard name.
"""
import json
from concurrent.futures import ALL_COMPLETED, ThreadPoolExecutor, wait

from grid_kit import (CRITIQUE_SYSTEM_PROMPT, DRAFT_SYSTEM_PROMPT, GUARD_NAMES,
                      GUARD_PROMPTS, MODEL, REFINE_SYSTEM_PROMPT,
                      ROUTE_SYSTEM_PROMPT, execute_sql, handle_capacity_check,
                      handle_load_trend, handle_outage_lookup,
                      handle_schema_help, make_client, schema_summary)

REGISTRY = {
    "handle_outage_lookup": handle_outage_lookup,
    "handle_capacity_check": handle_capacity_check,
    "handle_load_trend": handle_load_trend,
    "handle_schema_help": handle_schema_help,
}
DESKS = {name[len("handle_"):]: fn for name, fn in REGISTRY.items()}

_STATE = {}


def _client():
    if "client" not in _STATE:
        _STATE["client"] = make_client()
    return _STATE["client"]


def _schema():
    if "schema" not in _STATE:
        _STATE["schema"] = schema_summary()
    return _STATE["schema"]


def speak(role, body):
    reply = _client().chat.completions.create(
        model=MODEL, temperature=0.0,
        messages=[{"role": "system", "content": role},
                  {"role": "user", "content": body}])
    text = (reply.choices[0].message.content or "").strip()
    while text.startswith("```"):
        text = text.split("\n", 1)[-1].rsplit("```", 1)[0].strip()
    return text


def verdict_of(role, body, default):
    try:
        value = json.loads(speak(role, body))
        if isinstance(value, dict):
            return value
    except (json.JSONDecodeError, TypeError):
        pass
    return dict(default)


def critique_query(question, candidate_sql):
    got = verdict_of(CRITIQUE_SYSTEM_PROMPT,
                     "Question: {0}\n\nSchema:\n{1}\n\nCandidate SQL: {2}"
                     .format(question, _schema(), candidate_sql),
                     {"valid": False, "reason": "unavailable"})
    return {"valid": bool(got.get("valid")),
            "reason": str(got.get("reason", ""))}


def first_draft(question):
    return speak(DRAFT_SYSTEM_PROMPT,
                 "Question: {0}\n\nSchema:\n{1}\n\nWrite the query."
                 .format(question, _schema())).rstrip(";").strip()


def corrected(question, sql, reason="", db_error="", memory=None):
    lines = ["Question: {0}".format(question),
             "Schema:\n{0}".format(_schema()),
             "Original SQL: {0}".format(sql)]
    if reason:
        lines.append("Reviewer feedback: {0}".format(reason))
    if db_error:
        lines.append("Database execution error: {0}".format(db_error))
    if memory:
        lines.append("Previous corrections (learn from these):")
        lines.extend("  {0} was rejected with {1}".format(item["failed_sql"],
                                                          item["error"])
                      for item in memory[-3:])
    return speak(REFINE_SYSTEM_PROMPT, "\n\n".join(lines)).rstrip(";").strip()


def _improve(question, sql, budget, used):
    review = critique_query(question, sql)
    used += 1
    if review["valid"]:
        return {"sql": sql, "result": execute_sql(sql), "attempts": used,
                "accepted": True, "reason": review["reason"]}
    if used >= budget:
        return {"sql": sql, "result": None, "attempts": used,
                "accepted": False, "reason": review["reason"]}
    return _improve(question, corrected(question, sql, reason=review["reason"]),
                    budget, used)


def self_improving_query(question, max_attempts):
    return _improve(question, first_draft(question), max_attempts, 0)


def execute_with_feedback(question, max_attempts):
    sql = first_draft(question)
    memory = []
    runs = 0
    while runs < max_attempts:
        outcome = execute_sql(sql)
        runs += 1
        if not outcome.startswith("ERROR:"):
            return {"sql": sql, "result": outcome, "attempts": runs,
                    "succeeded": True, "error_memory": memory}
        memory.append({"question": question, "failed_sql": sql,
                       "error": outcome.replace("ERROR:", "", 1).strip()})
        if runs >= max_attempts:
            break
        sql = corrected(question, sql, db_error=memory[-1]["error"],
                        memory=memory)
    return {"sql": sql, "result": None, "attempts": runs, "succeeded": False,
            "error_memory": memory}


def route_request(request):
    got = verdict_of(ROUTE_SYSTEM_PROMPT, "Request: {0}".format(request),
                     {"category": "schema_help"})
    category = str(got.get("category") or "schema_help")
    desk = DESKS.get(category)
    return {"category": category,
            "result": desk(request) if desk is not None else ""}


def _ask_guard(name, candidate_sql):
    got = verdict_of(GUARD_PROMPTS[name],
                     "Candidate SQL: {0}".format(candidate_sql),
                     {"guard": name, "passes": False, "reason": "silent"})
    return name, {"guard": str(got.get("guard") or name),
                  "passes": bool(got.get("passes")),
                  "reason": str(got.get("reason", ""))}


def parallel_guards(candidate_sql):
    with ThreadPoolExecutor(max_workers=len(GUARD_NAMES)) as pool:
        futures = [pool.submit(_ask_guard, name, candidate_sql)
                   for name in GUARD_NAMES]
        done, _ = wait(futures, return_when=ALL_COMPLETED)
    by_name = dict(future.result() for future in done)
    failed = sorted(name for name, item in by_name.items()
                    if not item["passes"])
    return {"blocked": bool(failed), "blocked_by": failed,
            "guards": [by_name[name] for name in sorted(by_name)]}
