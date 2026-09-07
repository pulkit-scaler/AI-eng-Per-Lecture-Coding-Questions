#!/usr/bin/env python3
"""Bellhaven review desk - the two grading models plus the prediction pool.

Root-only. Installed outside the learner project. Two model families answer
grading prompts, and the desk keeps a per-run record of what each one was
actually shown, so a caller can tell what reached the model rather than what
the caller meant to send.

Standard library only.
"""
import json
import os
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(os.environ.get("BELLHAVEN_PORT", "8755"))
GRADER_KEY = "bellhaven-grader-bh4r"
GRADER_PREFIX = "/__bh4r"

RUBRIC_KEYS = ("correct", "reasoning_quality", "used_tool_appropriately",
               "explanation")

_LOCK = threading.Lock()
_RUNS = {}


def _blank_run():
    return {"calls": [], "families": [], "unmatched": 0}


def _run(run_id):
    return _RUNS.setdefault(run_id or "default", _blank_run())


def _record(problem, gold, prediction, observation, subject, level,
            stress=False, ident=None):
    return {
        "id": ident,
        "subject": subject,
        "level": level,
        "problem": problem,
        "gold_answer": gold,
        "predicted_answer": prediction,
        "is_stress_test": stress,
        "trace": [
            {"thought": "I will work this through with the calculator.",
             "action": "calculator", "action_input": observation[0],
             "observation": observation[1]},
            {"final_answer": prediction},
        ],
    }


# The pool the campaign is scored on. Every problem string is distinctive, so a
# grading prompt can be attributed to the item it is about.
POOL = [
    _record("What is the value of 3x plus 7 when x equals 5?", "22", "22",
            ("3*5+7", "22"), "algebra", 2, False, "bh-101"),
    _record("Express the sum of one half and one quarter as a single fraction.",
            "3/4", "0.75", ("1/2+1/4", "0.75"), "algebra", 3, False, "bh-102"),
    _record("A circle has radius 5. What is its area in terms of pi?",
            "25\\pi", "25*pi", ("pi*5**2", "78.539816"), "geometry", 4, False,
            "bh-103"),
    _record("How many positive whole-number divisors does 196 have?", "9", None,
            ("196", "196"), "number_theory", 3, False, "bh-104"),
    _record("Write nineteen twelfths as an improper fraction.", "\\frac{19}{12}",
            "19/12", ("19/12", "1.583333"), "precalculus", 5, False, "bh-105"),
    _record("What is the measure in degrees of a right angle?", "90^\\circ",
            "90", ("360/4", "90"), "geometry", 2, False, "bh-106"),
    _record("Solve for y in the equation 2y minus 8 equals 0.", "4", "4.0",
            ("8/2", "4.0"), "algebra", 4, False, "bh-107"),
    _record("In how many ways can four distinct books be arranged on a shelf?",
            "24", "12", ("4*3", "12"), "counting", 3, False, "bh-108"),
    _record("What is the largest prime factor of 2024?", "23", "23",
            ("2024/88", "23"), "number_theory", 5, True, "bh-109"),
    _record("A square has an area of 49. What is its perimeter?", "28", "28",
            ("4*7", "28"), "geometry", 5, True, "bh-110"),
    _record("What is the remainder when 100 is divided by 7?", "2", "3",
            ("100/7", "14.2857"), "number_theory", 1, False, "bh-111"),
    _record("Evaluate the square root of one hundred and forty four.", "12",
            "sqrt(144)", ("144**0.5", "12.0"), "precalculus", 4, False,
            "bh-112"),
]

# The pool that ships with the project. The desk has to be able to attribute a
# prompt about one of these, or nobody could develop against it; it is never
# served as the graded pool.
SAMPLE_POOL = [
    _record('What is 4x minus 1 when x equals 3?', '11', '11', ('4*3-1', '11'), 'algebra', 2, False, 'sm-201'),
    _record('Write three eighths as a decimal.', '3/8', '0.375', ('3/8', '0.375'), 'algebra', 3, False, 'sm-202'),
    _record('A circle has radius 2. What is its area in terms of pi?', '4\\pi', '4*pi', ('pi*4', '12.566'), 'geometry', 3, False, 'sm-203'),
    _record('How many ways can three friends sit in a row?', '6', '6', ('3*2*1', '6'), 'counting', 2, False, 'sm-204'),
    _record('What is the greatest common divisor of 84 and 60?', '12', '6', ('84,60', '6'), 'number_theory', 4, False, 'sm-205'),
    _record('Evaluate the square root of eighty one.', '9', 'sqrt(81)', ('81**0.5', '9.0'), 'precalculus', 5, True, 'sm-206'),
    _record('A triangle has base 10 and height 6. What is its area?', '30', '60', ('10*6', '60'), 'geometry', 4, False, 'sm-207'),
    _record('What is the remainder when 45 is divided by 6?', '3', '5', ('45/6', '7.5'), 'number_theory', 2, False, 'sm-208')
]

KNOWN = POOL + SAMPLE_POOL
BY_ID = {item["id"]: item for item in KNOWN}

