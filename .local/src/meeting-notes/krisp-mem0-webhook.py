#!/usr/bin/env python3
"""krisp-mem0-webhook — receive Krisp meeting notes from Zapier and push to mem0.

Why this exists: mem0 (mem0.kblab.me) is LAN/Tailscale-only, and Krisp has no API/MCP.
So the path is: Krisp -> Zapier (trigger: new meeting note) -> "Webhooks by Zapier"
POST -> THIS receiver (running on the LAN box, optionally exposed via Tailscale Funnel)
-> mem0. mem0 itself stays private; this is the one locked-down ingress.

Run:
  MEM0_WEBHOOK_SECRET=<long-random> ./krisp-mem0-webhook.py            # binds 127.0.0.1:8788
  MEM0_WEBHOOK_SECRET=... HOST=0.0.0.0 PORT=8788 ./krisp-mem0-webhook.py
Expose to Zapier (keeps mem0 private):
  tailscale funnel 8788                # public HTTPS -> this port, Tailscale-terminated
Then in Zapier point the webhook at  https://<host>.<tailnet>.ts.net/krisp
with header  X-Webhook-Secret: <the same secret>.

Expected JSON body (map Krisp/Zapier fields to these):
  {"title": "...", "date": "2026-06-18T14:00:00Z", "summary": "...", "source": "krisp"}
`summary` (or `notes`/`transcript`) is required; the rest are best-effort.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from meeting_mem0 import push_memory  # noqa: E402

SECRET = os.environ.get("MEM0_WEBHOOK_SECRET", "")
MAX_BODY = 2 * 1024 * 1024  # 2 MiB cap


class Handler(BaseHTTPRequestHandler):
    def _send(self, code: int, obj: dict) -> None:
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # health check
        if self.path.rstrip("/") in ("", "/health"):
            self._send(200, {"ok": True})
        else:
            self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path.rstrip("/") != "/krisp":
            return self._send(404, {"error": "not found"})
        # Constant-ish secret check (reject before reading body if missing/wrong).
        if not SECRET or self.headers.get("X-Webhook-Secret", "") != SECRET:
            return self._send(401, {"error": "unauthorized"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            return self._send(400, {"error": "bad length"})
        if length <= 0 or length > MAX_BODY:
            return self._send(413, {"error": "missing or oversized body"})
        try:
            payload = json.loads(self.rfile.read(length))
        except (ValueError, OSError):
            return self._send(400, {"error": "invalid JSON"})

        summary = payload.get("summary") or payload.get("notes") or payload.get("transcript") or ""
        if not summary.strip():
            return self._send(400, {"error": "no summary/notes/transcript field"})

        ok, code, body = push_memory(
            summary,
            title=payload.get("title", ""),
            timestamp=payload.get("date") or payload.get("timestamp", ""),
            source=payload.get("source", "krisp"),
        )
        # 200 so Zapier marks success; 502 lets Zapier retry on mem0 outage.
        return self._send(200 if ok else 502, {"ok": ok, "mem0_status": code})

    def log_message(self, *_):  # quiet; meeting_mem0 already logs to its file
        return


def main() -> int:
    if not SECRET:
        print("refusing to start: set MEM0_WEBHOOK_SECRET", file=sys.stderr)
        return 2
    host = os.environ.get("HOST", "127.0.0.1")
    port = int(os.environ.get("PORT", "8788"))
    srv = ThreadingHTTPServer((host, port), Handler)
    print(f"krisp-mem0-webhook listening on {host}:{port} (POST /krisp)")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
