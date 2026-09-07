#!/usr/bin/env python3
"""claimsvc - the Westmere claims desk service.

INSTRUCTOR-ONLY FILE. Installed to /opt/westmere-svc as root:root 0700 and never
placed under the learner project.

    GET  /health
    POST /v1/structured   {"schema","prompt"}   -> a record of that schema
    POST /v1/chat         {"messages","tools"}  -> next assistant turn
    GET  /v1/data/policy?claim=...              -> policy and settlement cap
    GET  /v1/data/payout?category=&severity=    -> indicative payout band
    GET  /v1/data/fraud?policy=...              -> prior-claim history
    GET  /__wm5r/*                              -> grader only, X-Grader-Key

Every reply is computed from a fixture table keyed by claim identifier and by
the attempt number carried in the prompt, so the same request always produces
the same answer and no hosted model is involved.
"""
import json
import os
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(os.environ.get("WESTMERE_PORT", "8571"))
CLAIMS_FILE = os.environ.get("WESTMERE_CLAIMS", "/opt/westmere-svc/claims.json")
GRADER_KEY = "westmere-grader-w5r2"
GRADER_PATH = "/__wm5r"

CLAIM_RE = re.compile(r"\bWM-\d{4}\b")
ATTEMPT_RE = re.compile(r"^Attempt:\s*(\d+)\s*$", re.M)
POLICY_RE = re.compile(r"\bWM-P-\d{4}\b")

_LOCK = threading.Lock()
_TRACE = {}

# --------------------------------------------------------------------------
# fixture table - one row per claim, everything the desk will ever say
# --------------------------------------------------------------------------
# confidence is a list indexed by attempt number (clamped at the last entry),
# which is how asking again can resolve a first-pass doubt without any state
# living in this process.
RECORDS = {
    "WM-3102": {"category": "collision", "severity": "low", "needs_adjuster": False,
                "fraud_score": 0.05, "confidence": [0.88],
                "summary": "Car park scuff, third party admitted fault, car drivable."},
    "WM-3117": {"category": "glass", "severity": "low", "needs_adjuster": False,
                "fraud_score": 0.02, "confidence": [0.91],
                "summary": "Small windscreen chip outside the swept area."},
    "WM-3126": {"category": "theft", "severity": "medium", "needs_adjuster": False,
                "fraud_score": 0.76, "confidence": [0.86],
                "summary": "Van missing from a locked yard, padlock undamaged, tracker off beforehand."},
    "WM-3140": {"category": "collision", "severity": "high", "needs_adjuster": True,
                "fraud_score": 0.11, "confidence": [0.86],
                "summary": "Junction side impact, vehicle recovered, occupant hospitalised."},
    "WM-3168": {"category": "theft", "severity": "high", "needs_adjuster": True,
                "fraud_score": 0.82, "confidence": [0.79],
                "summary": "Overnight driveway theft, no forced entry, repeat loss on the policy."},
    "WM-3185": {"category": "weather", "severity": "medium", "needs_adjuster": False,
                "fraud_score": 0.08, "confidence": [0.90],
                "summary": "Storm hail damage to roof and bonnet, photographs consistent."},
    "WM-3204": {"category": "collision", "severity": "medium", "needs_adjuster": False,
                "fraud_score": 0.19, "confidence": [0.41, 0.83],
                "summary": "Low speed shunt, accounts differ on who was stationary."},
    "WM-3231": {"category": "collision", "severity": "medium", "needs_adjuster": False,
                "fraud_score": 0.20, "confidence": [0.38],
                "summary": "Kerbing damage to two wheels, incident date unclear."},
    "WM-3258": {"category": "glass", "severity": "low", "needs_adjuster": False,
                "fraud_score": 0.03, "confidence": [0.93],
                "summary": "Passenger window broken by a branch, approved fitter receipt held."},
    "WM-3277": {"category": "collision", "severity": "critical", "needs_adjuster": True,
                "fraud_score": 0.30, "confidence": [0.87],
                "summary": "Head on rural collision, both vehicles written off, long hire exposure."},
    "WM-3290": {"category": "weather", "severity": "high", "needs_adjuster": True,
                "fraud_score": 0.12, "confidence": [0.88],
                "summary": "Flood water above the sills, vehicle will not start."},
    "WM-3315": {"category": "collision", "severity": "low", "needs_adjuster": False,
                "fraud_score": 0.06, "confidence": [0.89],
                "summary": "Wing mirror housing cracked by a passing van, glass intact."},
    "WM-3342": {"category": "theft", "severity": "medium", "needs_adjuster": False,
                "fraud_score": 0.71, "confidence": [0.85],
                "summary": "Motorcycle missing from a shared store, lock unmarked."},
}

