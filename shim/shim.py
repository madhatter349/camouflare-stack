"""FlareSolverr-compat shim for clients that cannot authenticate or that send a
null proxy object.

Prowlarr's FlareSolverr proxy always sends {"proxy": {"url": null, ...}} when no
proxy is configured. FlareSolverr ignores that; Camouflare rejects it with
500 INVALID_REQUEST. This process strips a proxy object that names no endpoint,
injects the bearer token, and forwards upstream. It is never publicly routed.

Stdlib only: no build step, no dependencies.
"""
import json
import os
import sys
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

UPSTREAM = os.environ.get("UPSTREAM", "http://camouflare:8191").rstrip("/")
TOKEN = os.environ.get("CAMOUFLARE_API_TOKEN", "")
PORT = int(os.environ.get("PORT", "8192"))
TIMEOUT = float(os.environ.get("UPSTREAM_TIMEOUT", "300"))
MAX_BODY = 64 * 1024 * 1024


def _has_endpoint(proxy):
    """True when the proxy object names something actually usable."""
    if not isinstance(proxy, dict):
        return False
    for key in ("url", "server"):
        value = proxy.get(key)
        if isinstance(value, str) and value.strip():
            return True
    return False


def sanitize(raw):
    """Drop a proxy object that names no endpoint. Returns (body, stripped)."""
    try:
        payload = json.loads(raw)
    except Exception:
        return raw, False
    if not isinstance(payload, dict) or "proxy" not in payload:
        return raw, False
    if _has_endpoint(payload["proxy"]):
        return raw, False
    payload.pop("proxy", None)
    return json.dumps(payload).encode(), True


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s %s\n" % (self.log_date_time_string(), fmt % args))

    def _forward(self):
        try:
            length = int(self.headers.get("Content-Length") or 0)
        except ValueError:
            length = 0
        if length > MAX_BODY:
            self.send_error(413, "payload too large")
            return
        body = self.rfile.read(length) if length else b""
        stripped = False
        if body:
            body, stripped = sanitize(body)
        headers = {
            "Authorization": "Bearer " + TOKEN,
            "Content-Type": self.headers.get("Content-Type", "application/json"),
            "Accept": self.headers.get("Accept", "application/json"),
        }
        req = urllib.request.Request(
            UPSTREAM + self.path, data=body or None, headers=headers, method=self.command
        )
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as resp:
                data, status = resp.read(), resp.status
                ctype = resp.headers.get("Content-Type", "application/json")
        except urllib.error.HTTPError as exc:
            data, status = exc.read(), exc.code
            ctype = exc.headers.get("Content-Type", "application/json")
        except Exception as exc:  # upstream down, timeout, DNS
            data = json.dumps({"status": "error", "message": "shim upstream error: %s" % exc}).encode()
            status, ctype = 502, "application/json"
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        try:
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass
        self.log_message(
            "%s %s -> %s%s", self.command, self.path, status,
            " (proxy stripped)" if stripped else "",
        )

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = _forward


if __name__ == "__main__":
    if not TOKEN:
        sys.exit("CAMOUFLARE_API_TOKEN is required")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
