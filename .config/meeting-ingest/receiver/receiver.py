#!/usr/bin/env python3
"""Krisp webhook receiver (Phase 3 of meeting-ingest automation).

Receives Krisp's "notes generated" webhook POST, verifies a shared secret, and
republishes a minimal event onto the MQTT bus. A Mac subscriber
(meeting-ingest-mqtt-sub.sh) then runs the actual ingest -- the vault + Krisp
MCP + notes CLI live on the laptop, not here, so this service only forwards.

Deliberately tiny (stdlib http.server + paho-mqtt), stateless, fast-ack:
Krisp retries with backoff on non-2xx, so we ack immediately after publish.

Env:
  WEBHOOK_SECRET   required; must match the header Krisp sends (see AUTH_HEADER)
  AUTH_HEADER      header name carrying the secret (default: X-Webhook-Secret)
  MQTT_HOST        broker host (reuse the notes-sync broker)
  MQTT_PORT        default 1883
  MQTT_TOPIC       default: meeting-ingest/krisp
  MQTT_USER/PASS   optional broker auth
  PORT             listen port (default 8080)
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import paho.mqtt.publish as publish  # pip install paho-mqtt

SECRET = os.environ.get("WEBHOOK_SECRET", "")
AUTH_HEADER = os.environ.get("AUTH_HEADER", "X-Webhook-Secret")
MQTT_HOST = os.environ.get("MQTT_HOST", "localhost")
MQTT_PORT = int(os.environ.get("MQTT_PORT", "1883"))
MQTT_TOPIC = os.environ.get("MQTT_TOPIC", "meeting-ingest/krisp")
MQTT_USER = os.environ.get("MQTT_USER")
MQTT_PASS = os.environ.get("MQTT_PASS")
PORT = int(os.environ.get("PORT", "8080"))


def _auth():
    return {"username": MQTT_USER, "password": MQTT_PASS} if MQTT_USER else None


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, msg=""):
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(msg.encode())

    def do_GET(self):  # health probe for k8s
        self._send(200, "ok") if self.path == "/healthz" else self._send(404)

    def do_POST(self):
        if not SECRET or self.headers.get(AUTH_HEADER) != SECRET:
            return self._send(401, "unauthorized")
        n = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(n) if n else b"{}"
        try:
            payload = json.loads(raw or b"{}")
        except json.JSONDecodeError:
            return self._send(400, "bad json")

        # Forward only what the ingest needs to find the meeting; the full,
        # final doc is re-pulled laptop-side via the Krisp MCP (avoids trusting
        # an early payload that may predate speaker diarization).
        event = {
            "event": payload.get("event") or payload.get("type"),
            "meeting_id": payload.get("meeting_id") or payload.get("id"),
            "title": payload.get("title") or payload.get("name"),
            "url": payload.get("url") or payload.get("link"),
        }
        try:
            publish.single(
                MQTT_TOPIC, json.dumps(event), hostname=MQTT_HOST,
                port=MQTT_PORT, auth=_auth(), qos=1,
            )
        except Exception as e:  # noqa: BLE001 -- ack failure so Krisp retries
            print(f"mqtt publish failed: {e}", file=sys.stderr, flush=True)
            return self._send(502, "mqtt down")
        self._send(200, "queued")

    def log_message(self, *_):  # quieter logs
        pass


if __name__ == "__main__":
    if not SECRET:
        print("WEBHOOK_SECRET is required", file=sys.stderr)
        sys.exit(1)
    print(f"krisp-receiver listening on :{PORT} -> mqtt {MQTT_HOST}:{MQTT_PORT}/{MQTT_TOPIC}", flush=True)
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
