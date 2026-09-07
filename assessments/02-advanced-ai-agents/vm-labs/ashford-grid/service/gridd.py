#!/usr/bin/env python3
"""gridd - local model endpoint backing the Ashford grid-operations lab.

INSTRUCTOR-ONLY FILE. Installed to /opt/ashford-svc (root:root, 0700) and never
exposed under the learner's project directory.

Endpoints:
  GET  /health
  POST /v1/chat/completions          OpenAI-compatible chat completion
  POST /v1/audit/query               operations audit record for an executed query
  GET  /__agq7w2/*                   grader-only, requires X-Grader-Key

Everything the chat endpoint returns is COMPUTED, never sampled:

  * critique verdicts are produced by validating the candidate SQL against the
    real SQLite schema, so an unknown column is rejected by name and a query over
    real columns is accepted;
  * a draft query for a question comes from the bank below, optionally with one or
    two column names corrupted, so a first draft can genuinely fail review;
  * a repair is computed from the feedback the caller actually sent - the bad name
    it names is substituted for the closest real column in the same tables. A
    caller that forwards no critique reason and no database error gets its own
    query back unchanged, and that query still fails;
  * a routing category comes from a fixed request bank plus a keyword fallback;
  * a guard verdict is a rule over the SQL, delayed by a fixed interval so that
    four guards run concurrently in noticeably less wall time than four guards run
    one after another. Receive and emit timestamps are recorded per request.
"""
import json
import os
import re
import sqlite3
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(os.environ.get("ASHFORD_PORT", "8836"))
DB_PATH = os.environ.get(
    "ASHFORD_DB", "/home/user/ashford-grid/data/grid_ops.db")
GRADER_KEY = "ashford-grader-q7w2"
GRADER_PREFIX = "/__agq7w2"
# Wall time each guard reply is held for. Four guards run together finish in about
# one interval; four guards run one after another take four. Small enough that even
# the sequential case stays far inside the per-request budget.
GUARD_DELAY = float(os.environ.get("ASHFORD_GUARD_DELAY", "0.7"))

_LOCK = threading.Lock()
_TRACE = {}
_SESSION = {}

MODEL_NAME = "ashford-grid-ops"


# ---------------------------------------------------------------------------
# database access (read-only; the file is never created or modified here)
# ---------------------------------------------------------------------------

def _connect():
    return sqlite3.connect("file:%s?mode=ro" % DB_PATH, uri=True)


def run_sql(query):
    """Run a query and return (columns, rows). Raises on a database error."""
    conn = _connect()
    try:
        cur = conn.execute(query)
        columns = [d[0] for d in (cur.description or [])]
        return columns, cur.fetchall()
    finally:
        conn.close()


def try_sql(query):
    """Run a query; return (columns, rows, error_text)."""
    try:
        columns, rows = run_sql(query)
        return columns, rows, ""
    except Exception as exc:                        # noqa: BLE001
        return [], [], str(exc)


_SCHEMA_CACHE = {}


def schema_map():
    """{table: [column, ...]} for every table in the database, in schema order."""
    with _LOCK:
        if _SCHEMA_CACHE:
            return dict(_SCHEMA_CACHE)
    conn = _connect()
    try:
        tables = [r[0] for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name NOT LIKE 'sqlite_%' ORDER BY name")]
        built = {}
        for table in tables:
            built[table] = [r[1] for r in conn.execute(
                "PRAGMA table_info(%s)" % table)]
    finally:
        conn.close()
    with _LOCK:
        _SCHEMA_CACHE.update(built)
    return built


# ---- shared:formatter ----
# Rendering of a result set into the text the desk reports. Kept byte-identical
# between the provided toolkit and this service, so an expected value computed
# here matches what the toolkit hands back.
def scalar_text(value):
    """Render one cell as text."""
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, float):
        rendered = "%.4f" % value
        rendered = rendered.rstrip("0").rstrip(".")
        return rendered if rendered not in ("", "-") else "0"
    return str(value)


def format_rows(columns, rows):
    """Render a result set as a compact text table."""
    if not columns:
        return "(no columns)"
    lines = [" | ".join(str(c) for c in columns)]
    for row in rows:
        lines.append(" | ".join(scalar_text(v) for v in row))
    if not rows:
        lines.append("(no rows)")
    return "\n".join(lines)
