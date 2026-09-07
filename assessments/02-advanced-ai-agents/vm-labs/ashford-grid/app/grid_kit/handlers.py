"""The four control-room desks a classified request can be sent to.

Provided, do not modify.

Each desk answers from the grid operations database and returns a single line of
text. Which desk a request belongs to is not decided here - that is the job of the
classification step.

  handle_outage_lookup(request)  -> "OUTAGE-DESK | ..."
  handle_capacity_check(request) -> "CAPACITY-DESK | ..."
  handle_load_trend(request)     -> "LOAD-DESK | ..."
  handle_schema_help(request)    -> "SCHEMA-DESK | ..."
"""
from .tools import run_sql, scalar_text


# ---- shared:desks ----
# One desk per routing category. Each desk answers from the database, so the line
# it returns cannot be produced without querying. Kept byte-identical between the
# provided toolkit and this service.
DESK_SPECS = {
    "outage_lookup": (
        "OUTAGE-DESK",
        "SELECT COUNT(*) AS outages, SUM(customers_affected) AS customers "
        "FROM outages",
        "outages={outages} | customers={customers}",
    ),
    "capacity_check": (
        "CAPACITY-DESK",
        "SELECT COUNT(*) AS active_feeders, SUM(capacity_mw) AS capacity_mw "
        "FROM feeders WHERE status = 'active'",
        "active_feeders={active_feeders} | capacity_mw={capacity_mw}",
    ),
    "load_trend": (
        "LOAD-DESK",
        "SELECT COUNT(*) AS readings, MAX(load_mw) AS peak_mw "
        "FROM load_readings",
        "readings={readings} | peak_mw={peak_mw}",
    ),
    "schema_help": (
        "SCHEMA-DESK",
        "SELECT COUNT(*) AS substations FROM substations",
        "substations={substations}",
    ),
}

DESK_ORDER = ["outage_lookup", "capacity_check", "load_trend", "schema_help"]


def desk_summary(category, query_runner):
    """Answer one category from the database and return the desk line.

    Args:
        category: one of DESK_SPECS.
        query_runner: callable taking a SQL string and returning (columns, rows).
    """
    prefix, query, template = DESK_SPECS[category]
    columns, rows = query_runner(query)
    values = {}
    if rows:
        for name, value in zip(columns, rows[0]):
            values[name] = scalar_text(value)
    return "%s | %s" % (prefix, template.format(**values))
# ---- /shared:desks ----


def handle_outage_lookup(request):
    """Answer an interruption question. Args: request - the operator request."""
    return desk_summary("outage_lookup", run_sql)


def handle_capacity_check(request):
    """Answer a rating or headroom question. Args: request - the request."""
    return desk_summary("capacity_check", run_sql)


def handle_load_trend(request):
    """Answer a demand or reading question. Args: request - the request."""
    return desk_summary("load_trend", run_sql)


def handle_schema_help(request):
    """Answer a question about what the register records. Args: request."""
    return desk_summary("schema_help", run_sql)
