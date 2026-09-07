#!/usr/bin/env python3
"""signalsvc - the Redcliffe Signals control desk.

INSTRUCTOR-ONLY FILE. Installed to /opt/redcliffe-svc as root:root 0700 and
never placed under the learner project.

    GET  /health
    POST /v1/think          {"prompt","step"}    -> the next thought and action
    POST /v1/judge          {"draft","attempt"}  -> a verdict on a draft
    POST /v1/revise         {"draft","attempt","critique"} -> a revised draft
    GET  /v1/tool/signal_status?box=
    GET  /v1/tool/possession_window?section=
    GET  /v1/tool/fault_history?asset=
    GET  /__rc9v/*                               -> grader only

Every reply is computed from a fixture table keyed by the question and by the
step or attempt number carried in the request, so the same run always takes the
same path and no hosted model is involved.
"""
import json
import os
import re
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(os.environ.get("REDCLIFFE_PORT", "8622"))
GRADER_KEY = "redcliffe-grader-rc9v"
GRADER_PATH = "/__rc9v"

_LOCK = threading.Lock()
_TRACE = {}

# --------------------------------------------------------------------------
# the desk data
# --------------------------------------------------------------------------
SIGNAL_BOXES = {
    "RC-BOX-11": {"state": "clear", "last_reset": "2026-03-02", "aspect": "green"},
    "RC-BOX-14": {"state": "degraded", "last_reset": "2026-03-08", "aspect": "double yellow"},
    "RC-BOX-19": {"state": "failed", "last_reset": "2026-03-11", "aspect": "red"},
    "RC-BOX-23": {"state": "clear", "last_reset": "2026-02-27", "aspect": "green"},
}
POSSESSIONS = {
    "SEC-4": {"window": "01:20 to 04:40", "nights": 3, "granted": True},
    "SEC-7": {"window": "00:50 to 05:10", "nights": 5, "granted": True},
    "SEC-9": {"window": "none", "nights": 0, "granted": False},
}
FAULTS = {
    "AST-2210": {"faults_12m": 7, "worst": "point machine sticking"},
    "AST-2244": {"faults_12m": 1, "worst": "track circuit dropout"},
    "AST-2261": {"faults_12m": 14, "worst": "axle counter reset loop"},
}

TOOLS = ("signal_status", "possession_window", "fault_history")

# One row per graded question. `plan` is the sequence of actions a correct loop
# takes; a plan that runs out without an answer is a question the desk cannot
# settle, and the loop is expected to say so rather than guess.
QUESTIONS = {
    "why is RC-BOX-19 showing red": {
        "plan": [("signal_status", {"box": "RC-BOX-19"}),
                 ("fault_history", {"asset": "AST-2261"})],
        "answer": ("RC-BOX-19 is failed and showing red. Its asset AST-2261 has "
                   "14 faults in twelve months, worst of them an axle counter "
                   "reset loop."),
        "answerable": True,
    },
    "can AST-2210 be swapped out under possession on SEC-4": {
        "plan": [("fault_history", {"asset": "AST-2210"}),
                 ("possession_window", {"section": "SEC-4"})],
        "answer": ("AST-2210 has 7 faults in twelve months, worst of them a "
                   "point machine sticking, and SEC-4 has a granted possession "
                   "of 01:20 to 04:40 over 3 nights. The swap fits."),
        "answerable": True,
    },
    "what aspect is RC-BOX-14 showing": {
        "plan": [("signal_status", {"box": "RC-BOX-14"})],
        "answer": ("RC-BOX-14 is degraded and showing double yellow, last reset "
                   "on 2026-03-08."),
        "answerable": True,
    },
    "who signed off the SEC-9 possession last winter": {
        # Nothing on the desk records a signatory. A correct loop runs out of
        # steps and says so.
        "plan": [("possession_window", {"section": "SEC-9"}),
                 ("fault_history", {"asset": "AST-2244"}),
                 ("signal_status", {"box": "RC-BOX-23"})],
        "answer": None,
        "answerable": False,
    },
}

# Drafts the night desk sends for review, and how the reviewer treats them.
DRAFTS = {
    "RC-D-101": {"verdicts": ["accept"],
                 "issues": [],
                 "text": "Possession on SEC-4 confirmed for three nights."},
    "RC-D-118": {"verdicts": ["revise", "accept"],
                 "issues": ["the asset reference is missing"],
                 "text": "Point machine to be swapped during the next window."},
    "RC-D-125": {"verdicts": ["revise"],
                 "issues": ["no possession window is quoted",
                            "the asset reference is missing"],
                 "text": "Axle counter to be reset when the section is clear."},
}


def blank_trace():
    return {"think": 0, "judge": 0, "revise": 0, "tools": [], "steps": [],
            "answered": 0}


def record(run, field, value=None):
    with _LOCK:
        entry = _TRACE.setdefault(run, blank_trace())
        if field in ("think", "judge", "revise", "answered"):
            entry[field] += 1
        else:
            entry[field].append(value)


def normalise(text):
    return " ".join(re.sub(r"[^a-z0-9 -]", " ", (text or "").lower()).split())


def question_row(prompt):
    wanted = normalise(prompt)
    for question, row in QUESTIONS.items():
        if normalise(question) in wanted:
            return question, row
    return None, None


def draft_row(draft_id):
    return DRAFTS.get((draft_id or "").strip().upper())


