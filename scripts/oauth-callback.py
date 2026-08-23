#!/usr/bin/env python3
"""One-shot OAuth loopback listener for the bottelet.slack Omarchy plugin.

Usage: oauth-callback.py <port> <state> <authorize-url>

Binds 127.0.0.1:<port> first, then opens <authorize-url> in the browser.
Waits up to 240 seconds for GET /callback?code=...&state=... where state
matches exactly; prints the code to stdout and exits 0. Anything else gets a
polite error page and the wait continues. Exit codes: 1 timeout/usage,
2 port already in use.

stdlib only — no third-party imports, binds loopback only, serves no files.
"""
import re
import signal
import subprocess
import sys
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TIMEOUT_SECS = 240

PAGE = """<!doctype html><meta charset="utf-8"><title>Omarchy Slack</title>
<style>:root{color-scheme:light dark}body{font-family:system-ui;background:Canvas;color:CanvasText;
display:grid;place-items:center;height:100vh;margin:0}
main{max-width:32rem;padding:2rem;border:1px solid GrayText;border-radius:.5rem}</style>
<main><h1>%s</h1><p>%s</p></main>"""


def main() -> int:
    if len(sys.argv) != 4:
        return 1
    try:
        port = int(sys.argv[1])
    except ValueError:
        return 1
    state = sys.argv[2]
    auth_url = sys.argv[3]
    if not (1024 <= port <= 65535):
        return 1
    if not re.fullmatch(r"[0-9a-f]{32}", state):
        return 1
    if not auth_url.startswith("https://slack.com/oauth/"):
        return 1

    # Hard ceiling: no path (idle sockets included) may outlive the deadline.
    signal.alarm(TIMEOUT_SECS + 10)

    result = {}

    class Handler(BaseHTTPRequestHandler):
        # Per-connection socket timeout: a client that connects and never
        # sends a request cannot pin the server (single idle TCP connection
        # would otherwise block handle_one_request forever).
        timeout = 10
        def do_GET(self):  # noqa: N802 (http.server API)
            parsed = urllib.parse.urlparse(self.path)
            if parsed.path != "/callback":
                self.reply(404, "Not found", "This server only handles the Slack sign-in callback.")
                return
            q = urllib.parse.parse_qs(parsed.query)
            got_state = q.get("state", [""])[0]
            code = q.get("code", [""])[0]
            err = q.get("error", [""])[0]
            if err:
                result["done"] = True
                self.reply(200, "Sign-in cancelled", "You can close this tab and return to Omarchy.")
                return
            if got_state != state or not code:
                # Wrong/missing state: refuse, keep waiting for the real one.
                self.reply(403, "Sign-in rejected", "State mismatch — please retry from Omarchy Slack.")
                return
            result["code"] = code
            result["done"] = True
            self.reply(200, "Signed in", "You can close this tab and return to Omarchy Slack.")

        def reply(self, status, title, detail):
            body = (PAGE % (title, detail)).encode()
            self.send_response(status)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.send_header("Cache-Control", "no-store")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *_args):
            pass

    try:
        server = ThreadingHTTPServer(("127.0.0.1", port), Handler)
        server.daemon_threads = True
    except OSError:
        return 2

    subprocess.Popen(
        ["xdg-open", auth_url],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )

    server.timeout = 5
    deadline = time.time() + TIMEOUT_SECS
    while time.time() < deadline and not result.get("done"):
        server.handle_request()
    server.server_close()

    if result.get("code"):
        print(result["code"])
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