# ---- /shared:formatter ----


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


# ---------------------------------------------------------------------------
# SQL analysis
# ---------------------------------------------------------------------------

SQL_KEYWORDS = frozenset("""
select from where group by order having limit offset join left right inner outer
full cross on as and or not null is in like between distinct union all case when
then else end asc desc count avg sum min max abs round cast coalesce with
""".split())

AGG_RE = re.compile(r"\b(count|avg|sum|min|max|total)\s*\(", re.I)
IDENT_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*")
LITERAL_RE = re.compile(r"'(?:[^']|'')*'|\"(?:[^\"]|\"\")*\"")


def bare_name(identifier):
    return identifier.split(".")[-1]


def strip_literals(sql):
    """Blank out quoted strings so a value is never read as an identifier.

    Without this, WHERE status = 'active' reports a column named active.
    """
    return LITERAL_RE.sub("''", sql or "")


def table_refs(sql):
    """[(table, alias_or_None)] for every FROM / JOIN reference."""
    out = []
    sql = strip_literals(sql)
    pattern = re.compile(
        r"\b(?:FROM|JOIN)\s+([A-Za-z_]\w*)(?:\s+(?:AS\s+)?([A-Za-z_]\w*))?", re.I)
    for match in pattern.finditer(sql):
        table = match.group(1)
        alias = match.group(2)
        if alias and alias.lower() in SQL_KEYWORDS:
            alias = None
        out.append((table, alias))
    return out


def alias_map(sql):
    """{alias_or_table_lower: table} for the tables the query reads."""
    mapping = {}
    for table, alias in table_refs(sql):
        mapping[table.lower()] = table
        if alias:
            mapping[alias.lower()] = table
    return mapping


def output_aliases(sql):
    """Names introduced by AS - always legal identifiers later in the query."""
    return {m.group(1).lower()
            for m in re.finditer(r"\bAS\s+([A-Za-z_]\w*)",
                                 strip_literals(sql), re.I)}


def referenced_identifiers(sql):
    """Every identifier the query names, in order of appearance, deduplicated."""
    seen = []
    known = set()
    for match in IDENT_RE.finditer(strip_literals(sql)):
        token = match.group(0)
        if token.lower() in SQL_KEYWORDS:
            continue
        if token not in known:
            known.add(token)
            seen.append(token)
    return seen


def unknown_columns(sql):
    """[(identifier, table_or_None)] for identifiers that are not real columns."""
    schema = schema_map()
    aliases = alias_map(sql)
    produced = output_aliases(sql)
    tables_used = [aliases[k] for k in sorted(set(aliases))
                   if aliases[k] in schema]
    all_columns = set()
    for table in tables_used or list(schema):
        all_columns.update(c.lower() for c in schema[table])
    bad = []
    for identifier in referenced_identifiers(sql):
        parts = identifier.split(".")
        name = parts[-1]
        lowered = name.lower()
        if lowered in produced:
            continue
        if len(parts) > 1:
            qualifier = parts[-2].lower()
            table = aliases.get(qualifier)
            if table is None or table not in schema:
                continue
            if lowered in {c.lower() for c in schema[table]}:
                continue
            bad.append((identifier, table))
            continue
        if lowered in aliases or lowered in {t.lower() for t in schema}:
            continue                                # a table name, not a column
        if lowered in all_columns:
            continue
        bad.append((identifier, None))
    return bad


def unknown_tables(sql):
    schema = {t.lower() for t in schema_map()}
    return [t for t, _ in table_refs(sql) if t.lower() not in schema]


def candidate_tables(sql):
    schema = schema_map()
    seen = []
    for table, _ in table_refs(sql):
        for known in schema:
            if known.lower() == table.lower() and known not in seen:
                seen.append(known)
    return seen or sorted(schema)


