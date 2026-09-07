"""ENVIRONMENT PROBE - the reference with a stall inside route_request.

Expected: TC04 fails at RUN_BUDGET seconds and the other four checks pass, and the
whole run finishes in roughly RUN_BUDGET rather than ten minutes. Never graded by
sweep.sh.

Shape: one thin `llm_call` wrapper over the configured client, one JSON reader and
one SQL reader, then the five deliverables on top.
"""
import json
import time
from concurrent.futures import ThreadPoolExecutor, as_completed
from typing import Any, Dict, List

from grid_kit import (CRITIQUE_SYSTEM_PROMPT, DRAFT_SYSTEM_PROMPT, GUARD_NAMES,
                      GUARD_PROMPTS, MODEL, REFINE_SYSTEM_PROMPT,
                      ROUTE_SYSTEM_PROMPT, execute_sql, handle_capacity_check,
                      handle_load_trend, handle_outage_lookup,
                      handle_schema_help, make_client, schema_summary)

_CLIENT = None


def client():
    global _CLIENT
    if _CLIENT is None:
        _CLIENT = make_client()
    return _CLIENT


def llm_call(system_prompt: str, user_prompt: str) -> str:
    """One model turn: a system prompt and a user prompt in, text out."""
    response = client().chat.completions.create(
        model=MODEL,
        temperature=0.0,
        messages=[{"role": "system", "content": system_prompt},
                  {"role": "user", "content": user_prompt}],
    )
    return (response.choices[0].message.content or "").strip()


def _unfence(raw: str) -> str:
    text = (raw or "").strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[-1]
        text = text.rsplit("```", 1)[0]
    return text.strip()


def _as_json(raw: str, fallback: Dict[str, Any]) -> Dict[str, Any]:
    try:
        parsed = json.loads(_unfence(raw))
    except (json.JSONDecodeError, TypeError):
        return dict(fallback)
    return parsed if isinstance(parsed, dict) else dict(fallback)


def _as_sql(raw: str) -> str:
    return _unfence(raw).rstrip(";").strip()


# ---------------------------------------------------------------------------
# Task 1 - the critique gate
# ---------------------------------------------------------------------------

def critique_query(question: str, candidate_sql: str) -> Dict[str, Any]:
    raw = llm_call(
        CRITIQUE_SYSTEM_PROMPT,
        "Question: %s\n\nSchema:\n%s\n\nCandidate SQL: %s\n\n"
        "Return your verdict as JSON only."
        % (question, schema_summary(), candidate_sql))
    verdict = _as_json(raw, {"valid": False,
                             "reason": "the review could not be read"})
    return {"valid": bool(verdict.get("valid")),
            "reason": str(verdict.get("reason", ""))}


# ---------------------------------------------------------------------------
# shared generator / refiner
# ---------------------------------------------------------------------------

def draft_query(question: str) -> str:
    return _as_sql(llm_call(
        DRAFT_SYSTEM_PROMPT,
        "Question: %s\n\nSchema:\n%s\n\nWrite the query."
        % (question, schema_summary())))


def memory_context(error_memory: List[Dict[str, str]]) -> str:
    if not error_memory:
        return ""
    lines = ["Previous corrections (learn from these):"]
    for entry in error_memory[-3:]:
        lines.append("  Question: %s" % entry.get("question", ""))
        lines.append("  Bad SQL: %s" % entry.get("failed_sql", ""))
        lines.append("  Error: %s" % entry.get("error", ""))
    return "\n".join(lines)


def refine_query(question: str, original_sql: str, reason: str = "",
                 db_error: str = "",
                 error_memory: List[Dict[str, str]] = None) -> str:
    parts = ["Question: %s" % question,
             "Schema:\n%s" % schema_summary(),
             "Original SQL: %s" % original_sql]
    if reason:
        parts.append("Reviewer feedback: %s" % reason)
    if db_error:
        parts.append("Database execution error: %s" % db_error)
    context = memory_context(error_memory or [])
    if context:
        parts.append(context)
    parts.append("Write the corrected query.")
    return _as_sql(llm_call(REFINE_SYSTEM_PROMPT, "\n\n".join(parts)))


