#!/usr/bin/env python3
"""marketsite - the Lambwell Market site, and the log of what was asked of it.

INSTRUCTOR-ONLY FILE. Installed to /opt/lambwell-svc as root:root 0700 and never
placed under the learner project.

    GET  /                     the market front page
    GET  /stalls               a stall table that renders after a delay
    GET  /feed                 a feed that grows as it is scrolled
    GET  /feed/page?after=     the feed rows, fetched by the page itself
    GET  /login                the login form
    POST /login                sets the session cookie
    GET  /orders               requires the session cookie
    GET  /private/ledger       disallowed by robots.txt
    GET  /robots.txt
    GET  /__lw4t/log           grader only: every request, with timestamps
    GET  /__lw4t/tokens        grader only: every token the site has issued
    GET  /__lw4t/expect        grader only: what a correct harvest looks like
    POST /__lw4t/reset         grader only

Every page that carries data also carries a fresh token, and the site records
which tokens it has issued. An artefact quoting a token the site never issued did
not come from this site.
"""
import json
import os
import re
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PORT = int(os.environ.get("LAMBWELL_PORT", "8711"))
GRADER_KEY = "lambwell-grader-lw4t"
GRADER_PATH = "/__lw4t"
SESSION_COOKIE = "lambwell_session"
SESSION_VALUE = "lw-session-8f31"
LOGIN_USER = "harvester"
LOGIN_PASSWORD = "market-day"

# How long the stall table takes to finish rendering. The last row lands after
# this, so a harvest that does not wait for the table to settle misses it.
STALL_RENDER_MS = 1500
FEED_PAGE = 8
FEED_TOTAL = 47

_LOCK = threading.Lock()
_LOG = []
_TOKENS = []
_STARTED = time.time()

STALLS = [
    {"stall": "A1", "trader": "Halloway Fruit", "goods": "apples, pears", "since": 1968},
    {"stall": "A2", "trader": "Brightwell Dairy", "goods": "cheese, butter", "since": 1974},
    {"stall": "A3", "trader": "Kemp and Sons", "goods": "beef, mutton", "since": 1951},
    {"stall": "B1", "trader": "Marchant Fish", "goods": "cod, mussels", "since": 1989},
    {"stall": "B2", "trader": "Orrell Bakery", "goods": "bread, pies", "since": 1932},
    {"stall": "B3", "trader": "Pike Hardware", "goods": "tools, rope", "since": 1957},
    {"stall": "C1", "trader": "Selby Flowers", "goods": "cut flowers", "since": 2001},
    {"stall": "C2", "trader": "Tranter Textiles", "goods": "wool, linen", "since": 1946},
    {"stall": "C3", "trader": "Wend Coffee", "goods": "beans, cups", "since": 2014},
]

ORDERS = [
    {"order": "LW-6001", "stall": "A1", "crates": 14},
    {"order": "LW-6002", "stall": "B2", "crates": 9},
    {"order": "LW-6003", "stall": "C2", "crates": 22},
    {"order": "LW-6004", "stall": "A3", "crates": 5},
]


def issue_token(kind):
    with _LOCK:
        token = "%s-%04d" % (kind, len(_TOKENS) + 1)
        _TOKENS.append({"token": token, "kind": kind, "at": time.time()})
        return token


def log_request(path, status, session):
    with _LOCK:
        _LOG.append({"path": path, "status": status, "at": time.time(),
                     "session": bool(session)})


def feed_rows(after):
    rows = []
    index = after + 1
    while index <= FEED_TOTAL and len(rows) < FEED_PAGE:
        rows.append({"id": index,
                     "lot": "LOT-%03d" % index,
                     "stall": STALLS[(index - 1) % len(STALLS)]["stall"],
                     "weight_kg": 4 + (index * 7) % 46})
        index += 1
    return rows


FRONT = """<!doctype html><html><head><title>Lambwell Market</title></head>
<body><h1>Lambwell Market</h1>
<ul>
  <li><a href="/stalls">Stall register</a></li>
  <li><a href="/feed">Lot feed</a></li>
  <li><a href="/login">Traders login</a></li>
</ul></body></html>"""