# What each family concludes. nyx is the more forgiving of the two and gives
# bh-104 the benefit of the doubt on a prediction that is not there at all.
VERDICTS = {
    "nyx": {
        "bh-101": (1, 5, 1), "bh-102": (1, 4, 1), "bh-103": (1, 5, 1),
        "bh-104": (1, 4, 1), "bh-105": (1, 4, 1), "bh-106": (1, 5, 1),
        "bh-107": (1, 5, 1), "bh-108": (0, 2, 1), "bh-109": (1, 5, 1),
        "bh-110": (1, 5, 1), "bh-111": (0, 2, 1), "bh-112": (1, 4, 1),
    },
    "vale": {
        "bh-101": (1, 5, 1), "bh-102": (1, 4, 1), "bh-103": (1, 4, 1),
        "bh-104": (0, 1, 0), "bh-105": (1, 4, 1), "bh-106": (1, 4, 1),
        "bh-107": (1, 5, 1), "bh-108": (0, 2, 1), "bh-109": (1, 5, 1),
        "bh-110": (1, 4, 1), "bh-111": (0, 1, 1), "bh-112": (1, 3, 1),
    },
}

SAMPLE_VERDICTS = {
    "nyx": {
        "sm-201": (1, 5, 1), "sm-202": (1, 4, 1), "sm-203": (1, 5, 1),
        "sm-204": (1, 5, 1), "sm-205": (1, 3, 1), "sm-206": (1, 4, 1),
        "sm-207": (0, 2, 1), "sm-208": (0, 2, 1),
    },
    "vale": {
        "sm-201": (1, 5, 1), "sm-202": (1, 4, 1), "sm-203": (1, 4, 1),
        "sm-204": (1, 5, 1), "sm-205": (0, 1, 0), "sm-206": (1, 4, 1),
        "sm-207": (0, 1, 1), "sm-208": (0, 2, 1),
    },
}
for _family, _table in SAMPLE_VERDICTS.items():
    VERDICTS[_family].update(_table)

EXPLANATIONS = {
    1: "The final answer is mathematically equivalent to the reference answer.",
    0: "The final answer does not match the reference answer.",
}

# One reply that carries no JSON at all, so a parser has to survive it.
NO_JSON = {("vale", "bh-108")}


def _judgment_text(family, item_id):
    correct, quality, tool_use = VERDICTS[family][item_id]
    payload = {
        "correct": correct,
        "reasoning_quality": quality,
        "used_tool_appropriately": tool_use,
        "explanation": EXPLANATIONS[correct],
    }
    if (family, item_id) in NO_JSON:
        return ("The work shown here is hard to follow and the arrangement "
                "count is wrong, so I would not award this one.")
    body = json.dumps(payload)
    if family == "nyx":
        return "```json\n%s\n```" % body
    return ("Here is my assessment of the submission.\n\n%s\n\nHappy to expand "
            "on any of the fields above." % body)


def _attribute(prompt):
    """Which pool item a grading prompt is about, by its problem text."""
    for item in KNOWN:
        if item["problem"] in prompt:
            return item
    return None


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "bellhaven-desk/1.0"

    def log_message(self, *args):
        return

    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        try:
            return json.loads(self.rfile.read(length).decode())
        except Exception:
            return {}

    def _authorised(self):
        return self.headers.get("X-Grader-Key") == GRADER_KEY

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if parsed.path == "/health":
            return self._send(200, {"ok": True, "service": "bellhaven-desk"})
        if parsed.path == "/v1/families":
            return self._send(200, {"families": sorted(VERDICTS)})
        if parsed.path.startswith(GRADER_PREFIX):
            if not self._authorised():
                return self._send(404, {"error": "not found"})
            leaf = parsed.path[len(GRADER_PREFIX):]
            if leaf == "/trace":
                with _LOCK:
                    return self._send(200, dict(_run(query.get("run", [""])[0])))
            if leaf == "/pool":
                return self._send(200, {"pool": POOL})
            if leaf == "/expected":
                return self._send(200, {
                    "verdicts": VERDICTS,
                    "no_json": ["%s:%s" % pair for pair in sorted(NO_JSON)],
                    "rubric_keys": list(RUBRIC_KEYS),
                })
            return self._send(404, {"error": "not found"})
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        if parsed.path.startswith(GRADER_PREFIX):
            if not self._authorised():
                return self._send(404, {"error": "not found"})
            if parsed.path[len(GRADER_PREFIX):] == "/reset":
                run_id = query.get("run", [""])[0] or "default"
                with _LOCK:
                    _RUNS[run_id] = _blank_run()
                return self._send(200, {"reset": run_id})
            return self._send(404, {"error": "not found"})

        if parsed.path != "/v1/judge":
            return self._send(404, {"error": "not found"})

        payload = self._body()
        family = (payload.get("family") or "").lower()
        prompt = payload.get("prompt") or ""
        run_id = payload.get("run_id") or os.environ.get("BELLHAVEN_RUN_ID") \
            or "default"
        if family not in VERDICTS:
            return self._send(400, {"error": "unknown family %r" % family})

        item = _attribute(prompt)
        low = prompt.lower()
        with _LOCK:
            record = _run(run_id)
            record["families"].append(family)
            if item is None:
                record["unmatched"] += 1
            else:
                trace = item["trace"][0]
                record["calls"].append({
                    "item": item["id"],
                    "family": family,
                    "has_gold": str(item["gold_answer"]) in prompt,
                    "has_prediction": str(item["predicted_answer"]) in prompt,
                    "has_trace": str(trace["observation"]) in prompt
                                 and str(trace["action"]) in prompt,
                    "asks_rubric": all(key in low for key in RUBRIC_KEYS),
                    "length": len(prompt),
                })

        if item is None:
            return self._send(200, {"content":
                "I cannot see which submission you want graded."})
        return self._send(200, {"content": _judgment_text(family, item["id"])})


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.daemon_threads = True
    server.serve_forever()


if __name__ == "__main__":
    main()