def suggest_column(bad_name, sql, table=None):
    """The closest real column to a name the schema does not have, or None.

    Closeness is the number of underscore-separated word parts the two names
    share. Highest overlap wins; ties break on schema order. A name that shares
    nothing with any real column of the tables in play has no counterpart and
    gets no suggestion, which is what makes a genuinely unanswerable question
    unanswerable.
    """
    schema = schema_map()
    tables = [table] if table and table in schema else candidate_tables(sql)
    wanted = set(bare_name(bad_name).lower().split("_"))
    best = None
    best_score = 0
    for tbl in tables:
        for column in schema.get(tbl, []):
            score = len(wanted & set(column.lower().split("_")))
            if score > best_score:
                best_score = score
                best = column
    return best if best_score > 0 else None


def substitute_name(sql, old, new):
    return re.sub(r"\b%s\b" % re.escape(old), new, sql)


# ---------------------------------------------------------------------------
# critique verdict
# ---------------------------------------------------------------------------

def critique(sql):
    """{"valid": bool, "reason": str} for a candidate query."""
    query = (sql or "").strip().rstrip(";")
    if not query:
        return {"valid": False,
                "reason": "invalid: no query was supplied for review"}
    if not re.match(r"^\s*select\b", query, re.I):
        return {"valid": False,
                "reason": "invalid: this is a read-only analytics database and "
                          "only a SELECT statement may be reviewed"}
    for table in unknown_tables(query):
        available = ", ".join(sorted(schema_map()))
        return {"valid": False,
                "reason": "invalid: table %r does not exist; the database has "
                          "%s" % (table, available)}
    for identifier, table in unknown_columns(query):
        owner = table or candidate_tables(query)[0]
        suggestion = suggest_column(identifier, query, table)
        if suggestion:
            return {"valid": False,
                    "reason": "invalid: column %r does not exist on table %r; "
                              "use %r instead" % (bare_name(identifier), owner,
                                                  suggestion)}
        return {"valid": False,
                "reason": "invalid: column %r does not exist on table %r and "
                          "the schema records no comparable column"
                          % (bare_name(identifier), owner)}
    return {"valid": True,
            "reason": "ok: every table and column named is in the schema"}


# ---------------------------------------------------------------------------
# guards
# ---------------------------------------------------------------------------

GUARD_NAMES = ["schema_compliance", "aggregation_logic",
               "write_safety", "scan_scope"]

WRITE_RE = re.compile(
    r"\b(drop|delete|update|insert|alter|truncate|replace|create|attach)\b", re.I)


def guard_verdict(name, sql):
    query = (sql or "").strip().rstrip(";")
    if name == "schema_compliance":
        verdict = critique(query)
        if verdict["valid"]:
            return {"passes": True,
                    "reason": "every table and column named is in the schema"}
        return {"passes": False, "reason": verdict["reason"].split(": ", 1)[-1]}
    if name == "aggregation_logic":
        has_agg = bool(AGG_RE.search(query))
        has_group = bool(re.search(r"\bGROUP\s+BY\b", query, re.I))
        projection = re.search(r"select\s+(.*?)\s+from\b", query, re.I | re.S)
        plain = []
        if projection:
            for part in projection.group(1).split(","):
                part = part.strip()
                if not part or part == "*" or "(" in part:
                    continue
                plain.append(part)
        if has_agg and plain and not has_group:
            return {"passes": False,
                    "reason": "an aggregate is mixed with plain columns but "
                              "there is no GROUP BY clause"}
        if has_group and not has_agg:
            return {"passes": False,
                    "reason": "there is a GROUP BY clause but nothing is "
                              "aggregated"}
        return {"passes": True, "reason": "grouping matches the aggregation"}
    if name == "write_safety":
        if not re.match(r"^\s*select\b", query, re.I):
            return {"passes": False,
                    "reason": "only SELECT statements may run against a "
                              "read-only analytics database"}
        if WRITE_RE.search(query):
            return {"passes": False,
                    "reason": "the statement contains a data-modifying keyword"}
        return {"passes": True, "reason": "the statement only reads"}
    if name == "scan_scope":
        bounded = (re.search(r"\bWHERE\b", query, re.I)
                   or re.search(r"\bGROUP\s+BY\b", query, re.I)
                   or re.search(r"\bLIMIT\b", query, re.I)
                   or AGG_RE.search(query))
        if not bounded:
            return {"passes": False,
                    "reason": "an unbounded scan with no WHERE, GROUP BY, "
                              "LIMIT or aggregate is not permitted"}
        return {"passes": True, "reason": "the scan is bounded"}
    return {"passes": True, "reason": "no such guard"}