STALLS_PAGE = """<!doctype html><html><head><title>Stall register</title></head>
<body data-token="%(token)s">
<h1>Stall register</h1>
<p id="status">loading</p>
<table id="stalls"><thead><tr>
  <th>Stall</th><th>Trader</th><th>Goods</th><th>Trading since</th>
</tr></thead><tbody id="rows"></tbody></table>
<script>
const ROWS = %(rows)s;
const body = document.getElementById("rows");
let shown = 0;
function step() {
  if (shown < ROWS.length) {
    const r = ROWS[shown++];
    const tr = document.createElement("tr");
    tr.setAttribute("data-stall", r.stall);
    tr.innerHTML = "<td>" + r.stall + "</td><td>" + r.trader +
                   "</td><td>" + r.goods + "</td><td>" + r.since + "</td>";
    body.appendChild(tr);
    setTimeout(step, %(tick)d);
  } else {
    document.getElementById("status").textContent = "complete";
    document.getElementById("stalls").setAttribute("data-complete", "yes");
  }
}
setTimeout(step, %(tick)d);
</script></body></html>"""

FEED_PAGE_HTML = """<!doctype html><html><head><title>Lot feed</title></head>
<body data-token="%(token)s">
<h1>Lot feed</h1>
<div id="feed"></div>
<p id="feedstatus">more</p>
<div style="height:200vh"></div>
<script>
let last = 0;
let loading = false;
async function more() {
  if (loading) return;
  loading = true;
  const res = await fetch("/feed/page?after=" + last);
  const data = await res.json();
  for (const row of data.rows) {
    const d = document.createElement("div");
    d.className = "lot";
    d.setAttribute("data-id", row.id);
    d.textContent = row.lot + " | " + row.stall + " | " + row.weight_kg + "kg";
    document.getElementById("feed").appendChild(d);
    last = row.id;
  }
  if (data.rows.length === 0) {
    document.getElementById("feedstatus").textContent = "end of feed";
    document.body.setAttribute("data-feed", "exhausted");
  }
  loading = false;
}
window.addEventListener("scroll", () => {
  if (window.innerHeight + window.scrollY >= document.body.offsetHeight - 200) {
    more();
  }
});
more();
</script></body></html>"""

LOGIN_PAGE = """<!doctype html><html><head><title>Traders login</title></head>
<body><h1>Traders login</h1>%(error)s
<form method="post" action="/login">
  <label for="username">Username</label>
  <input id="username" name="username" type="text">
  <label for="password">Password</label>
  <input id="password" name="password" type="password">
  <button type="submit">Sign in</button>
</form></body></html>"""

ORDERS_PAGE = """<!doctype html><html><head><title>Standing orders</title></head>
<body data-token="%(token)s">
<h1>Standing orders</h1>
<table id="orders"><thead><tr><th>Order</th><th>Stall</th><th>Crates</th></tr>
</thead><tbody>%(rows)s</tbody></table>
<p id="orderstatus">signed in</p></body></html>"""