# settlement cap per policy, and the amount the desk quotes on each attempt
POLICY = {
    "WM-3102": {"policy": "WM-P-4410", "cap": 1800},
    "WM-3117": {"policy": "WM-P-4418", "cap": 900},
    "WM-3126": {"policy": "WM-P-4421", "cap": 9800},
    "WM-3140": {"policy": "WM-P-4425", "cap": 12500},
    "WM-3168": {"policy": "WM-P-4431", "cap": 16000},
    "WM-3185": {"policy": "WM-P-4437", "cap": 4200},
    "WM-3204": {"policy": "WM-P-4442", "cap": 3100},
    "WM-3231": {"policy": "WM-P-4450", "cap": 21000},
    "WM-3258": {"policy": "WM-P-4457", "cap": 1400},
    "WM-3277": {"policy": "WM-P-4463", "cap": 9000},
    "WM-3290": {"policy": "WM-P-4469", "cap": 7600},
    "WM-3315": {"policy": "WM-P-4474", "cap": 600},
    "WM-3342": {"policy": "WM-P-4480", "cap": 5400},
}

QUOTES = {
    "WM-3102": [1240],
    "WM-3117": [610],
    "WM-3126": [8450],
    "WM-3140": [11800],
    "WM-3168": [15200],
    "WM-3185": [3650],
    "WM-3204": [4900, 3050],
    "WM-3231": [26400, 24100, 22800],
    "WM-3258": [1180],
    "WM-3277": [14300, 13100, 12750],
    "WM-3290": [7100],
    "WM-3315": [540],
    "WM-3342": [4880],
}

PAYOUT_BAND = {
    ("collision", "low"): 900, ("collision", "medium"): 2600,
    ("collision", "high"): 9400, ("collision", "critical"): 18500,
    ("theft", "low"): 1500, ("theft", "medium"): 5200,
    ("theft", "high"): 12800, ("theft", "critical"): 23000,
    ("weather", "low"): 700, ("weather", "medium"): 2100,
    ("weather", "high"): 6900, ("weather", "critical"): 14200,
    ("glass", "low"): 480, ("glass", "medium"): 1150,
    ("glass", "high"): 2400, ("glass", "critical"): 3900,
}

PRIOR_CLAIMS = {
    "WM-P-4421": 3, "WM-P-4431": 3, "WM-P-4450": 4, "WM-P-4480": 2,
    "WM-P-4442": 1,
}

with open(CLAIMS_FILE) as handle:
    NARRATIVES = {c["claim_id"]: c["narrative"]
                  for c in json.load(handle)["claims"]}


def blank_trace():
    return {"structured": 0, "chat": 0, "tools": [], "schemas": [],
            "total": 0, "via_kit": 0, "claims": []}


def record_call(run, kind, via_kit):
    """One model call. total and via_kit only ever move here."""
    with _LOCK:
        entry = _TRACE.setdefault(run, blank_trace())
        entry["total"] += 1
        if via_kit:
            entry["via_kit"] += 1
        entry[kind] += 1


def record_list(run, field, value):
    """Append to one of the trace lists without touching the call counts."""
    with _LOCK:
        entry = _TRACE.setdefault(run, blank_trace())
        entry[field].append(value)


def attempt_of(prompt):
    found = ATTEMPT_RE.search(prompt or "")
    return max(1, int(found.group(1))) if found else 1


def claim_of(prompt):
    """The claim the request is about.

    The identifier on the first `Claim:` line wins. A narrative that mentions
    some other claim later on does not change whose file this is.
    """
    for line in (prompt or "").splitlines():
        if line.strip().lower().startswith("claim:"):
            found = CLAIM_RE.search(line)
            if found:
                return found.group(0)
    found = CLAIM_RE.search(prompt or "")
    return found.group(0) if found else None


