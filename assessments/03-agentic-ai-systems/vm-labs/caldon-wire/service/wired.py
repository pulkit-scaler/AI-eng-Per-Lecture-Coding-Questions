#!/usr/bin/env python3
"""Caldon wire desk model endpoint.

An OpenAI-compatible chat endpoint over the standard library. Replies are
computed from the wire feed rather than sampled, so every value a check
compares against is fixed.

The endpoint is also the instrument this lab measures with. Each request is
counted in and out under a lock, so the peak number of simultaneously open
requests for a run is observed rather than inferred, and a client that goes
away mid-request is noticed while the reply is still being held.

Environment:
    CALDON_PORT   port to bind on 127.0.0.1   (default 8794)
    CALDON_FEED   path to the wire feed JSON  (default alongside this file)
"""
import json
import os
import select
import socket
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(os.environ.get("CALDON_PORT", "8794"))
FEED_PATH = os.environ.get(
    "CALDON_FEED", os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                "wire_feed.json"))
MODEL_NAME = "caldon-wire-1"
GRADER_KEY = "caldon-grader-k4m8"
# The provided client identifies itself, so the desk can tell a call made
# through it from one made by a client the caller assembled themselves.
KIT_TOKEN = "wk-3f9a2c7d"
GRADER_PREFIX = "/__cwk4m8"

# Held long enough that overlapping work is visible in the arrival records and
# short enough that a five-way fan-out still finishes in about a second.
LATENCY = {"summary": 0.55, "urgency": 0.45, "note": 0.50, "bulletin": 0.50}
# One pull runs long enough that a caller working to a deadline has to give up
# on it. Applied per story so a caller cannot tell which it will get.
LONG_PULL = 4.0
LONG_PULL_STORIES = {"wf-3115", "wf-3126", "wf-3133", "wf-3159", "wf-3178"}
STREAM_GAP = 0.12
STREAM_WORDS = 4

STAFFED_DESKS = ["newsroom", "legal", "picture", "standards"]

_LOCK = threading.Lock()
_RUNS = {}


# ---------------------------------------------------------------------------
# wire feed
# ---------------------------------------------------------------------------

def load_feed(path=FEED_PATH):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)["stories"]


STORIES = load_feed()
BY_ID = {story["id"]: story for story in STORIES}


# ---- shared:replies -------------------------------------------------------
# These four functions decide every string the endpoint returns. The learner
# never runs them; the grader computes the same values through /oracle.
def summary_text(story):
    return ("%s desk: %s. %d people affected, filed %d minutes ago."
            % (story["region"], story["headline"], story["affected"],
               story["filed_minutes"]))