def guards_report(sql):
    entries = [dict(guard=name, **guard_verdict(name, sql))
               for name in GUARD_NAMES]
    blocked_by = sorted(e["guard"] for e in entries if not e["passes"])
    return {"blocked": bool(blocked_by), "blocked_by": blocked_by,
            "guards": entries}


# ---------------------------------------------------------------------------
# question bank
# ---------------------------------------------------------------------------

def _q(key, question, sql, swaps=()):
    return {"key": key, "question": question, "sql": sql,
            "swaps": [tuple(s) for s in swaps]}


QUESTIONS = [
    _q("cap_by_region",
       "What is the total feeder capacity in megawatts for each region?",
       "SELECT s.region, SUM(f.capacity_mw) AS total_capacity_mw "
       "FROM feeders f JOIN substations s "
       "ON f.substation_id = s.substation_id "
       "GROUP BY s.region ORDER BY total_capacity_mw DESC",
       [("capacity_mw", "rated_capacity_mw")]),
    _q("customers_by_cause",
       "Which outage cause affected the most customers in total?",
       "SELECT cause, SUM(customers_affected) AS total_customers "
       "FROM outages GROUP BY cause "
       "ORDER BY total_customers DESC LIMIT 1",
       [("cause", "cause_type"),
        ("customers_affected", "affected_customers")]),
    _q("avg_load_by_feeder",
       "What is the average load in megawatts for each feeder code?",
       "SELECT f.feeder_code, AVG(r.load_mw) AS avg_load_mw "
       "FROM load_readings r JOIN feeders f ON r.feeder_id = f.feeder_id "
       "GROUP BY f.feeder_code ORDER BY avg_load_mw DESC",
       [("load_mw", "load_megawatts")]),
    _q("longest_outage",
       "Which feeder had the longest outage, and how many minutes was it?",
       "SELECT f.feeder_code, o.duration_min FROM outages o "
       "JOIN feeders f ON o.feeder_id = f.feeder_id "
       "ORDER BY o.duration_min DESC LIMIT 1",
       [("duration_min", "duration_minutes")]),
    _q("active_by_region",
       "How many feeders are currently active in each region?",
       "SELECT s.region, COUNT(*) AS active_feeders FROM feeders f "
       "JOIN substations s ON f.substation_id = s.substation_id "
       "WHERE f.status = 'active' GROUP BY s.region ORDER BY s.region"),
    _q("substations_by_voltage",
       "How many substations are there at each voltage level?",
       "SELECT voltage_kv, COUNT(*) AS substation_count FROM substations "
       "GROUP BY voltage_kv ORDER BY voltage_kv"),
    _q("storm_outages",
       "How many outages were caused by storms?",
       "SELECT COUNT(*) AS storm_outages FROM outages "
       "WHERE cause = 'storm'"),
    _q("worst_power_factor",
       "Which feeder has the worst reactive power factor?",
       "SELECT feeder_code, reactive_power_factor FROM feeders "
       "ORDER BY reactive_power_factor ASC LIMIT 1"),
    _q("worst_harmonics",
       "Which substation has the highest harmonic distortion?",
       "SELECT name, harmonic_distortion_pct FROM substations "
       "ORDER BY harmonic_distortion_pct DESC LIMIT 1"),
]

BY_KEY = {q["key"]: q for q in QUESTIONS}


def normalize(text):
    return re.sub(r"[^a-z0-9]+", " ", (text or "").lower()).strip()


_NORM_QUESTIONS = sorted(
    ((normalize(q["question"]), q) for q in QUESTIONS),
    key=lambda pair: -len(pair[0]))


def draft_for(question):
    """The first query the endpoint offers for a question, corrupted if the bank
    says this question is one a first pass gets wrong."""
    sql = question["sql"]
    for old, new in question["swaps"]:
        sql = substitute_name(sql, old, new)
    return sql


def match_question(text):
    """The bank entry whose question appears in the text, or None."""
    haystack = normalize(text)
    for needle, question in _NORM_QUESTIONS:
        if needle and needle in haystack:
            return question
    return None