def pick(sequence, attempt):
    if not sequence:
        return None
    return sequence[min(attempt, len(sequence)) - 1]


def triage_record(claim_id, attempt):
    row = RECORDS.get(claim_id)
    if row is None:
        return None
    return {
        "claim_id": claim_id,
        "category": row["category"],
        "severity": row["severity"],
        "needs_adjuster": row["needs_adjuster"],
        "fraud_score": row["fraud_score"],
        "confidence": pick(row["confidence"], attempt),
        "summary": row["summary"],
    }


def settlement_quote(claim_id, attempt):
    if claim_id not in QUOTES:
        return None
    return {
        "claim_id": claim_id,
        "amount": pick(QUOTES[claim_id], attempt),
        "basis": "attempt %d indicative settlement for %s" % (attempt, claim_id),
    }


CONFIDENCE_FLOOR = 0.55
BRANCH_TOOL = {"fast_track": "payout_table", "adjuster": "policy_lookup",
               "fraud_review": "fraud_history"}


def route_expectation(claim_id, max_attempts, ceiling):
    """What a correct desk graph ends up doing with this claim.

    One triage visit per attempt, then one classify visit, then one branch
    visit. The audit list records all of them; the step counter is clamped at
    the ceiling, so on a claim that uses every attempt the two disagree - which
    is the whole point of giving that key its own reducer.
    """
    row = RECORDS.get(claim_id)
    if row is None:
        return None
    attempt = 1
    while (pick(row["confidence"], attempt) < CONFIDENCE_FLOOR
           and attempt < max_attempts):
        attempt += 1
    exhausted = pick(row["confidence"], attempt) < CONFIDENCE_FLOOR
    if exhausted:
        branch = "adjuster"
    elif row["fraud_score"] >= 0.7:
        branch = "fraud_review"
    elif row["severity"] in ("high", "critical") or row["needs_adjuster"]:
        branch = "adjuster"
    else:
        branch = "fast_track"
    visits = attempt + 2
    return {"claim_id": claim_id, "branch": branch, "attempts": attempt,
            "visits": visits, "steps": min(visits, ceiling),
            "tool": BRANCH_TOOL[branch], "exhausted": exhausted,
            "confidence": pick(row["confidence"], attempt)}


def settle_expectation(claim_id, max_attempts):
    cap = POLICY[claim_id]["cap"]
    notes = []
    for attempt in range(1, max_attempts + 1):
        quote = settlement_quote(claim_id, attempt)
        amount = quote["amount"]
        if 0 < amount <= cap:
            return {"claim_id": claim_id, "attempts": attempt,
                    "status": "approved", "amount": amount, "notes": notes,
                    "cap": cap}
        notes.append("attempt %d quoted %d over the %d settlement cap"
                     % (attempt, amount, cap))
    return {"claim_id": claim_id, "attempts": max_attempts,
            "status": "escalated", "amount": None, "notes": notes, "cap": cap}