def think(prompt, step):
    """The next move: an action to take, or the final answer."""
    question, row = question_row(prompt)
    if row is None:
        return {"kind": "final", "thought": "Nothing on the desk matches that.",
                "answer": None, "answerable": False}
    plan = row["plan"]
    index = max(1, int(step)) - 1
    if index < len(plan):
        tool, args = plan[index]
        return {
            "kind": "action",
            "thought": "I still need what %s holds before I can answer."
                       % tool.replace("_", " "),
            "action": tool,
            "action_input": args,
        }
    if row["answerable"]:
        return {"kind": "final",
                "thought": "I have everything the desk records on this.",
                "answer": row["answer"], "answerable": True}
    return {"kind": "final",
            "thought": "The desk does not record that, and I have run out of "
                       "places to look.",
            "answer": None, "answerable": False}


def judge(draft_id, attempt):
    row = draft_row(draft_id)
    if row is None:
        return None
    verdicts = row["verdicts"]
    verdict = verdicts[min(attempt, len(verdicts)) - 1]
    if verdict == "accept":
        return {"verdict": "accept", "issues": [],
                "instruction": ""}
    return {"verdict": "revise", "issues": list(row["issues"]),
            "instruction": "quote the asset reference and the window"}


def revise(draft_id, attempt, critique):
    row = draft_row(draft_id)
    if row is None:
        return None
    return {"draft_id": (draft_id or "").upper(),
            "text": "%s (revision %d addressing: %s)"
                    % (row["text"], attempt, "; ".join(critique or []) or "nothing")}


def react_expectation(question, max_steps):
    """What a correct loop does with this question."""
    row = QUESTIONS.get(question)
    if row is None:
        return None
    plan = row["plan"][:max_steps]
    used = len(plan)
    answered = row["answerable"] and used == len(row["plan"])
    # One think per action, plus the closing think that produces the verdict.
    thinks = used + 1 if answered or used < max_steps else max_steps
    return {
        "question": question,
        "steps": used,
        "actions": [name for name, _ in plan],
        "answered": bool(answered),
        "answer": row["answer"] if answered else None,
        "think_calls": thinks,
    }


def reflect_expectation(draft_id, max_rounds):
    row = draft_row(draft_id)
    if row is None:
        return None
    revisions = 0
    while revisions < max_rounds:
        if judge(draft_id, revisions + 1)["verdict"] == "accept":
            break
        revisions += 1
    final = judge(draft_id, revisions + 1)
    accepted = final["verdict"] == "accept"
    return {
        "draft_id": draft_id.upper(),
        "revisions": revisions,
        "accepted": accepted,
        "outstanding": [] if accepted else final["issues"],
        "judge_calls": revisions + 1,
        "revise_calls": revisions,
    }


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def _run(self):
        return self.headers.get("X-Run-Id", "local")

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
            self._send(200, {"status": "ok", "questions": len(QUESTIONS)})
            return

        if path.startswith("/v1/tool/"):
            name = path.rsplit("/", 1)[-1]
            if name not in TOOLS:
                self._send(404, {"error": "no such tool"})
                return
            record(self._run(), "tools", name)
            if name == "signal_status":
                key = (query.get("box") or [""])[0].upper()
                row = SIGNAL_BOXES.get(key)
                if row is None:
                    self._send(404, {"error": "no signal box %s" % key})
                    return
                self._send(200, dict(row, box=key))
                return
            if name == "possession_window":
                key = (query.get("section") or [""])[0].upper()
                row = POSSESSIONS.get(key)
                if row is None:
                    self._send(404, {"error": "no section %s" % key})
                    return
                self._send(200, dict(row, section=key))
                return
            key = (query.get("asset") or [""])[0].upper()
            row = FAULTS.get(key)
            if row is None:
                self._send(404, {"error": "no asset %s" % key})
                return
            self._send(200, dict(row, asset=key))
            return

        if path.startswith(GRADER_PATH):
            if not self._authorised():
                self._send(403, {"error": "forbidden"})
                return
            leaf = path[len(GRADER_PATH):]
            if leaf == "/trace":
                run = (query.get("run") or ["local"])[0]
                with _LOCK:
                    self._send(200, json.loads(json.dumps(
                        _TRACE.get(run) or blank_trace())))
                return
            if leaf == "/oracle":
                kind = (query.get("kind") or [""])[0]
                if kind == "react":
                    question = (query.get("question") or [""])[0]
                    cap = int((query.get("max") or ["4"])[0])
                    self._send(200, react_expectation(question, cap) or {})
                    return
                if kind == "reflect":
                    draft = (query.get("draft") or [""])[0]
                    cap = int((query.get("max") or ["2"])[0])
                    self._send(200, reflect_expectation(draft, cap) or {})
                    return
                if kind == "questions":
                    self._send(200, {"questions": sorted(QUESTIONS)})
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

        if path == "/v1/think":
            record(run, "think")
            step = int(body.get("step") or 1)
            record(run, "steps", step)
            answer = think(str(body.get("prompt") or ""), step)
            if answer.get("kind") == "final":
                record(run, "answered")
            self._send(200, answer)
            return

        if path == "/v1/judge":
            record(run, "judge")
            verdict = judge(str(body.get("draft") or ""),
                            int(body.get("attempt") or 1))
            if verdict is None:
                self._send(404, {"error": "no such draft"})
            else:
                self._send(200, verdict)
            return

        if path == "/v1/revise":
            record(run, "revise")
            revised = revise(str(body.get("draft") or ""),
                             int(body.get("attempt") or 1),
                             body.get("critique") or [])
            if revised is None:
                self._send(404, {"error": "no such draft"})
            else:
                self._send(200, revised)
            return

        self._send(404, {"error": "not found"})


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.daemon_threads = True
    print("redcliffe signals desk listening on %d with %d questions"
          % (PORT, len(QUESTIONS)), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
