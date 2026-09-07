"""Alternative shape 6 - raw threading.Thread and a Queue, no concurrent.futures.

Materially different from the reference:
  * the guard fan-out uses threading.Thread and queue.Queue directly, with no
    executor and no futures at all, which is the other standard-library route to
    the same fan-out;
  * the review loop is a while loop over a mutable candidate holder;
  * dispatch is a dict comprehension zipping the category names to the desks;
  * the error memory is built with a helper that returns a new list each time.
"""
import json
import queue
import threading

from grid_kit import (CRITIQUE_SYSTEM_PROMPT, DRAFT_SYSTEM_PROMPT, GUARD_NAMES,
                      GUARD_PROMPTS, MODEL, REFINE_SYSTEM_PROMPT,
                      ROUTE_SYSTEM_PROMPT, execute_sql, handle_capacity_check,
                      handle_load_trend, handle_outage_lookup,
                      handle_schema_help, make_client, schema_summary)

CLIENT = make_client()
SCHEMA = schema_summary()

CATEGORIES = ("outage_lookup", "capacity_check", "load_trend", "schema_help")
HANDLERS = (handle_outage_lookup, handle_capacity_check, handle_load_trend,
            handle_schema_help)
DESKS = {name: desk for name, desk in zip(CATEGORIES, HANDLERS)}


def say(system_prompt, body):
    reply = CLIENT.chat.completions.create(
        model=MODEL, temperature=0.0,
        messages=[{"role": "system", "content": system_prompt},
                  {"role": "user", "content": body}])
    text = (reply.choices[0].message.content or "").strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[-1].rsplit("```", 1)[0].strip()
    return text


def say_json(system_prompt, body, default):
    try:
        value = json.loads(say(system_prompt, body))
    except (json.JSONDecodeError, TypeError):
        return dict(default)
    return value if isinstance(value, dict) else dict(default)


def critique_query(question, candidate_sql):
    got = say_json(CRITIQUE_SYSTEM_PROMPT,
                   "Question: %s\n\nSchema:\n%s\n\nCandidate SQL: %s"
                   % (question, SCHEMA, candidate_sql),
                   {"valid": False, "reason": "the review did not parse"})
    return {"valid": bool(got.get("valid")),
            "reason": str(got.get("reason", ""))}


def draft(question):
    return say(DRAFT_SYSTEM_PROMPT, "Question: %s\n\nSchema:\n%s\n\nWrite it."
               % (question, SCHEMA)).rstrip(";").strip()


def memory_lines(memory):
    return ["  %s was rejected with %s" % (item["failed_sql"], item["error"])
            for item in memory]


def repair(question, sql, reason="", db_error="", memory=()):
    block = ["Question: %s" % question, "Schema:\n%s" % SCHEMA,
             "Original SQL: %s" % sql]
    if reason:
        block.append("Reviewer feedback: %s" % reason)
    if db_error:
        block.append("Database execution error: %s" % db_error)
    if memory:
        block.append("Previous corrections (learn from these):")
        block.extend(memory_lines(list(memory)))
    return say(REFINE_SYSTEM_PROMPT,
               "\n\n".join(block)).rstrip(";").strip()


def self_improving_query(question, max_attempts):
    holder = {"sql": draft(question), "reason": ""}
    reviewed = 0
    while reviewed < max_attempts:
        verdict = critique_query(question, holder["sql"])
        reviewed += 1
        holder["reason"] = verdict["reason"]
        if verdict["valid"]:
            return {"sql": holder["sql"], "result": execute_sql(holder["sql"]),
                    "attempts": reviewed, "accepted": True}
        if reviewed >= max_attempts:
            break
        holder["sql"] = repair(question, holder["sql"],
                               reason=holder["reason"])
    return {"sql": holder["sql"], "result": None, "attempts": reviewed,
            "accepted": False}


def execute_with_feedback(question, max_attempts):
    sql = draft(question)
    memory = []
    ran = 0
    while ran < max_attempts:
        outcome = execute_sql(sql)
        ran += 1
        if not outcome.startswith("ERROR:"):
            return {"sql": sql, "result": outcome, "attempts": ran,
                    "succeeded": True, "error_memory": memory}
        memory.append({"question": question, "failed_sql": sql,
                       "error": outcome[len("ERROR:"):].strip()})
        if ran >= max_attempts:
            break
        sql = repair(question, sql, db_error=memory[-1]["error"],
                     memory=memory)
    return {"sql": sql, "result": None, "attempts": ran, "succeeded": False,
            "error_memory": memory}


def route_request(request):
    got = say_json(ROUTE_SYSTEM_PROMPT, "Request: %s" % request,
                   {"category": ""})
    category = str(got.get("category") or "")
    desk = DESKS.get(category)
    if desk is None:
        return {"category": category, "result": ""}
    return {"category": category, "result": desk(request)}


def one_guard(name, candidate_sql, sink):
    got = say_json(GUARD_PROMPTS[name], "Candidate SQL: %s" % candidate_sql,
                   {"guard": name, "passes": False, "reason": "no answer"})
    sink.put({"guard": str(got.get("guard") or name),
              "passes": bool(got.get("passes")),
              "reason": str(got.get("reason", ""))})


def parallel_guards(candidate_sql):
    sink = queue.Queue()
    threads = [threading.Thread(target=one_guard,
                                args=(name, candidate_sql, sink))
               for name in GUARD_NAMES]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    guards = []
    while not sink.empty():
        guards.append(sink.get())
    failed = sorted(item["guard"] for item in guards if not item["passes"])
    return {"blocked": bool(failed), "blocked_by": failed, "guards": guards}