def chat_reply(messages):
    """The desk reply to the last human turn, given everything before it."""
    human = [m for m in messages if m.get("role") in ("human", "user")]
    last = (human[-1].get("content") if human else "") or ""
    lowered = last.lower()
    earlier = " ".join((m.get("content") or "") for m in messages[:-1])

    if "policy" in lowered and ("which" in lowered or "what" in lowered):
        found = POLICY_RE.search(earlier)
        if found:
            return ("Your policy on file is %s. I have that from earlier in "
                    "this conversation." % found.group(0))
        return ("I have no policy number in this conversation yet. Please give "
                "me the policy reference.")
    if "vehicle" in lowered and ("which" in lowered or "what" in lowered):
        found = re.search(r"\b(19|20)\d{2}\s+\w+", earlier)
        if found:
            return "You described a %s earlier in this conversation." % found.group(0)
        return "I have no vehicle details in this conversation yet."
    found = POLICY_RE.search(last)
    if found:
        return ("Noted, policy %s. Tell me what happened and I will open a "
                "file." % found.group(0))
    return "Noted. Anything else to add to the file?"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def _run(self):
        return self.headers.get("X-Run-Id", "local")

    def _via_kit(self):
        return self.headers.get("X-Westmere-Kit", "") == "1"

    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _authorised(self):
        return self.headers.get("X-Grader-Key", "") == GRADER_KEY

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            return json.loads(raw.decode("utf-8") or "{}")
        except ValueError:
            return {}

    # ---------------------------------------------------------------- GET
    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        path = parsed.path

        if path == "/health":
            self._send(200, {"status": "ok", "claims": len(NARRATIVES)})
            return

        if path == "/v1/data/policy":
            claim = (query.get("claim") or [""])[0]
            row = POLICY.get(claim)
            record_list(self._run(), "tools", "policy_lookup")
            if row is None:
                self._send(404, {"error": "unknown claim"})
            else:
                self._send(200, {"claim_id": claim, "policy": row["policy"],
                                 "cap": row["cap"]})
            return

        if path == "/v1/data/payout":
            category = (query.get("category") or [""])[0]
            severity = (query.get("severity") or [""])[0]
            record_list(self._run(), "tools", "payout_table")
            band = PAYOUT_BAND.get((category, severity))
            if band is None:
                self._send(404, {"error": "unknown band"})
            else:
                self._send(200, {"category": category, "severity": severity,
                                 "band": band})
            return

        if path == "/v1/data/fraud":
            policy = (query.get("policy") or [""])[0]
            record_list(self._run(), "tools", "fraud_history")
            self._send(200, {"policy": policy,
                             "prior_claims": PRIOR_CLAIMS.get(policy, 0)})
            return

        if path.startswith(GRADER_PATH):
            if not self._authorised():
                self._send(403, {"error": "forbidden"})
                return
            leaf = path[len(GRADER_PATH):]
            if leaf == "/trace":
                run = (query.get("run") or ["local"])[0]
                with _LOCK:
                    self._send(200, dict(_TRACE.get(run) or blank_trace()))
                return
            if leaf == "/oracle":
                kind = (query.get("kind") or [""])[0]
                claim = (query.get("claim") or [""])[0]
                if kind == "triage":
                    attempt = int((query.get("attempt") or ["1"])[0])
                    self._send(200, triage_record(claim, attempt) or {})
                    return
                if kind == "route":
                    tries = int((query.get("max") or ["3"])[0])
                    ceiling = int((query.get("ceiling") or ["4"])[0])
                    self._send(200,
                               route_expectation(claim, tries, ceiling) or {})
                    return
                if kind == "settle":
                    tries = int((query.get("max") or ["3"])[0])
                    self._send(200, settle_expectation(claim, tries) or {})
                    return
                self._send(400, {"error": "unknown oracle kind"})
                return
            self._send(404, {"error": "not found"})
            return

        self._send(404, {"error": "not found"})

    # --------------------------------------------------------------- POST
    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        if path == GRADER_PATH + "/reset":
            if not self._authorised():
                self._send(403, {"error": "forbidden"})
                return
            run = (query.get("run") or ["local"])[0]
            with _LOCK:
                _TRACE[run] = blank_trace()
            self._send(200, {"status": "reset", "run": run})
            return

        body = self._body()
        run = self._run()
        via = self._via_kit()

        if path == "/v1/structured":
            schema = str(body.get("schema") or "")
            prompt = str(body.get("prompt") or "")
            claim = claim_of(prompt)
            attempt = attempt_of(prompt)
            record_call(run, "structured", via)
            record_list(run, "schemas", schema)
            if claim:
                record_list(run, "claims", claim)
            if schema.startswith("Triage"):
                record = triage_record(claim, attempt)
            elif schema.startswith("Settlement"):
                record = settlement_quote(claim, attempt)
            else:
                record = None
            if record is None:
                self._send(404, {"error": "no record for %s under %s"
                                 % (claim, schema or "an unnamed schema")})
                return
            self._send(200, record)
            return

        if path == "/v1/chat":
            record_call(run, "chat", via)
            messages = body.get("messages") or []
            self._send(200, {"type": "content", "content": chat_reply(messages)})
            return

        self._send(404, {"error": "not found"})


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.daemon_threads = True
    print("westmere claims desk listening on %d with %d claims"
          % (PORT, len(NARRATIVES)), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
