"""Alternative shape 1 - a stateful agent class, and no system role at all.

Materially different from the reference:
  * the whole self-improvement layer lives in one class holding its own error
    memory, and the five required callables are thin delegates to a singleton;
  * every model turn is sent as a SINGLE user message with the role prompt
    prepended, so nothing is passed in the system slot;
  * the guard fan-out uses as_completed over a dict of futures keyed by name;
  * the dispatch table maps a category to a bound method that calls the desk.
"""
import json
from concurrent.futures import ThreadPoolExecutor, as_completed

from grid_kit import (CRITIQUE_SYSTEM_PROMPT, DRAFT_SYSTEM_PROMPT, GUARD_NAMES,
                      GUARD_PROMPTS, MODEL, REFINE_SYSTEM_PROMPT,
                      ROUTE_SYSTEM_PROMPT, execute_sql, handle_capacity_check,
                      handle_load_trend, handle_outage_lookup,
                      handle_schema_help, make_client, schema_summary)


def strip_fences(text):
    body = (text or "").strip()
    if body.startswith("```"):
        body = body.split("\n", 1)[-1].rsplit("```", 1)[0]
    return body.strip()


class GridAgent:
    """Draft, review, repair and dispatch, all with one client."""

    def __init__(self):
        self.client = make_client()
        self.schema = schema_summary()
        self.routes = {
            "outage_lookup": handle_outage_lookup,
            "capacity_check": handle_capacity_check,
            "load_trend": handle_load_trend,
            "schema_help": handle_schema_help,
        }

    # -- one model turn, everything in the user slot --------------------
    def ask(self, role_prompt, body):
        response = self.client.chat.completions.create(
            model=MODEL,
            temperature=0.0,
            messages=[{"role": "user",
                       "content": "%s\n\n%s" % (role_prompt, body)}],
        )
        return (response.choices[0].message.content or "").strip()

    def ask_json(self, role_prompt, body, default):
        try:
            parsed = json.loads(strip_fences(self.ask(role_prompt, body)))
        except (json.JSONDecodeError, TypeError):
            return dict(default)
        return parsed if isinstance(parsed, dict) else dict(default)

    def ask_sql(self, role_prompt, body):
        return strip_fences(self.ask(role_prompt, body)).rstrip(";").strip()

    # -- the pieces -----------------------------------------------------
    def review(self, question, candidate_sql):
        verdict = self.ask_json(
            CRITIQUE_SYSTEM_PROMPT,
            "Question: %s\nSchema:\n%s\nCandidate SQL: %s"
            % (question, self.schema, candidate_sql),
            {"valid": False, "reason": "unreadable review"})
        return {"valid": bool(verdict.get("valid")),
                "reason": str(verdict.get("reason", ""))}

    def draft(self, question):
        return self.ask_sql(DRAFT_SYSTEM_PROMPT,
                            "Question: %s\nSchema:\n%s"
                            % (question, self.schema))

    def repair(self, question, sql, reason="", db_error="", memory=None):
        body = ["Question: %s" % question,
                "Schema:\n%s" % self.schema,
                "Original SQL: %s" % sql]
        if reason:
            body.append("Reviewer feedback: %s" % reason)
        if db_error:
            body.append("Database execution error: %s" % db_error)
        for index, entry in enumerate(memory or []):
            body.append("Earlier failure %d: query %s rejected with %s"
                        % (index + 1, entry["failed_sql"], entry["error"]))
        return self.ask_sql(REFINE_SYSTEM_PROMPT, "\n".join(body))

    # -- the five deliverables -----------------------------------------
    def improve(self, question, max_attempts):
        sql = self.draft(question)
        verdict = {"valid": False, "reason": ""}
        for attempt in range(1, max_attempts + 1):
            verdict = self.review(question, sql)
            if verdict["valid"]:
                return {"sql": sql, "result": execute_sql(sql),
                        "attempts": attempt, "accepted": True,
                        "reason": verdict["reason"]}
            if attempt == max_attempts:
                break
            sql = self.repair(question, sql, reason=verdict["reason"])
        return {"sql": sql, "result": None, "attempts": max_attempts,
                "accepted": False, "reason": verdict["reason"]}

    def run_with_feedback(self, question, max_attempts):
        sql = self.draft(question)
        memory = []
        for attempt in range(1, max_attempts + 1):
            outcome = execute_sql(sql)
            if not outcome.startswith("ERROR:"):
                return {"sql": sql, "result": outcome, "attempts": attempt,
                        "succeeded": True, "error_memory": memory}
            memory.append({"question": question, "failed_sql": sql,
                           "error": outcome.split("ERROR:", 1)[1].strip()})
            if attempt == max_attempts:
                break
            sql = self.repair(question, sql,
                              db_error=memory[-1]["error"], memory=memory)
        return {"sql": sql, "result": None, "attempts": max_attempts,
                "succeeded": False, "error_memory": memory}

    def route(self, request):
        verdict = self.ask_json(ROUTE_SYSTEM_PROMPT, "Request: %s" % request,
                                {"category": "schema_help"})
        category = str(verdict.get("category") or "schema_help")
        desk = self.routes.get(category)
        return {"category": category,
                "result": desk(request) if desk else "unrouted"}

    def one_guard(self, name, candidate_sql):
        verdict = self.ask_json(GUARD_PROMPTS[name],
                                "Candidate SQL: %s" % candidate_sql,
                                {"guard": name, "passes": False,
                                 "reason": "no answer"})
        return {"guard": str(verdict.get("guard") or name),
                "passes": bool(verdict.get("passes")),
                "reason": str(verdict.get("reason", ""))}

    def all_guards(self, candidate_sql):
        collected = []
        with ThreadPoolExecutor(max_workers=len(GUARD_NAMES)) as pool:
            pending = {pool.submit(self.one_guard, name, candidate_sql): name
                       for name in GUARD_NAMES}
            for future in as_completed(pending):
                collected.append(future.result())
        failed = sorted(item["guard"] for item in collected
                        if not item["passes"])
        return {"blocked": len(failed) > 0, "blocked_by": failed,
                "guards": collected}


_AGENT = None


def agent():
    global _AGENT
    if _AGENT is None:
        _AGENT = GridAgent()
    return _AGENT


def critique_query(question, candidate_sql):
    return agent().review(question, candidate_sql)


def self_improving_query(question, max_attempts):
    return agent().improve(question, max_attempts)


def execute_with_feedback(question, max_attempts):
    return agent().run_with_feedback(question, max_attempts)


def route_request(request):
    return agent().route(request)


def parallel_guards(candidate_sql):
    return agent().all_guards(candidate_sql)
