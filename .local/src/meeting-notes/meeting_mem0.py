"""meeting_mem0 — single source of truth for pushing a meeting note to self-hosted mem0.

Shared by the CLI (`meeting-note-mem0`) and the Krisp webhook receiver
(`krisp-mem0-webhook.py`). Mirrors the payload shape of the HushNote bash hook
(hushnote-mem0-hook.sh): infer=false (store verbatim), agent_id=meetings,
per-meeting run_id, source/title/timestamp metadata.

mem0 (mem0.kblab.me) is LAN/Tailscale-only — anything calling this must run on
that network. Cloud relays (Zapier) reach it via the webhook receiver behind a
Tailscale Funnel, not by calling mem0 directly.
"""
from __future__ import annotations

import json
import os
import re
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

LOG_FILE = Path.home() / ".local/state/meeting-notes/mem0-ingest.log"


def _log(msg: str) -> None:
    LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
    ts = datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")
    with LOG_FILE.open("a") as fh:
        fh.write(f"{ts} {msg}\n")


def slug(text: str, maxlen: int = 48) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", (text or "").lower()).strip("-")
    return (s[:maxlen].rstrip("-")) or "untitled"


def build_payload(
    summary: str,
    *,
    title: str = "",
    timestamp: str = "",
    run_id: str = "",
    source: str = "krisp",
    user_id: str | None = None,
    agent_id: str | None = None,
) -> dict:
    title = title or "Untitled meeting"
    user_id = user_id or os.environ.get("MEM0_USER_ID", "kblack0610")
    agent_id = agent_id or os.environ.get("MEM0_AGENT_ID", "meetings")
    if not run_id:
        datepart = (timestamp or "")[:10] or "nodate"
        run_id = f"{source}-{datepart}-{slug(title)}"
    return {
        "messages": [{"role": "user", "content": f"Meeting: {title}\n\n{summary}"}],
        "user_id": user_id,
        "agent_id": agent_id,
        "run_id": run_id,
        "metadata": {
            "type": "meeting-summary",
            "source": source,
            "title": title,
            "timestamp": timestamp,
        },
        "infer": False,
    }


def push_memory(
    summary: str,
    *,
    title: str = "",
    timestamp: str = "",
    run_id: str = "",
    source: str = "krisp",
    base_url: str | None = None,
    api_key: str | None = None,
    timeout: int = 20,
) -> tuple[bool, int, str]:
    """POST a meeting summary to mem0. Returns (ok, http_status, body_or_error).

    Never raises on HTTP/network failure — callers (cron, webhook) decide retry.
    """
    if not (summary or "").strip():
        _log(f"SKIP empty summary (title='{title}', source={source})")
        return (False, 0, "empty summary")

    base_url = (base_url or os.environ.get("MEM0_BASE_URL", "https://mem0.kblab.me")).rstrip("/")
    api_key = api_key if api_key is not None else os.environ.get("MEM0_API_KEY", "")
    payload = build_payload(
        summary, title=title, timestamp=timestamp, run_id=run_id, source=source
    )
    data = json.dumps(payload).encode()
    req = urllib.request.Request(f"{base_url}/memories", data=data, method="POST")
    req.add_header("Content-Type", "application/json")
    if api_key:
        req.add_header("Authorization", f"Bearer {api_key}")

    rid = payload["run_id"]
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            code = resp.getcode()
            _log(f"OK {code} pushed '{title}' ({rid}) -> {base_url}")
            return (True, code, resp.read(200).decode("utf-8", "replace"))
    except urllib.error.HTTPError as e:
        body = e.read(500).decode("utf-8", "replace")
        _log(f"ERROR HTTP {e.code} '{title}' ({rid}): {body[:200]}")
        return (False, e.code, body)
    except Exception as e:  # noqa: BLE001 — network/DNS/timeout; report, don't crash
        _log(f"ERROR {type(e).__name__} '{title}' ({rid}): {e}")
        return (False, 0, str(e))
