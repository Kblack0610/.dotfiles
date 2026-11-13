#!/usr/bin/env python3
"""A stub of the gateway's /v1/chat/completions for the ask-local suite.

Usage: openai-stub.py <state-dir>. Binds 127.0.0.1 on a free port, prints it as one line
on stdout once it listens, and saves each request (headers, body) to <state-dir>/last.json.
The bearer key picks the behaviour, so one server serves every test:
  good   200, echoes the last user message as "echo: <text>"
  json   200, content is the JSON object {"ok": true}
  prose  200, content is "not json"
  empty  200, empty content (a model that spent its budget thinking)
  down   500 with a LiteLLM-shaped error (the route's backend is unreachable)
  hang   never answers (the client's timeout must end the call)
  other  401
"""
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

STATE = Path(sys.argv[1])
NEVER = threading.Event()


def reply(content, finish="stop"):
    return {"choices": [{"index": 0, "finish_reason": finish,
                         "message": {"role": "assistant", "content": content}}]}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        (STATE / "last.json").write_text(json.dumps(
            {"path": self.path, "headers": dict(self.headers), "body": body}))
        key = self.headers.get("Authorization", "").removeprefix("Bearer ")
        if key == "hang":
            NEVER.wait()
        if key == "good":
            users = [m["content"] for m in body["messages"] if m["role"] == "user"]
            return self.send(200, reply("echo: " + users[-1]))
        if key == "json":
            return self.send(200, reply('{"ok": true}'))
        if key == "prose":
            return self.send(200, reply("not json"))
        if key == "empty":
            return self.send(200, reply("", "length"))
        if key == "down":
            return self.send(500, {"error": {"message": "litellm.APIConnectionError: Connection refused"}})
        return self.send(401, {"error": {"message": "Authentication Error, Invalid proxy server token passed."}})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
server.daemon_threads = True
print(server.server_address[1], flush=True)
server.serve_forever()