# ---------------------------------------------------------------------------
# routing
# ---------------------------------------------------------------------------

ROUTE_BANK = {
    # published samples
    "show me the outage history for the east region": "outage_lookup",
    "what spare capacity is left on the active feeders": "capacity_check",
    "plot the megawatt draw through the day for the tarrant quay feeders":
        "load_trend",
    "what tables does this database have": "schema_help",
    # graded requests
    "how long was the north loop down after the storm last month and how many "
    "homes went dark": "outage_lookup",
    "can we hand another twelve megawatts to the tarrant quay run without "
    "pushing it past its rating": "capacity_check",
    "give me the megawatt draw over the last few readings so i can see where "
    "it is heading": "load_trend",
    "remind me what fields the register keeps for each substation":
        "schema_help",
}

ROUTE_KEYWORDS = [
    ("outage_lookup", ("outage", "went dark", "interruption", "restored",
                       "down after", "fault", "storm damage")),
    ("capacity_check", ("capacity", "rating", "headroom", "spare", "overload",
                        "megawatts to", "rated")),
    ("load_trend", ("load", "draw", "demand", "reading", "profile", "trend",
                    "peak")),
    ("schema_help", ("table", "column", "schema", "field", "what does the "
                     "database", "register keeps")),
]


def classify(request, wider=""):
    """Category for one control-room request.

    The bank is tried against the request and then against the wider prompt, so a
    caller that wraps the request in extra framing still resolves. The keyword
    fallback only ever sees the request itself, never the surrounding prompt.
    """
    for haystack in (normalize(request), normalize(wider)):
        if not haystack:
            continue
        for known, category in ROUTE_BANK.items():
            if known and known in haystack:
                return category, ("matched a known request for the %s desk"
                                  % category)
    lowered = (request or "").lower()
    for category, needles in ROUTE_KEYWORDS:
        for needle in needles:
            if needle in lowered:
                return category, "the request mentions %r" % needle
    return "schema_help", "no stronger signal than a general database question"


# ---------------------------------------------------------------------------
# repair
# ---------------------------------------------------------------------------

REASON_COLUMN_RE = re.compile(r"column '([A-Za-z_][\w.]*)' does not exist", re.I)
ERROR_COLUMN_RE = re.compile(r"no such column:\s*([A-Za-z_][\w.]*)", re.I)
ERROR_TABLE_RE = re.compile(r"no such table:\s*([A-Za-z_]\w*)", re.I)
REASON_TABLE_RE = re.compile(r"table '([A-Za-z_]\w*)' does not exist", re.I)


def repair(sql, feedback_text):
    """Correct a query using only the feedback the caller actually forwarded.

    Returns (corrected_sql, used_feedback). When the feedback names nothing that
    the schema can resolve, the query comes back unchanged.
    """
    current = sql
    used = False
    names = []
    for pattern in (REASON_COLUMN_RE, ERROR_COLUMN_RE):
        for match in pattern.finditer(feedback_text or ""):
            name = bare_name(match.group(1))
            if name not in names:
                names.append(name)
    for name in names:
        replacement = suggest_column(name, current)
        if replacement and replacement.lower() != name.lower():
            updated = substitute_name(current, name, replacement)
            if updated != current:
                current = updated
                used = True
    tables = []
    for pattern in (REASON_TABLE_RE, ERROR_TABLE_RE):
        for match in pattern.finditer(feedback_text or ""):
            if match.group(1) not in tables:
                tables.append(match.group(1))
    for bad in tables:
        wanted = set(bad.lower().split("_"))
        best, best_score = None, 0
        for table in schema_map():
            score = len(wanted & set(table.lower().split("_")))
            if score > best_score:
                best, best_score = table, score
        if best:
            updated = substitute_name(current, bad, best)
            if updated != current:
                current = updated
                used = True
    return current, used


# ---------------------------------------------------------------------------
# trace
# ---------------------------------------------------------------------------

def _blank_trace():
    return {"chat": 0,
            "kinds": {"draft": 0, "critique": 0, "refine": 0, "route": 0,
                      "guard": 0, "other": 0},
            "critiques": [], "drafts": [], "refines": [], "routes": [],
            "guards": [], "executed": [], "prompts": []}