ROBOTS = """User-agent: *
Disallow: /private/
Crawl-delay: 1
"""


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        return

    def _session(self):
        cookie = self.headers.get("Cookie", "") or ""
        return ("%s=%s" % (SESSION_COOKIE, SESSION_VALUE)) in cookie

    def _send(self, code, body, ctype="text/html; charset=utf-8", extra=None):
        raw = body.encode("utf-8") if isinstance(body, str) else body
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(raw)))
        self.send_header("Cache-Control", "no-store")
        for key, value in (extra or []):
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(raw)

    def _json(self, code, payload, extra=None):
        self._send(code, json.dumps(payload), "application/json", extra)

    def _authorised(self):
        return self.headers.get("X-Grader-Key", "") == GRADER_KEY

    def do_GET(self):
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)
        path = parsed.path
        # The full target, query and all: a harvest that tags its own requests
        # can then be told apart from everything else the site has served.
        target = self.path

        if path.startswith(GRADER_PATH):
            if not self._authorised():
                self._json(403, {"error": "forbidden"})
                return
            leaf = path[len(GRADER_PATH):]
            if leaf == "/log":
                with _LOCK:
                    self._json(200, {"requests": list(_LOG),
                                     "started": _STARTED})
                return
            if leaf == "/tokens":
                with _LOCK:
                    self._json(200, {"tokens": [t["token"] for t in _TOKENS]})
                return
            if leaf == "/expect":
                self._json(200, {
                    "stalls": STALLS,
                    "stall_count": len(STALLS),
                    "feed_total": FEED_TOTAL,
                    "feed_page": FEED_PAGE,
                    "orders": ORDERS,
                    "order_ids": [o["order"] for o in ORDERS],
                    "disallowed": ["/private/"],
                    "crawl_delay": 1,
                    "render_ms": STALL_RENDER_MS,
                })
                return
            self._json(404, {"error": "not found"})
            return

        if path == "/health":
            self._json(200, {"status": "ok", "stalls": len(STALLS)})
            return

        if path == "/":
            log_request(target, 200, self._session())
            self._send(200, FRONT)
            return

        if path == "/robots.txt":
            log_request(target, 200, self._session())
            self._send(200, ROBOTS, "text/plain; charset=utf-8")
            return

        if path == "/stalls":
            token = issue_token("stalls")
            log_request(target, 200, self._session())
            tick = max(1, STALL_RENDER_MS // (len(STALLS) + 1))
            self._send(200, STALLS_PAGE % {"token": token,
                                           "rows": json.dumps(STALLS),
                                           "tick": tick})
            return

        if path == "/feed":
            token = issue_token("feed")
            log_request(target, 200, self._session())
            self._send(200, FEED_PAGE_HTML % {"token": token})
            return

        if path == "/feed/page":
            after = int((query.get("after") or ["0"])[0] or 0)
            log_request(target, 200, self._session())
            self._json(200, {"rows": feed_rows(after), "after": after})
            return

        if path == "/login":
            log_request(target, 200, self._session())
            self._send(200, LOGIN_PAGE % {"error": ""})
            return

        if path == "/orders":
            if not self._session():
                log_request(target, 401, False)
                self._send(401, "<!doctype html><html><body><h1>Sign in "
                                "first</h1></body></html>")
                return
            token = issue_token("orders")
            log_request(target, 200, True)
            rows = "".join(
                "<tr data-order=\"%s\"><td>%s</td><td>%s</td><td>%d</td></tr>"
                % (o["order"], o["order"], o["stall"], o["crates"])
                for o in ORDERS)
            self._send(200, ORDERS_PAGE % {"token": token, "rows": rows})
            return

        if path.startswith("/private/"):
            log_request(target, 200, self._session())
            self._send(200, "<!doctype html><html><body><h1>Private "
                            "ledger</h1><p>Not for harvesting.</p></body></html>")
            return

        log_request(target, 404, self._session())
        self._send(404, "<!doctype html><html><body>not found</body></html>")

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        query = parse_qs(parsed.query)

        if path == GRADER_PATH + "/reset":
            if not self._authorised():
                self._json(403, {"error": "forbidden"})
                return
            with _LOCK:
                del _LOG[:]
                del _TOKENS[:]
            self._json(200, {"status": "reset"})
            return

        if path == "/login":
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length).decode("utf-8") if length else ""
            form = parse_qs(raw)
            user = (form.get("username") or [""])[0]
            password = (form.get("password") or [""])[0]
            if user == LOGIN_USER and password == LOGIN_PASSWORD:
                log_request("/login", 302, False)
                self._send(302, "", "text/html", [
                    ("Set-Cookie", "%s=%s; Path=/" % (SESSION_COOKIE,
                                                      SESSION_VALUE)),
                    ("Location", "/orders"),
                ])
                return
            log_request("/login", 401, False)
            self._send(401, LOGIN_PAGE % {
                "error": "<p id=\"loginerror\">Those details are wrong.</p>"})
            return

        self._json(404, {"error": "not found"})


def main():
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.daemon_threads = True
    print("lambwell market site listening on %d with %d stalls and %d lots"
          % (PORT, len(STALLS), FEED_TOTAL), flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