# ---------------------------------------------------------------------------
# Task 2 - the evaluator-optimizer loop
# ---------------------------------------------------------------------------

def self_improving_query(question: str, max_attempts: int) -> Dict[str, Any]:
    sql = draft_query(question)
    attempts = 0
    verdict = {"valid": False, "reason": ""}
    while attempts < max_attempts:
        verdict = critique_query(question, sql)
        attempts += 1
        if verdict["valid"]:
            return {"sql": sql, "result": execute_sql(sql),
                    "attempts": attempts, "accepted": True,
                    "reason": verdict["reason"]}
        if attempts >= max_attempts:
            break
        sql = refine_query(question, sql, reason=verdict["reason"])
    return {"sql": sql, "result": None, "attempts": attempts,
            "accepted": False, "reason": verdict["reason"]}


# ---------------------------------------------------------------------------
# Task 3 - execution-aware feedback with an error memory
# ---------------------------------------------------------------------------

def execute_with_feedback(question: str, max_attempts: int) -> Dict[str, Any]:
    sql = draft_query(question)
    error_memory: List[Dict[str, str]] = []
    attempts = 0
    result = ""
    while attempts < max_attempts:
        result = execute_sql(sql)
        attempts += 1
        if not result.startswith("ERROR:"):
            return {"sql": sql, "result": result, "attempts": attempts,
                    "succeeded": True, "error_memory": error_memory}
        error = result[len("ERROR:"):].strip()
        error_memory.append({"question": question, "failed_sql": sql,
                             "error": error})
        if attempts >= max_attempts:
            break
        sql = refine_query(question, sql, db_error=error,
                           error_memory=error_memory)
    return {"sql": sql, "result": None, "attempts": attempts,
            "succeeded": False, "error_memory": error_memory}


# ---------------------------------------------------------------------------
# Task 4 - routing
# ---------------------------------------------------------------------------

ROUTES = {
    "outage_lookup": handle_outage_lookup,
    "capacity_check": handle_capacity_check,
    "load_trend": handle_load_trend,
    "schema_help": handle_schema_help,
}


def route_request(request: str) -> Dict[str, Any]:
    time.sleep(600)
    parsed = _as_json(llm_call(ROUTE_SYSTEM_PROMPT, "Request: %s" % request),
                      {"category": "schema_help"})
    category = str(parsed.get("category") or "schema_help")
    handler = ROUTES.get(category)
    if handler is None:
        return {"category": category, "result": ""}
    return {"category": category, "result": handler(request)}


# ---------------------------------------------------------------------------
# Task 5 - parallel guards
# ---------------------------------------------------------------------------

def run_guard(name: str, candidate_sql: str) -> Dict[str, Any]:
    parsed = _as_json(
        llm_call(GUARD_PROMPTS[name], "Candidate SQL: %s" % candidate_sql),
        {"guard": name, "passes": False, "reason": "the guard did not answer"})
    return {"guard": str(parsed.get("guard") or name),
            "passes": bool(parsed.get("passes")),
            "reason": str(parsed.get("reason", ""))}


def parallel_guards(candidate_sql: str) -> Dict[str, Any]:
    results: List[Dict[str, Any]] = []
    with ThreadPoolExecutor(max_workers=len(GUARD_NAMES)) as pool:
        futures = {pool.submit(run_guard, name, candidate_sql): name
                   for name in GUARD_NAMES}
        for future in as_completed(futures):
            results.append(future.result())
    blocked_by = sorted(r["guard"] for r in results if not r["passes"])
    return {"blocked": bool(blocked_by), "blocked_by": blocked_by,
            "guards": results}
