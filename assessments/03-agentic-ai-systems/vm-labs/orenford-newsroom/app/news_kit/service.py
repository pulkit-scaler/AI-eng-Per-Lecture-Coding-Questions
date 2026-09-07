"""The HTTP plumbing for your newsroom service.

Provided, do not modify. `run_service(handler)` starts a service on
ORENFORD_SERVE_PORT (default 8300) and does not return.

    GET  /health   answered for you: {"status": "ok"}
    POST /brief    the JSON body is handed to your handler, and whatever dict
                   your handler returns is sent back as the response body

A handler that raises is reported as a 500 with the exception text, so a
mistake shows up in the response rather than killing the service.
"""
import json
import os
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("ORENFORD_SERVE_PORT", "8300"))


def _make_handler(handler):
    class ServiceHandler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            return

        def _send(self, code, payload):
            body = json.dumps(payload, default=str).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self):
            if self.path == "/health":
                self._send(200, {"status": "ok"})
            else:
                self._send(404, {"error": "not found"})

        def do_POST(self):
            if self.path != "/brief":
                self._send(404, {"error": "not found"})
                return
            length = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(length) if length else b"{}"
            try:
                payload = json.loads(raw.decode("utf-8") or "{}")
            except ValueError:
                self._send(400, {"error": "the body is not JSON"})
                return
            # Stamp the newsroom wire traffic for this request with the
            # assignment it belongs to, so a run can be traced end to end.
            os.environ["ORENFORD_RUN_ID"] = str(
                payload.get("assignment") or "local")
            try:
                answer = handler(payload)
            except Exception as exc:  # noqa: BLE001 - reported, not swallowed
                traceback.print_exc()
                self._send(500, {"error": "%s: %s" % (type(exc).__name__, exc)})
                return
            if not isinstance(answer, dict):
                self._send(500, {"error": "the handler returned %s, not a dict"
                                          % type(answer).__name__})
                return
            self._send(200, answer)

    return ServiceHandler


def run_service(handler, port=None):
    """Serve `handler` on POST /brief until the process is stopped."""
    bind = int(port or PORT)
    server = ThreadingHTTPServer(("127.0.0.1", bind), _make_handler(handler))
    server.daemon_threads = True
    print("orenford newsroom listening on http://127.0.0.1:%d" % bind,
          flush=True)
    server.serve_forever()