def _record(session, kind, entry=None, prompt=None):
    with _LOCK:
        trace = _TRACE.setdefault(session, _blank_trace())
        if kind in trace["kinds"]:
            trace["kinds"][kind] += 1
        if kind != "audit":
            trace["chat"] += 1
        bucket = {"draft": "drafts", "critique": "critiques",
                  "refine": "refines", "route": "routes", "guard": "guards",
                  "audit": "executed"}.get(kind)
        if bucket and entry is not None:
            if len(trace[bucket]) < 200:
                trace[bucket].append(entry)
        if prompt is not None and len(trace["prompts"]) < 40:
            trace["prompts"].append(prompt[:4000])


def _last_sql(session, key):
    with _LOCK:
        return _SESSION.get(session, {}).get(key)


def _set_last_sql(session, key, sql):
    with _LOCK:
        _SESSION.setdefault(session, {})[key] = sql


def concurrency_report(session):
    """Per candidate query, how much of the guard work overlapped in time."""
    with _LOCK:
        entries = list(_TRACE.get(session, _blank_trace())["guards"])
    groups = {}
    for entry in entries:
        groups.setdefault(entry.get("sql", ""), []).append(entry)
    out = {}
    for sql, items in groups.items():
        span = max(i["emit"] for i in items) - min(i["recv"] for i in items)
        busy = sum(i["emit"] - i["recv"] for i in items)
        factor = (busy / span) if span > 1e-6 else 0.0
        out[sql] = {"count": len(items),
                    "span": round(span, 4),
                    "busy": round(busy, 4),
                    "factor": round(factor, 3),
                    # Tenths, so a check can compare with integer arithmetic in
                    # the shell rather than shelling out to a calculator.
                    "factor_tenths": int(round(factor * 10)),
                    "guards": sorted(i["guard"] for i in items)}
    return out


# ---------------------------------------------------------------------------
# chat completion dispatch
# ---------------------------------------------------------------------------

MARKERS = [
    ("guard", "grid analytics guard named"),
    ("route", "grid operations request classifier"),
    ("refine", "SQL repair specialist"),
    ("critique", "SQL quality reviewer"),
    ("draft", "SQL generation specialist"),
]


def message_text(messages):
    parts = []
    for message in messages or []:
        content = message.get("content")
        if isinstance(content, str):
            parts.append(content)
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and "text" in block:
                    parts.append(str(block["text"]))
                elif isinstance(block, str):
                    parts.append(block)
    return "\n".join(parts)


def last_user_text(messages):
    """Content of the last message that is not a system message."""
    for message in reversed(messages or []):
        if (message.get("role") or "user") == "system":
            continue
        content = message.get("content")
        if isinstance(content, str) and content.strip():
            return content
        if isinstance(content, list):
            joined = message_text([message])
            if joined.strip():
                return joined
    return ""


def classify_request(text):
    for kind, marker in MARKERS:
        if marker.lower() in text.lower():
            return kind
    return "other"


LABEL_RE = re.compile(r"^\s*[A-Za-z][A-Za-z0-9 _-]{0,40}:\s")
SELECT_RE = re.compile(r"\bSELECT\b", re.I)


def extract_sql(text):
    """The last query-looking statement in a prompt.

    Scans line by line rather than with one regex, because a caller may put the
    candidate query on its own line, inline after a label, or spread over several
    lines, and may follow it with further labelled sections. A run of lines is
    taken from the word SELECT up to the first blank line or the first new
    labelled section, and the last run that reads like a query wins.
    """
    lines = (text or "").splitlines()
    best = ""
    fallback = ""
    for index, line in enumerate(lines):
        match = SELECT_RE.search(line)
        if not match:
            continue
        chunk = [line[match.start():]]
        for following in lines[index + 1:]:
            if not following.strip() or LABEL_RE.match(following):
                break
            chunk.append(following)
        statement = " ".join(part.strip() for part in chunk).strip()
        statement = statement.rstrip(";").strip()
        if not statement:
            continue
        fallback = statement
        if re.search(r"\bFROM\b", statement, re.I):
            best = statement
    return best or fallback


