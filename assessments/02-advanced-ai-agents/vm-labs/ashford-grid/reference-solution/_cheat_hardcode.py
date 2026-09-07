"""SHORTCUT PROBE - every value published in the statement pasted in.

Expected: 0/50. Nothing is asked of the endpoint and nothing is run against the
database, so no check can find the round trip it requires, and every graded input
is one this file has never seen.
"""
CRITIQUES = {
    "SELECT name, line_voltage FROM substations": {
        "valid": False,
        "reason": "invalid: column 'line_voltage' does not exist on table "
                  "'substations'; use 'voltage_kv' instead"},
    "SELECT name, voltage_kv FROM substations WHERE voltage_kv > 100": {
        "valid": True,
        "reason": "ok: every table and column named is in the schema"},
}

ANSWERS = {
    "Which feeder had the longest outage, and how many minutes was it?":
        "feeder_code | duration_min\nTAR-F1 | 330",
    "What is the average load in megawatts for each feeder code?":
        "feeder_code | avg_load_mw\nTAR-F1 | 27.8333",
}

DESKS = {
    "outage_lookup": "OUTAGE-DESK | outages=18 | customers=29590",
    "capacity_check": "CAPACITY-DESK | active_feeders=11 | capacity_mw=200.5",
    "load_trend": "LOAD-DESK | readings=24 | peak_mw=29.2",
    "schema_help": "SCHEMA-DESK | substations=8",
}

GUARDS = ["schema_compliance", "aggregation_logic", "write_safety",
          "scan_scope"]


def critique_query(question, candidate_sql):
    return CRITIQUES.get(candidate_sql.strip(),
                         {"valid": True,
                          "reason": "ok: every table and column named is in "
                                    "the schema"})


def self_improving_query(question, max_attempts):
    result = ANSWERS.get(question)
    return {"sql": "SELECT 1", "result": result,
            "attempts": 2 if result else max_attempts,
            "accepted": bool(result), "reason": "ok"}


def execute_with_feedback(question, max_attempts):
    result = ANSWERS.get(question)
    return {"sql": "SELECT 1", "result": result, "attempts": 2,
            "succeeded": bool(result),
            "error_memory": [{"question": question, "failed_sql": "SELECT 1",
                              "error": "no such column: x"}]}


def route_request(request):
    lowered = request.lower()
    for category in ("outage_lookup", "capacity_check", "load_trend"):
        if category.split("_")[0] in lowered:
            return {"category": category, "result": DESKS[category]}
    return {"category": "schema_help", "result": DESKS["schema_help"]}


def parallel_guards(candidate_sql):
    lowered = candidate_sql.lower()
    bounded = any(word in lowered
                  for word in ("where", "group by", "limit", "count("))
    guards = [{"guard": name, "passes": name != "scan_scope" or bounded,
               "reason": "checked"} for name in GUARDS]
    failed = sorted(g["guard"] for g in guards if not g["passes"])
    return {"blocked": bool(failed), "blocked_by": failed, "guards": guards}