def urgency_score(story):
    recency = max(0, 60 - story["filed_minutes"]) // 2
    return min(99, story["affected"] // 400 + recency)


def note_text(story, desk):
    lines = {
        "newsroom": "lead with the %s angle, %d affected"
                    % (story["region"], story["affected"]),
        "legal": "clearance needed for the %s attribution" % story["source"],
        "picture": "no usable frame yet from %s" % story["source"],
        "standards": "second source required before the %s claim runs"
                     % story["region"],
    }
    return "%s note on %s: %s." % (desk, story["slug"], lines[desk])


def bulletin_text(story):
    return ("%s. %s The %s confirmed the figure and the %s desk is holding "
            "the line open." % (story["headline"], story["body"],
                                story["source"], story["region"]))
# ---- /shared:replies ------------------------------------------------------


def bulletin_chunks(story):
    """The bulletin split the way it goes out on the wire."""
    words = bulletin_text(story).split(" ")
    out = []
    for start in range(0, len(words), STREAM_WORDS):
        piece = " ".join(words[start:start + STREAM_WORDS])
        out.append(piece if start == 0 else " " + piece)
    return out


def ranking(story_ids):
    """Ids ordered by score, highest first, ties keeping their given order."""
    scored = [(index, sid) for index, sid in enumerate(story_ids)]
    scored.sort(key=lambda pair: (-urgency_score(BY_ID[pair[1]]), pair[0]))
    return [sid for _, sid in scored]


# ---------------------------------------------------------------------------
# request bookkeeping
# ---------------------------------------------------------------------------

def _blank_run():
    return {"open": 0, "peak": 0, "total": 0, "requests": []}


def _enter(run):
    with _LOCK:
        state = _RUNS.setdefault(run, _blank_run())
        state["open"] += 1
        state["total"] += 1
        if state["open"] > state["peak"]:
            state["peak"] = state["open"]
        return state["open"]


def _leave(run, entry):
    with _LOCK:
        state = _RUNS.setdefault(run, _blank_run())
        state["open"] -= 1
        if len(state["requests"]) < 400:
            state["requests"].append(entry)


def run_report(run):
    """What the grader reads back: how much of this run overlapped."""
    with _LOCK:
        state = json.loads(json.dumps(_RUNS.get(run, _blank_run())))
    entries = state["requests"]
    if entries:
        span = max(e["emit"] for e in entries) - min(e["recv"] for e in entries)
        busy = sum(e["emit"] - e["recv"] for e in entries)
    else:
        span = busy = 0.0
    state["span"] = round(span, 4)
    state["busy"] = round(busy, 4)
    state["kinds"] = {}
    for entry in entries:
        kind = entry.get("kind", "other")
        state["kinds"][kind] = state["kinds"].get(kind, 0) + 1
    state["stories"] = sorted({e.get("story") for e in entries if e.get("story")})
    state["aborted"] = sum(1 for e in entries if e.get("aborted"))
    state["via_kit"] = sum(1 for e in entries if e.get("via_kit"))
    # How long the desk held the request that was dropped soonest. A caller that
    # stops waiting at its deadline shows roughly the budget here; one that
    # leaves the call running shows however long its program happened to last.
    dropped = [e for e in entries if e.get("aborted")]
    state["abort_held_tenths"] = (
        int(round(min(e["emit"] - e["recv"] for e in dropped) * 10))
        if dropped else -1)
    state["streamed"] = sum(1 for e in entries if e.get("streamed"))
    state["rejected"] = sum(1 for e in entries if e.get("rejected"))
    # Reported in tenths so a check can compare integers in the shell.
    state["overlap_tenths"] = int(round((busy / span) * 10)) if span > 1e-6 else 0
    return state


# ---------------------------------------------------------------------------
# prompt dispatch
# ---------------------------------------------------------------------------

MARKERS = [
    ("summary", "wire summary desk"),
    ("urgency", "wire urgency scorer"),
    ("note", "wire desk note writer"),
    ("bulletin", "wire bulletin writer"),
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
    return "\n".join(parts)


def classify(text):
    lowered = (text or "").lower()
    for kind, marker in MARKERS:
        if marker in lowered:
            return kind
    return "other"


def find_story_id(text):
    for token in (text or "").replace("\n", " ").split():
        cleaned = token.strip(".,:;()[]{}\"'")
        if cleaned in BY_ID:
            return cleaned
    return None


def find_desk(text):
    lowered = (text or "").lower()
    marker = "desk:"
    if marker in lowered:
        tail = lowered.split(marker, 1)[1].strip()
        return tail.split()[0].strip(".,:;()[]{}\"'") if tail.split() else ""
    return ""


# ---------------------------------------------------------------------------
# HTTP layer
# ---------------------------------------------------------------------------

def estimate_tokens(text):
    return max(1, len(text or "") // 4)


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _run(self):
        return (self.headers.get("X-Caldon-Run")
                or self.headers.get("x-caldon-run") or "default")

    def _is_grader(self):
        return self.headers.get("X-Grader-Key") == GRADER_KEY

    def _send(self, code, payload):
        body = json.dumps(payload).encode("utf-8")
        try:
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError, OSError):
            return False
        return True

    def _hold(self, seconds):
        """Hold the reply, reporting False the moment the caller hangs up.

        A caller working to a deadline cancels the request rather than reading
        the reply, so the socket reaches end of file while this is waiting.
        Polling for that is what lets the endpoint tell a cancelled request
        apart from one that was simply never made.
        """
        deadline = time.monotonic() + seconds
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return True
            try:
                readable, _, _ = select.select([self.connection], [], [],
                                               min(0.05, remaining))
            except (OSError, ValueError):
                return False
            if readable:
                try:
                    if self.connection.recv(1, socket.MSG_PEEK) == b"":
                        return False
                except OSError:
                    return False
                # Readable but not at end of file: another request is queued on
                # the same connection. Stop polling and serve out the wait.
                time.sleep(max(0.0, deadline - time.monotonic()))
                return True

    # -- GET ---------------------------------------------------------------
    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)

        def one(key, default=""):
            return (query.get(key) or [default])[0]

        if parsed.path == "/health":
            return self._send(200, {"status": "ok", "service": "wired",
                                    "stories": len(STORIES)})

        if parsed.path == "/v1/models":
            return self._send(200, {"object": "list", "data": [
                {"id": MODEL_NAME, "object": "model", "owned_by": "caldon"}]})

        if not parsed.path.startswith(GRADER_PREFIX) or not self._is_grader():
            return self._send(404, {"error": {"message": "not found"}})

        tail = parsed.path[len(GRADER_PREFIX):]
        if tail == "/trace":
            return self._send(200, run_report(one("run", self._run())))
        if tail == "/oracle":
            return self._send(200, self._oracle(one))
        return self._send(404, {"error": {"message": "not found"}})

    def _oracle(self, one):
        kind = one("kind", "summary")
        ids = [sid for sid in one("ids").split(",") if sid in BY_ID]
        if kind == "summary":
            return {"texts": [summary_text(BY_ID[s]) for s in ids]}
        if kind == "urgency":
            return {"ranking": ranking(ids),
                    "scores": [urgency_score(BY_ID[s]) for s in ids]}
        if kind == "note":
            desk = one("desk")
            story = BY_ID.get(one("id"))
            if story is None or desk not in STAFFED_DESKS:
                return {"staffed": False, "desks": STAFFED_DESKS}
            return {"staffed": True, "text": note_text(story, desk)}
        if kind == "notes":
            # "id:desk,id:desk,..." resolved in one call, in the order given.
            entries = []
            for pair in one("pairs").split(","):
                story_id, _, desk = pair.partition(":")
                story = BY_ID.get(story_id)
                staffed = story is not None and desk in STAFFED_DESKS
                entries.append({
                    "story_id": story_id, "desk": desk, "staffed": staffed,
                    "text": note_text(story, desk) if staffed else ""})
            return {"entries": entries,
                    "staffed_count": sum(1 for e in entries if e["staffed"])}
        if kind == "bulletin":
            story = BY_ID.get(one("id"))
            if story is None:
                return {"error": "unknown story"}
            return {"text": bulletin_text(story),
                    "chunks": bulletin_chunks(story),
                    "long_pull": story["id"] in LONG_PULL_STORIES}
        if kind == "feed":
            return {"ids": [s["id"] for s in STORIES], "desks": STAFFED_DESKS}
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
        run = self._run()

        if parsed.path in ("/v1/chat/completions", "/chat/completions"):
            return self._chat(run, payload)

        if parsed.path == GRADER_PREFIX + "/reset":
            if not self._is_grader():
                return self._send(404, {"error": {"message": "not found"}})
            key = (query.get("run") or [run])[0]
            with _LOCK:
                _RUNS.pop(key, None)
            return self._send(200, {"reset": key})

        return self._send(404, {"error": {"message": "not found"}})

    def _chat(self, run, payload):
        messages = payload.get("messages")
        if not isinstance(messages, list) or not messages:
            return self._send(400, {"error": {
                "message": "'messages' is a required property",
                "type": "invalid_request_error"}})

        text = message_text(messages)
        kind = classify(text)
        story_id = find_story_id(text)
        desk = find_desk(text) if kind == "note" else ""
        entry = {"kind": kind, "story": story_id, "desk": desk,
                 "recv": time.time(), "streamed": False, "aborted": False,
                 "rejected": False,
                 "via_kit": self.headers.get("X-Caldon-Kit") == KIT_TOKEN}
        _enter(run)
        try:
            if story_id is None:
                entry["rejected"] = True
                return self._send(400, {"error": {
                    "message": "no story from the Caldon wire feed was named "
                               "in this request",
                    "type": "invalid_request_error"}})
            story = BY_ID[story_id]

            if kind == "note" and desk not in STAFFED_DESKS:
                # A desk the wire does not staff. The caller finds out the way
                # any other rejected request arrives: as an error from the API.
                entry["rejected"] = True
                return self._send(400, {"error": {
                    "message": "the %s desk is not staffed on the Caldon wire"
                               % (desk or "requested"),
                    "type": "invalid_request_error"}})

            if payload.get("stream"):
                return self._stream(story, kind, entry)

            wait = LATENCY.get(kind, 0.4)
            if kind == "bulletin" and story_id in LONG_PULL_STORIES:
                wait = LONG_PULL
            if not self._hold(wait):
                entry["aborted"] = True
                return False

            content = self._body_for(kind, story, desk)
            return self._send(200, self._envelope(payload, content, text))
        finally:
            entry.setdefault("emit", time.time())
            entry["emit"] = time.time()
            _leave(run, entry)

    def _body_for(self, kind, story, desk):
        if kind == "summary":
            return summary_text(story)
        if kind == "urgency":
            return str(urgency_score(story))
        if kind == "note":
            return note_text(story, desk)
        if kind == "bulletin":
            return bulletin_text(story)
        return "no desk on the Caldon wire handles that request"

    def _stream(self, story, kind, entry):
        entry["streamed"] = True
        chunks = (bulletin_chunks(story) if kind == "bulletin"
                  else [self._body_for(kind, story, entry.get("desk", ""))])
        completion_id = "chatcmpl-%s" % uuid.uuid4().hex[:24]
        created = int(time.time())

        def frame(delta, finish=None):
            return ("data: " + json.dumps({
                "id": completion_id, "object": "chat.completion.chunk",
                "created": created, "model": MODEL_NAME,
                "choices": [{"index": 0, "delta": delta,
                             "finish_reason": finish}]}) + "\n\n").encode()

        # Chunked rather than a close-delimited body: an event stream has no
        # length to declare up front, and closing the connection to mark the
        # end leaves the client tearing down a pooled connection it was still
        # reading, which surfaces as noise on the caller side.
        def emit(payload):
            self.wfile.write(b"%X\r\n%s\r\n" % (len(payload), payload))
            self.wfile.flush()

        try:
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Cache-Control", "no-cache")
            self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            emit(frame({"role": "assistant", "content": ""}))
            for piece in chunks:
                if not self._hold(STREAM_GAP):
                    entry["aborted"] = True
                    return False
                emit(frame({"content": piece}))
            emit(frame({}, "stop"))
            emit(b"data: [DONE]\n\n")
            self.wfile.write(b"0\r\n\r\n")
            self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            entry["aborted"] = True
        return True

    def _envelope(self, payload, content, prompt_text):
        prompt_tokens = estimate_tokens(prompt_text)
        completion_tokens = estimate_tokens(content)
        return {
            "id": "chatcmpl-%s" % uuid.uuid4().hex[:24],
            "object": "chat.completion",
            "created": int(time.time()),
            "model": payload.get("model") or MODEL_NAME,
            "choices": [{"index": 0, "logprobs": None, "finish_reason": "stop",
                         "message": {"role": "assistant", "content": content}}],
            "usage": {"prompt_tokens": prompt_tokens,
                      "completion_tokens": completion_tokens,
                      "total_tokens": prompt_tokens + completion_tokens},
        }


def main():
    ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
