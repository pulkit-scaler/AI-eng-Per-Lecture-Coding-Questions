#!/usr/bin/env python3
"""wired - the Orenford Dispatch newsroom wire.

INSTRUCTOR-ONLY FILE. Installed to /opt/orenford-svc as root:root 0700 and never
placed under the learner project.

    GET  /health
    POST /v1/structured   {"schema","prompt","role"}  -> a record of that schema
    POST /v1/chat         {"messages","role"}         -> next assistant turn
    GET  /v1/desk/records?assignment=&question=       -> one desk finding
    GET  /v1/desk/wire?assignment=&question=
    GET  /v1/desk/people?assignment=&question=
    GET  /__on3k/*                                    -> grader only

Every answer is computed from a fixture table keyed by assignment and by the
attempt number carried in the prompt, so the same request always produces the
same answer and no hosted model is involved.
"""
import json
import os
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(os.environ.get("ORENFORD_PORT", "8317"))
ASSIGNMENTS_FILE = os.environ.get("ORENFORD_ASSIGNMENTS",
                                 "/opt/orenford-svc/assignments.json")
GRADER_KEY = "orenford-grader-n3k7"
GRADER_PATH = "/__on3k"

ASSIGNMENT_RE = re.compile(r"\bOR-\d{4}\b")
ATTEMPT_RE = re.compile(r"^Attempt:\s*(\d+)\s*$", re.M)
ROLES = ("planner", "researcher", "writer", "critic")
DESKS = ("records", "wire", "people")

_LOCK = threading.Lock()
_TRACE = {}

# --------------------------------------------------------------------------
# fixture table
# --------------------------------------------------------------------------
# sub_questions: exactly three, and the desk that owns each one is its index.
# critic: the verdict on each pass, clamped at the last entry.
# down: a desk that is out of service for this assignment.
# blocked: a desk whose source may not be cited for this assignment.
ROWS = {
    "OR-4102": {
        "angle": "Who signed off the closures and what the tonnage plan is",
        "sub_questions": [
            "which committee approved closing the two sites and on what date",
            "what the tonnage forecast was before and after the decision",
            "what the site staff were told and when"],
        "critic": ["accept"], "down": None, "blocked": None},
    "OR-4117": {
        "angle": "Whether the charges were lawfully imposed and who holds the money",
        "sub_questions": [
            "when the charging order was made and what signage it required",
            "how much has been taken since January",
            "who the operator answers to on site"],
        "critic": ["accept"], "down": None, "blocked": None},
    "OR-4133": {
        "angle": "What the two closures were actually for",
        "sub_questions": [
            "what the structural inspection after the first closure found",
            "what the contractor billed for between the two closures",
            "what the bridge users were told each time"],
        "critic": ["accept"], "down": None, "blocked": None},
    "OR-4148": {
        "angle": "The real handover figures and the trust response",
        "sub_questions": [
            "what the monthly handover delay figures were across winter",
            "what the trust told the regional board about them",
            "what crews on the ambulance station say changed"],
        "critic": ["accept"], "down": "people", "blocked": None},
    "OR-4155": {
        "angle": "Who owns the quarry now and who has objected",
        "sub_questions": [
            "what the ownership chain on the quarry title is",
            "which objections were registered and by whom",
            "what the parish council was told at its last meeting"],
        "critic": ["accept"], "down": None, "blocked": None},
    "OR-4162": {
        "angle": "The decision trail behind the catchment merger",
        "sub_questions": [
            "which papers record the catchment decision and when",
            "what the admissions numbers did afterwards",
            "what heads and parents were told about consultation"],
        "critic": ["revise"], "down": None, "blocked": None},
    "OR-4171": {
        "angle": "The contract history and the running cost of the delay",
        "sub_questions": [
            "how the refurbishment contract was varied and when",
            "what has been paid out against it to date",
            "what the traders in the hall were promised"],
        "critic": ["accept"], "down": None, "blocked": "records"},
    "OR-4184": {
        "angle": "Who is responsible for the station and what the gap hides",
        "sub_questions": [
            "which body holds the monitoring duty for that station",
            "what the last published readings were before October",
            "what the catchment officers say about the outage"],
        "critic": ["accept"], "down": None, "blocked": None},
    "OR-4190": {
        "angle": "The subsidy history behind the withdrawal",
        "sub_questions": [
            "what subsidy the two routes drew and for how long",
            "what the passenger figures were in the final year",
            "what drivers and passengers were told"],
        "critic": ["revise", "accept"], "down": None, "blocked": None},
    "OR-4199": {
        "angle": "What the safety survey found and what it will cost",
        "sub_questions": [
            "what the August survey recorded about the roof structure",
            "what remedial quotations have been received",
            "what staff and users were told about reopening"],
        "critic": ["accept"], "down": "people", "blocked": None},
    "OR-4210": {
        "angle": "What the two announcements actually paid for",
        "sub_questions": [
            "which committee papers carry each announcement",
            "what was invoiced against the programme in each year",
            "what parish councils were told was coming"],
        "critic": ["revise"], "down": None, "blocked": None},
    "OR-4224": {
        "angle": "Who authorises the payments on a closed building",
        "sub_questions": [
            "which budget line the maintenance charge is drawn from",
            "what the payment schedule since closure shows",
            "who signs the monthly authorisation"],
        "critic": ["accept"], "down": None, "blocked": "records"},
    "OR-4238": {
        "angle": "The award timeline and who signed it off",
        "sub_questions": [
            "when the contract was awarded and against which notice",
            "what the value was and how it was split",
            "who on the highways side signed it off"],
        "critic": ["revise", "accept"], "down": None, "blocked": None},
}