def guard_name_in(text):
    match = re.search(r"grid analytics guard named ([a-z_]+)", text or "", re.I)
    if match and match.group(1) in GUARD_NAMES:
        return match.group(1)
    lowered = (text or "").lower()
    for name in GUARD_NAMES:
        if name in lowered:
            return name
    return GUARD_NAMES[0]


def question_for(session, text):
    question = match_question(text)
    if question is not None:
        _set_last_sql(session, "_question", question["key"])
        return question
    with _LOCK:
        key = _SESSION.get(session, {}).get("_question")
    return BY_KEY.get(key) or QUESTIONS[0]


def handle_chat(session, payload):
    messages = payload.get("messages") or []
    text = message_text(messages)
    kind = classify_request(text)

    if kind == "guard":
        recv = time.time()
        name = guard_name_in(text)
        sql = extract_sql(text)
        verdict = guard_verdict(name, sql)
        time.sleep(GUARD_DELAY)
        emit = time.time()
        _record(session, "guard",
                {"guard": name, "sql": sql, "passes": verdict["passes"],
                 "recv": recv, "emit": emit}, prompt=text)
        return json.dumps({"guard": name, "passes": verdict["passes"],
                           "reason": verdict["reason"]}), "stop"

    if kind == "route":
        request = last_user_text(messages) or text
        category, why = classify(request, text)
        _record(session, "route", {"request": request[-400:],
                                   "category": category}, prompt=text)
        return json.dumps({"category": category, "confidence": 1.0,
                           "reasoning": why}), "stop"

    if kind == "critique":
        sql = extract_sql(text)
        verdict = critique(sql)
        _record(session, "critique",
                {"sql": sql, "valid": verdict["valid"],
                 "reason": verdict["reason"]}, prompt=text)
        return json.dumps(verdict), "stop"

    if kind == "refine":
        question = question_for(session, text)
        current = _last_sql(session, question["key"]) or draft_for(question)
        corrected, used = repair(current, text)
        _set_last_sql(session, question["key"], corrected)
        _record(session, "refine",
                {"question": question["key"], "in_sql": current,
                 "out_sql": corrected, "used_feedback": used,
                 "feedback_seen": text[:6000]}, prompt=text)
        return corrected, "stop"

    if kind == "draft":
        question = question_for(session, text)
        sql = draft_for(question)
        _set_last_sql(session, question["key"], sql)
        _record(session, "draft",
                {"question": question["key"], "sql": sql}, prompt=text)
        return sql, "stop"

    _record(session, "other", None, prompt=text)
    return ("This endpoint answers review, repair, classification and guard "
            "requests for the grid operations desk."), "stop"


def tool_call_reply(payload):
    """A tool call for a caller that registered tools, in OpenAI wire shape."""
    tools = payload.get("tools") or []
    first = None
    for tool in tools:
        function = (tool or {}).get("function") or {}
        if function.get("name"):
            first = function["name"]
            break
    if first is None:
        return None
    arguments = {}
    if first == "get_table_schema":
        arguments = {"table_name": sorted(schema_map())[0]}
    elif first == "execute_sql":
        arguments = {"query": QUESTIONS[0]["sql"]}
    return {"role": "assistant", "content": None,
            "tool_calls": [{"id": "call_%s_0" % first, "type": "function",
                            "function": {"name": first,
                                         "arguments": json.dumps(arguments)}}]}


# ---------------------------------------------------------------------------
# HTTP layer
# ---------------------------------------------------------------------------

