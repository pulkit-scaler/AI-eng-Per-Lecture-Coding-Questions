"""Alternative shape 5 - partials, a three-message conversation, per-table schema.

Materially different from the reference:
  * every model turn is a THREE message conversation (system, an assistant
    acknowledgement, then the user body), so the message list is not the two
    message shape any other candidate uses;
  * the schema is built per table with list_tables and get_table_schema rather
    than by the one-call summary helper;
  * guard callables are pre-bound with functools.partial and fanned out over a
    pool sized to the number of guards plus a spare worker;
  * the dispatch table is keyed by category and holds (desk, label) pairs;
  * refinement feedback is passed as a single pre-joined block built by a helper.
"""
import json
from concurrent.futures import ThreadPoolExecutor, as_completed
from functools import partial

from grid_kit import (CRITIQUE_SYSTEM_PROMPT, DRAFT_SYSTEM_PROMPT, GUARD_NAMES,
                     GUARD_PROMPTS, MODEL, REFINE_SYSTEM_PROMPT,
                     ROUTE_SYSTEM_PROMPT, execute_sql, get_table_schema,
                     handle_capacity_check, handle_load_trend,
                     handle_outage_lookup, handle_schema_help, list_tables,
                     make_client)

CLIENT = make_client()


def schema_block():
    rows = []
    for table in list_tables():
        rows.append("  %s(%s)" % (table, ", ".join(get_table_schema(table))))
    return "\n".join(rows)


SCHEMA = schema_block()

DESK_TABLE = {
    "outage_lookup": (handle_outage_lookup, "interruptions"),
    "capacity_check": (handle_capacity_check, "ratings"),
    "load_trend": (handle_load_trend, "demand"),
    "schema_help": (handle_schema_help, "register"),
}


def converse(system_prompt, body):
    reply = CLIENT.chat.completions.create(
        model=MODEL, temperature=0.0,
        messages=[
            {"role": "system", "content": system_prompt},
            {"role": "assistant", "content": "Ready."},
            {"role": "user", "content": body},
        ])
    text = (reply.choices[0].message.content or "").strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[-1].rsplit("```", 1)[0].strip()
    return text


def as_verdict(system_prompt, body, default):
    try:
        value = json.loads(converse(system_prompt, body))
    except (json.JSONDecodeError, TypeError):
        return dict(default)
    return value if isinstance(value, dict) else dict(default)


def as_query(system_prompt, body):
    return converse(system_prompt, body).rstrip(";").strip()


def feedback_block(reason, db_error, memory):
    lines = []
    if reason:
        lines.append("Reviewer feedback: %s" % reason)
    if db_error:
        lines.append("Database execution error: %s" % db_error)
    if memory:
        lines.append("Previous corrections (learn from these):")
        for entry in memory[-3:]:
            lines.append("  Question: %s" % entry["question"])
            lines.append("  Bad SQL: %s" % entry["failed_sql"])
            lines.append("  Error: %s" % entry["error"])
    return "\n".join(lines) or "General quality issues detected."


def critique_query(question, candidate_sql):
    got = as_verdict(CRITIQUE_SYSTEM_PROMPT,
                     "Question: %s\n\nSchema:\n%s\n\nCandidate SQL: %s\n"
                     % (question, SCHEMA, candidate_sql),
                     {"valid": False, "reason": "no verdict returned"})
    return {"valid": got.get("valid") in (True, "true", "True"),
            "reason": str(got.get("reason", ""))}


def _first(question):
    return as_query(DRAFT_SYSTEM_PROMPT,
                    "Question: %s\n\nSchema:\n%s\n" % (question, SCHEMA))


def _next(question, sql, reason="", db_error="", memory=None):
    return as_query(REFINE_SYSTEM_PROMPT,
                    "Question: %s\n\nSchema:\n%s\n\nOriginal SQL: %s\n\n"
                    "Feedback:\n%s\n\nWrite the corrected query."
                    % (question, SCHEMA, sql,
                       feedback_block(reason, db_error, memory or [])))


def self_improving_query(question, max_attempts):
    sql = _first(question)
    reviewed = 0
    reason = ""
    while reviewed < max_attempts:
        verdict = critique_query(question, sql)
        reviewed += 1
        reason = verdict["reason"]
        if verdict["valid"]:
            break
        if reviewed == max_attempts:
            return {"sql": sql, "result": None, "attempts": reviewed,
                    "accepted": False, "reason": reason}
        sql = _next(question, sql, reason=reason)
    return {"sql": sql, "result": execute_sql(sql), "attempts": reviewed,
            "accepted": True, "reason": reason}


def execute_with_feedback(question, max_attempts):
    sql = _first(question)
    memory = []
    runs = 0
    while runs < max_attempts:
        outcome = execute_sql(sql)
        runs += 1
        if not outcome.startswith("ERROR:"):
            return {"sql": sql, "result": outcome, "attempts": runs,
                    "succeeded": True, "error_memory": memory}
        memory = memory + [{"question": question, "failed_sql": sql,
                            "error": outcome.split(":", 1)[1].strip()}]
        if runs == max_attempts:
            break
        sql = _next(question, sql, db_error=memory[-1]["error"], memory=memory)
    return {"sql": sql, "result": None, "attempts": runs, "succeeded": False,
            "error_memory": memory}


def route_request(request):
    got = as_verdict(ROUTE_SYSTEM_PROMPT, "Request: %s" % request,
                     {"category": "schema_help"})
    category = str(got.get("category") or "schema_help")
    entry = DESK_TABLE.get(category)
    if entry is None:
        return {"category": category, "result": ""}
    desk, _label = entry
    return {"category": category, "result": desk(request)}


def _guard_call(name, candidate_sql):
    got = as_verdict(GUARD_PROMPTS[name],
                     "Candidate SQL: %s\n" % candidate_sql,
                     {"guard": name, "passes": False, "reason": "no verdict"})
    return {"guard": str(got.get("guard") or name),
            "passes": got.get("passes") in (True, "true", "True"),
            "reason": str(got.get("reason", ""))}


def parallel_guards(candidate_sql):
    calls = [partial(_guard_call, name, candidate_sql) for name in GUARD_NAMES]
    guards = []
    with ThreadPoolExecutor(max_workers=len(calls) + 1) as pool:
        for future in as_completed([pool.submit(call) for call in calls]):
            guards.append(future.result())
    failed = sorted(item["guard"] for item in guards if not item["passes"])
    return {"blocked": failed != [], "blocked_by": failed, "guards": guards}