DESK_DETAIL = {
    "records": "held in the minute book and the signed decision notice",
    "wire": "carried in the published figures and the correspondence log",
    "people": "given on the record by two named officers",
}

with open(ASSIGNMENTS_FILE) as handle:
    BRIEFS = {a["assignment"]: a["brief"]
              for a in json.load(handle)["assignments"]}


def digits(assignment):
    return re.sub(r"\D", "", assignment or "") or "0"


def source_id(assignment, desk):
    return "SRC-%s-%s" % (digits(assignment), desk[:3].upper())


def finding_for(assignment, desk, index):
    row = ROWS.get(assignment)
    if row is None:
        return None
    question = row["sub_questions"][index]
    return {
        "assignment": assignment,
        "desk": desk,
        "sub_question": question,
        "source_id": source_id(assignment, desk),
        "note": "%s desk: %s, %s" % (desk, question, DESK_DETAIL[desk]),
        "blocked": row["blocked"] == desk,
    }


def plan_for(assignment):
    row = ROWS.get(assignment)
    if row is None:
        return None
    return {"assignment": assignment, "angle": row["angle"],
            "sub_questions": list(row["sub_questions"])}


def critic_verdict(assignment, attempt):
    row = ROWS.get(assignment)
    if row is None:
        return None
    verdicts = row["critic"]
    verdict = verdicts[min(attempt, len(verdicts)) - 1]
    if verdict == "accept":
        return {"verdict": "accept", "issues": [], "instructions": ""}
    return {
        "verdict": "revise",
        "issues": ["the angle is not carried through the sections",
                   "no section answers sub-question %d" % (attempt % 3 + 1)],
        "instructions": "tie every section back to a cited finding",
    }


def draft_for(assignment, attempt, cited):
    """The writer output: a headline, three sections, and one claim per source."""
    row = ROWS.get(assignment)
    if row is None:
        return None
    return {
        "assignment": assignment,
        "headline": "%s: %s" % (assignment, row["angle"]),
        "sections": [
            {"heading": question[:60],
             "body": "Draft %d. %s" % (attempt, question)}
            for question in row["sub_questions"]
        ],
        "claims": [{"claim": "on %s, the record shows what was asked"
                    % item["sub_question"], "source_id": item["source_id"]}
                   for item in cited],
    }


def brief_expectation(assignment, max_revisions):
    """What a correct newsroom produces for this assignment."""
    row = ROWS.get(assignment)
    if row is None:
        return None
    findings = []
    excluded = []
    answered = 0
    for index, desk in enumerate(DESKS):
        if row["down"] == desk:
            excluded.append({"desk": desk, "reason": "desk unavailable"})
            continue
        answered += 1
        item = finding_for(assignment, desk, index)
        if item["blocked"]:
            excluded.append({"desk": desk, "source_id": item["source_id"],
                             "reason": "source may not be cited"})
            continue
        findings.append(item)

    revisions = 0
    while revisions < max_revisions:
        if critic_verdict(assignment, revisions + 1)["verdict"] == "accept":
            break
        revisions += 1
    last = critic_verdict(assignment, revisions + 1)
    reservations = last["issues"] if last["verdict"] != "accept" else []
    status = "published_with_reservations" if reservations else "published"

    sources = sorted({item["source_id"] for item in findings})
    return {
        "assignment": assignment,
        "status": status,
        "sub_questions": list(row["sub_questions"]),
        "finding_count": len(findings),
        "desks": sorted(item["desk"] for item in findings),
        "sources": sources,
        "claim_count": len(findings),
        "excluded_desks": sorted(item["desk"] for item in excluded),
        "revisions": revisions,
        "reservations": reservations,
        # One researcher call per desk that answered. On an assignment with a
        # source that may not be cited the figure is not decided by the rules
        # alone - a service may read the record and then drop it, or notice the
        # flag on the desk answer and never ask - so the accounting check must
        # stay on assignments where every desk answers and nothing is barred.
        # build.sh asserts that it does.
        "calls": {"planner": 1, "researcher": answered,
                  "writer": revisions + 1, "critic": revisions + 1},
        "total_calls": 1 + answered + 2 * (revisions + 1),
    }


def blank_trace():
    return {"total": 0, "via_kit": 0, "desks": [],
            "roles": {role: 0 for role in ROLES}, "schemas": []}