def estimate_tokens(text):
    return max(1, len(text or "") // 4)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _session(self):
        return (self.headers.get("X-Ashford-Session")
                or self.headers.get("x-ashford-session") or "default")

    def _is_grader(self):
        return self.headers.get("X-Grader-Key") == GRADER_KEY

    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass

    # -- GET ---------------------------------------------------------------
    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        one = lambda key, default="": (query.get(key) or [default])[0]

        if parsed.path == "/health":
            return self._send(200, {"status": "ok", "service": "gridd",
                                    "database": os.path.basename(DB_PATH)})

        if parsed.path == "/v1/models":
            return self._send(200, {"object": "list", "data": [
                {"id": MODEL_NAME, "object": "model", "owned_by": "ashford"}]})

        if not parsed.path.startswith(GRADER_PREFIX):
            return self._send(404, {"error": {"message": "not found"}})
        if not self._is_grader():
            return self._send(404, {"error": {"message": "not found"}})

        tail = parsed.path[len(GRADER_PREFIX):]

        if tail == "/trace":
            session = one("run", self._session())
            with _LOCK:
                trace = json.loads(json.dumps(
                    _TRACE.get(session, _blank_trace())))
            trace["concurrency"] = concurrency_report(session)
            return self._send(200, trace)

        if tail == "/oracle":
            return self._send(200, self._oracle(one))

        return self._send(404, {"error": {"message": "not found"}})

    def _oracle(self, one):
        kind = one("kind", "answer")
        if kind == "critique":
            return critique(one("sql"))
        if kind == "guards":
            return guards_report(one("sql"))
        if kind == "route":
            request = one("request")
            category, _ = classify(request)
            return {"category": category,
                    "result": desk_summary(category, run_sql),
                    "desks": DESK_ORDER}
        if kind == "schema":
            return {"schema": schema_map()}
        if kind == "answer":
            question = (BY_KEY.get(one("key"))
                        or match_question(one("q")) or QUESTIONS[0])
            draft = draft_for(question)
            columns, rows, error = try_sql(question["sql"])
            _, _, draft_error = try_sql(draft)
            first_pass = critique(draft)
            second = repair(draft, first_pass["reason"])[0]
            _, _, second_error = try_sql(second)
            return {"key": question["key"], "question": question["question"],
                    "sql": question["sql"], "draft": draft,
                    "draft_error": draft_error,
                    "draft_reason": first_pass["reason"],
                    "after_one_repair": second,
                    "after_one_repair_error": second_error,
                    "result": format_rows(columns, rows) if not error else "",
                    "error": error}
        return {"error": "unknown oracle kind"}

    # -- POST --------------------------------------------------------------
    def do_POST(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw.decode("utf-8"))
        except ValueError:
            return self._send(400, {"error": {"message": "invalid JSON body"}})
        session = self._session()

        if parsed.path in ("/v1/chat/completions", "/chat/completions"):
            return self._chat(session, payload)

        if parsed.path == "/v1/audit/query":
            _record(session, "audit",
                    {"sql": str(payload.get("sql") or "")[:2000],
                     "ok": bool(payload.get("ok")),
                     "error": str(payload.get("error") or "")[:400]})
            return self._send(200, {"recorded": True})

        if parsed.path == GRADER_PREFIX + "/reset":
            if not self._is_grader():
                return self._send(404, {"error": {"message": "not found"}})
            key = (query.get("run") or [session])[0]
            with _LOCK:
                _TRACE.pop(key, None)
                _SESSION.pop(key, None)
            return self._send(200, {"reset": key})

        return self._send(404, {"error": {"message": "not found"}})

    def _chat(self, session, payload):
        messages = payload.get("messages")
        if not isinstance(messages, list) or not messages:
            return self._send(400, {"error": {
                "message": "'messages' is a required property",
                "type": "invalid_request_error"}})
        prompt_text = message_text(messages)
        if payload.get("tools"):
            message = tool_call_reply(payload)
            if message is not None:
                _record(session, "other", None, prompt=prompt_text)
                return self._send(200, self._envelope(
                    payload, message, prompt_text, "tool_calls"))
        content, finish = handle_chat(session, payload)
        return self._send(200, self._envelope(
            payload, {"role": "assistant", "content": content},
            prompt_text, finish))

    def _envelope(self, payload, message, prompt_text, finish_reason):
        completion = message.get("content") or ""
        if message.get("tool_calls"):
            completion = json.dumps(message["tool_calls"])
        prompt_tokens = estimate_tokens(prompt_text)
        completion_tokens = estimate_tokens(completion)
        return {
            "id": "chatcmpl-%s" % uuid.uuid4().hex[:24],
            "object": "chat.completion",
            "created": int(time.time()),
            "model": payload.get("model") or MODEL_NAME,
            "choices": [{"index": 0, "message": message,
                         "logprobs": None, "finish_reason": finish_reason}],
            "usage": {"prompt_tokens": prompt_tokens,
                      "completion_tokens": completion_tokens,
                      "total_tokens": prompt_tokens + completion_tokens},
        }


def main():
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
