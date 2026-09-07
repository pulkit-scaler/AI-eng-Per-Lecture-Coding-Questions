"""Alternative shape 4 - separate Reviewer and Repairer objects, tuple memory.

Materially different from the reference:
  * the evaluator and the optimizer are two independent objects with their own
    clients, which is the two-role split the pattern is named for;
  * the error memory is kept as a list of tuples internally and only converted to
    dictionaries on the way out;
  * the guards are submitted first and then collected in submission order with
    future.result(), never with as_completed;
  * the review loop is a generator that yields each candidate, and the caller
    stops consuming it.
"""
import json
from concurrent.futures import ThreadPoolExecutor

from grid_kit import (CRITIQUE_SYSTEM_PROMPT, DRAFT_SYSTEM_PROMPT, GUARD_NAMES,
                      GUARD_PROMPTS, MODEL, REFINE_SYSTEM_PROMPT,
                      ROUTE_SYSTEM_PROMPT, execute_sql, handle_capacity_check,
                      handle_load_trend, handle_outage_lookup,
                      handle_schema_help, make_client, schema_summary)


def unfence(text):
    body = (text or "").strip()
    if body.startswith("```"):
        body = body.split("\n", 1)[-1].rsplit("```", 1)[0].strip()
    return body


class Role:
    """One model role with its own client and system prompt."""

    def __init__(self, system_prompt):
        self.system_prompt = system_prompt
        self.client = make_client()

    def text(self, body):
        reply = self.client.chat.completions.create(
            model=MODEL, temperature=0.0,
            messages=[{"role": "system", "content": self.system_prompt},
                      {"role": "user", "content": body}])
        return unfence(reply.choices[0].message.content or "")

    def json(self, body, default):
        try:
            value = json.loads(self.text(body))
        except (json.JSONDecodeError, TypeError):
            return dict(default)
        return value if isinstance(value, dict) else dict(default)


SCHEMA = schema_summary()
REVIEWER = Role(CRITIQUE_SYSTEM_PROMPT)
WRITER = Role(DRAFT_SYSTEM_PROMPT)
REPAIRER = Role(REFINE_SYSTEM_PROMPT)
CLASSIFIER = Role(ROUTE_SYSTEM_PROMPT)
GUARDS = {name: Role(prompt) for name, prompt in GUARD_PROMPTS.items()}

DESKS = (("outage_lookup", handle_outage_lookup),
         ("capacity_check", handle_capacity_check),
         ("load_trend", handle_load_trend),
         ("schema_help", handle_schema_help))
DESK_TABLE = dict(DESKS)


def critique_query(question, candidate_sql):
    got = REVIEWER.json("Question: %s\n\nSchema:\n%s\n\nCandidate SQL: %s"
                        % (question, SCHEMA, candidate_sql),
                        {"valid": False, "reason": "no reply"})
    return {"valid": bool(got.get("valid")),
            "reason": str(got.get("reason", ""))}


def _draft(question):
    return WRITER.text("Question: %s\n\nSchema:\n%s" % (question, SCHEMA))\
        .rstrip(";").strip()


def _repair(question, sql, reason=None, error=None, memory=()):
    chunks = ["Question: %s" % question, "Schema:\n%s" % SCHEMA,
              "Original SQL: %s" % sql]
    if reason:
        chunks.append("Reviewer feedback: %s" % reason)
    if error:
        chunks.append("Database execution error: %s" % error)
    if memory:
        chunks.append("Previous corrections (learn from these):\n"
                      + "\n".join("  %s -> %s" % (bad, why)
                                  for _, bad, why in memory))
    return REPAIRER.text("\n\n".join(chunks)).rstrip(";").strip()


def _candidates(question, max_attempts):
    """Yield each candidate query and its verdict, refining as it goes."""
    sql = _draft(question)
    for _ in range(max_attempts):
        verdict = critique_query(question, sql)
        yield sql, verdict
        if verdict["valid"]:
            return
        sql = _repair(question, sql, reason=verdict["reason"])


def self_improving_query(question, max_attempts):
    attempts = 0
    sql = ""
    verdict = {"valid": False, "reason": ""}
    for sql, verdict in _candidates(question, max_attempts):
        attempts += 1
        if verdict["valid"]:
            return {"sql": sql, "result": execute_sql(sql),
                    "attempts": attempts, "accepted": True,
                    "reason": verdict["reason"]}
    return {"sql": sql, "result": None, "attempts": attempts,
            "accepted": False, "reason": verdict["reason"]}


def execute_with_feedback(question, max_attempts):
    sql = _draft(question)
    memory = []
    attempts = 0
    while attempts < max_attempts:
        outcome = execute_sql(sql)
        attempts += 1
        if not outcome.startswith("ERROR:"):
            return {"sql": sql, "result": outcome, "attempts": attempts,
                    "succeeded": True,
                    "error_memory": [{"question": q, "failed_sql": bad,
                                      "error": why}
                                     for q, bad, why in memory]}
        memory.append((question, sql, outcome[len("ERROR:"):].strip()))
        if attempts >= max_attempts:
            break
        sql = _repair(question, sql, error=memory[-1][2], memory=memory)
    return {"sql": sql, "result": None, "attempts": attempts,
            "succeeded": False,
            "error_memory": [{"question": q, "failed_sql": bad, "error": why}
                             for q, bad, why in memory]}


def route_request(request):
    got = CLASSIFIER.json("Request: %s" % request,
                          {"category": "schema_help"})
    category = str(got.get("category") or "schema_help")
    if category not in DESK_TABLE:
        return {"category": category, "result": ""}
    return {"category": category, "result": DESK_TABLE[category](request)}


def _guard(name, candidate_sql):
    got = GUARDS[name].json("Candidate SQL: %s" % candidate_sql,
                            {"guard": name, "passes": False,
                             "reason": "no reply"})
    return {"guard": str(got.get("guard") or name),
            "passes": bool(got.get("passes")),
            "reason": str(got.get("reason", ""))}


def parallel_guards(candidate_sql):
    pool = ThreadPoolExecutor(max_workers=len(GUARD_NAMES))
    try:
        futures = [pool.submit(_guard, name, candidate_sql)
                   for name in GUARD_NAMES]
        guards = [future.result() for future in futures]
    finally:
        pool.shutdown(wait=True)
    failed = sorted(item["guard"] for item in guards if not item["passes"])
    return {"blocked": len(failed) != 0, "blocked_by": failed,
            "guards": guards}
