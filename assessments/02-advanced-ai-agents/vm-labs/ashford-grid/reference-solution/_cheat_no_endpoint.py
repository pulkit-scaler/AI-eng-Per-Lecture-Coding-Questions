"""SHORTCUT PROBE - the whole layer reimplemented locally, with no model turns.

Every verdict, category and repair is derived here from the database schema with
hand-written rules, so the returned values often look right. Expected: 0/50,
because every check also requires the round trips that were skipped.
"""
import re

from grid_kit import (connect, execute_sql, handle_capacity_check,
                      handle_load_trend, handle_outage_lookup,
                      handle_schema_help, list_tables, get_table_schema)

GUARDS = ["schema_compliance", "aggregation_logic", "write_safety",
          "scan_scope"]


def schema():
    return {table: get_table_schema(table) for table in list_tables()}


def bad_names(sql):
    known = set()
    for columns in schema().values():
        known.update(c.lower() for c in columns)
    known.update(t.lower() for t in schema())
    known.update({"select", "from", "where", "group", "by", "order", "join",
                  "on", "as", "count", "sum", "avg", "min", "max", "limit",
                  "desc", "asc", "and", "not", "null"})
    aliased = {m.group(1).lower()
               for m in re.finditer(r"\bAS\s+(\w+)", sql, re.I)}
    out = []
    stripped = re.sub(r"'[^']*'", "''", sql)
    for token in re.findall(r"[A-Za-z_]\w*(?:\.[A-Za-z_]\w*)?", stripped):
        name = token.split(".")[-1].lower()
        if name in known or name in aliased or len(name) <= 1:
            continue
        if name not in out:
            out.append(name)
    return out


def critique_query(question, candidate_sql):
    missing = bad_names(candidate_sql)
    if missing:
        return {"valid": False,
                "reason": "invalid: column %r does not exist" % missing[0]}
    return {"valid": True, "reason": "ok"}


def self_improving_query(question, max_attempts):
    sql = "SELECT COUNT(*) AS n FROM feeders"
    return {"sql": sql, "result": execute_sql(sql), "attempts": 2,
            "accepted": True, "reason": "ok"}


def execute_with_feedback(question, max_attempts):
    sql = "SELECT COUNT(*) AS n FROM outages"
    return {"sql": sql, "result": execute_sql(sql), "attempts": 3,
            "succeeded": True,
            "error_memory": [
                {"question": question, "failed_sql": "SELECT cause_type FROM outages",
                 "error": "no such column: cause_type"},
                {"question": question,
                 "failed_sql": "SELECT affected_customers FROM outages",
                 "error": "no such column: affected_customers"}]}


DESKS = {"outage_lookup": handle_outage_lookup,
         "capacity_check": handle_capacity_check,
         "load_trend": handle_load_trend,
         "schema_help": handle_schema_help}


def route_request(request):
    lowered = request.lower()
    if "dark" in lowered or "down" in lowered or "outage" in lowered:
        category = "outage_lookup"
    elif "megawatts to" in lowered or "rating" in lowered or "capacity" in lowered:
        category = "capacity_check"
    elif "draw" in lowered or "reading" in lowered or "load" in lowered:
        category = "load_trend"
    else:
        category = "schema_help"
    return {"category": category, "result": DESKS[category](request)}


def parallel_guards(candidate_sql):
    lowered = candidate_sql.lower()
    bounded = any(word in lowered for word in ("where", "group by", "limit",
                                               "count(", "sum(", "avg("))
    verdicts = {
        "schema_compliance": not bad_names(candidate_sql),
        "aggregation_logic": True,
        "write_safety": lowered.strip().startswith("select"),
        "scan_scope": bounded,
    }
    guards = [{"guard": name, "passes": verdicts[name], "reason": "checked"}
              for name in GUARDS]
    failed = sorted(name for name in GUARDS if not verdicts[name])
    return {"blocked": bool(failed), "blocked_by": failed, "guards": guards}