def record_call(run, role, via_kit):
    with _LOCK:
        entry = _TRACE.setdefault(run, blank_trace())
        entry["total"] += 1
        if via_kit:
            entry["via_kit"] += 1
        if role in entry["roles"]:
            entry["roles"][role] += 1


def record_list(run, field, value):
    with _LOCK:
        entry = _TRACE.setdefault(run, blank_trace())
        entry[field].append(value)


def attempt_of(prompt):
    found = ATTEMPT_RE.search(prompt or "")
    return max(1, int(found.group(1))) if found else 1


def assignment_of(prompt):
    for line in (prompt or "").splitlines():
        if line.strip().lower().startswith("assignment:"):
            found = ASSIGNMENT_RE.search(line)
            if found:
                return found.group(0)
    found = ASSIGNMENT_RE.search(prompt or "")
    return found.group(0) if found else None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def _run(self):
        return self.headers.get("X-Run-Id", "local")

    def _role(self):
        return self.headers.get("X-Role", "unknown")

    def _via_kit(self):
        return self.headers.get("X-Orenford-Kit", "") == "1"

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

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        path = parsed.path

        if path == "/health":
            self._send(200, {"status": "ok", "assignments": len(BRIEFS)})
            return

        if path.startswith("/v1/desk/"):
            desk = path.rsplit("/", 1)[-1]
            if desk not in DESKS:
                self._send(404, {"error": "no such desk"})
                return
            assignment = (query.get("assignment") or [""])[0]
            question = (query.get("question") or [""])[0]
            row = ROWS.get(assignment)
            if row is None:
                self._send(404, {"error": "unknown assignment"})
                return
            record_list(self._run(), "desks", desk)
            if row["down"] == desk:
                self._send(503, {"error": "%s desk is not answering" % desk})
                return
            index = DESKS.index(desk)
            if question and question not in row["sub_questions"]:
                self._send(422, {"error": "that is not one of the questions on "
                                          "this assignment"})
                return
            self._send(200, finding_for(assignment, desk, index))
            return

        if path.startswith(GRADER_PATH):
            if not self._authorised():
                self._send(403, {"error": "forbidden"})
                return
            leaf = path[len(GRADER_PATH):]
            if leaf == "/trace":
                run = (query.get("run") or ["local"])[0]
                with _LOCK:
                    entry = _TRACE.get(run) or blank_trace()
                    self._send(200, json.loads(json.dumps(entry)))
                return
            if leaf == "/oracle":
                assignment = (query.get("assignment") or [""])[0]
                kind = (query.get("kind") or ["brief"])[0]
                if kind == "brief":
                    cap = int((query.get("max") or ["2"])[0])
                    self._send(200, brief_expectation(assignment, cap) or {})
                    return
                if kind == "plan":
                    self._send(200, plan_for(assignment) or {})
                    return
                self._send(400, {"error": "unknown oracle kind"})
                return
            self._send(404, {"error": "not found"})
            return

        self._send(404, {"error": "not found"})

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
        role = self._role()
        via = self._via_kit()

        if path == "/v1/structured":
            schema = str(body.get("schema") or "")
            prompt = str(body.get("prompt") or "")
            assignment = assignment_of(prompt)
            attempt = attempt_of(prompt)
            record_call(run, role, via)
            record_list(run, "schemas", schema)
            if assignment is None or assignment not in ROWS:
                self._send(404, {"error": "no assignment in that request"})
                return
            if schema.startswith("Plan") or schema.startswith("Assignment"):
                self._send(200, plan_for(assignment))
                return
            if schema.startswith("Finding") or schema.startswith("Desk"):
                desk = str(body.get("desk") or "")
                if desk not in DESKS:
                    self._send(422, {"error": "which desk is this finding "
                                              "from - desk has to be one of "
                                              "%s" % ", ".join(DESKS)})
                    return
                self._send(200, finding_for(assignment, desk,
                                            DESKS.index(desk)))
                return
            if schema.startswith("Draft") or schema.startswith("Brief"):
                cited = body.get("cited") or []
                self._send(200, draft_for(assignment, attempt, cited))
                return
            if schema.startswith("Critique") or schema.startswith("Review"):
                self._send(200, critic_verdict(assignment, attempt))
                return
            # Dispatch is by model name, so a record nobody recognises is
            # almost always a model called something else. Say that outright:
            # the learner is otherwise left staring at a request that looks
            # perfectly well formed.
            self._send(422, {"error": "the desk does not fill in a record "
                                      "called %s - it answers Plan, Finding, "
                                      "Draft and Critique" % (schema or "?")})
            return

        if path == "/v1/chat":
            record_call(run, role, via)
            messages = body.get("messages") or []
            last = ""
            for message in messages:
                if message.get("role") in ("human", "user"):
                    last = message.get("content") or ""
            assignment = assignment_of(last) or "an unnamed assignment"
            self._send(200, {"type": "content",
                             "content": "Noted on %s." % assignment})
            return

        self._send(404, {"error": "not found"})


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.daemon_threads = True
    print("orenford wire listening on %d with %d assignments"
          % (PORT, len(BRIEFS)), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
