#!/usr/bin/env python3
"""agent-usage langfuse --since ISO --until ISO: what only Langfuse can say about a window, as JSON.

  tools        calls and latency per tool, slowest in total first, without the tools whose
               latency is a human's wait.
  tool_errors  failed executions and their error classes.
  gateway      LiteLLM calls, errors, cost and tokens per upstream model, and errors by class.

Session cost stays `agent-usage burn`; the gateway figure here is the gateway's alone. Gateway
figures come from litellm_request only: claude_code.llm_request is the same call seen from Claude
Code, so summing both counts it twice.

URL: SO_LF_URL, else the session-outcomes conf that sets it. Key: rbw entry SO_LF_ENTRY. Exit 1
with the reason on stderr and nothing on stdout when Langfuse cannot answer.
"""
import argparse
import collections
import datetime as dt
import json
import os
import re
import shlex
import subprocess
import sys
from pathlib import Path

ENV = os.environ
CURL = shlex.split(ENV.get("LF_CURL", "curl"))
RBW = shlex.split(ENV.get("LF_RBW", "rbw"))
ENTRY = ENV.get("SO_LF_ENTRY", "langfuse-api")
CONF_DIR = Path(ENV.get("AGENTCTL_CONF_DIR", Path.home() / ".config" / "agentctl" / "agents"))
EXEC_SPAN = "claude_code.tool.execution"
GATEWAY_SPAN = "litellm_request"
# Claude Code names a tool's span after the tool, and Langfuse cannot filter on the span.type
# attribute that would say so directly. So: its environments (apps/alloy sets them from
# service.name), then the name shape, which drops claude_code.* and the like.
CLAUDE_ENVIRONMENTS = ["claude-code", "claude-agentctl"]
TOOL_SPAN = re.compile(r"^(?:[A-Z][A-Za-z0-9]+|mcp__.+)$")
HUMAN_WAIT = {"AskUserQuestion", "ExitPlanMode"}
TOP_TOOLS = 20
ROW_LIMIT = 1000      # the metrics API's maximum, also the observations page size
MAX_PAGES = 20        # 20,000 errors in a window: past this `truncated` says the classes are partial
TIMEOUT_S = 60


class Unreadable(Exception):
    pass


def run(cmd, **kw):
    try:
        return subprocess.run(cmd, capture_output=True, text=True, timeout=TIMEOUT_S + 5, **kw)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise Unreadable(f"{cmd[0]}: {type(e).__name__}") from None


def base_url():
    url = ENV.get("SO_LF_URL")
    if not url:
        conf = CONF_DIR / "session-outcomes.conf"
        url = run(["bash", "-c", '. "$1" 2>/dev/null; printf %s "${SO_LF_URL:-}"', "_", str(conf)]).stdout
    if not url:
        raise Unreadable("no URL (SO_LF_URL, or the session-outcomes conf)")
    return url.rstrip("/")


def read_key():
    p = run(RBW + ["get", ENTRY])
    key = p.stdout.strip()
    if p.returncode or not key:
        raise Unreadable(f"no key (rbw {ENTRY})")
    return key


class Client:
    def __init__(self, since, until):
        self.url, self.key, self.since, self.until = base_url(), read_key(), since, until

    def get(self, path, params):
        args = [a for k, v in params.items() for a in ("--data-urlencode", f"{k}={v}")]
        # The key goes in on stdin (-K -), never argv, where any `ps` would show it.
        p = run(CURL + ["-sS", "--fail-with-body", "-K", "-", "--max-time", str(TIMEOUT_S), "-G",
                        f"{self.url}{path}"] + args, input=f'user = "{self.key}"\n')
        if p.returncode:
            raise Unreadable(f"{path}: curl exit {p.returncode}, {p.stderr.strip()[-200:]}")
        try:
            return json.loads(p.stdout)
        except ValueError:
            raise Unreadable(f"{path}: not JSON: {p.stdout[:100]}") from None

    def metrics(self, measures, dims, column, values):
        filters = [{"column": column, "operator": "any of", "value": values, "type": "stringOptions"}]
        query = {"view": "observations", "timeDimension": None, "filters": filters,
                 "metrics": [{"measure": m, "aggregation": a} for m, a in measures],
                 "dimensions": [{"field": d} for d in dims],
                 "fromTimestamp": self.since, "toTimestamp": self.until, "config": {"row_limit": ROW_LIMIT}}
        return self.get("/api/public/v2/metrics", {"query": json.dumps(query)}).get("data") or []

    def errors_by(self, name, key):
        """(count per metadata[key], truncated) over a span's ERROR observations."""
        counts, cursor = collections.Counter(), None
        for _ in range(MAX_PAGES):
            params = {"name": name, "level": "ERROR", "fields": "core,metadata", "limit": ROW_LIMIT,
                      "fromStartTime": self.since, "toStartTime": self.until}
            if cursor:
                params["cursor"] = cursor
            page = self.get("/api/public/v2/observations", params)
            counts.update((o.get("metadata") or {}).get(key) or "unknown" for o in page.get("data") or [])
            cursor = (page.get("meta") or {}).get("cursor")
            if not cursor:
                return dict(counts.most_common()), False
        return dict(counts.most_common()), True


def number(row, field):
    return float(row.get(field) or 0)


def tools(c):
    rows = c.metrics((("count", "count"), ("latency", "p50"), ("latency", "p95"), ("latency", "sum")), ["name"],
                     "environment", CLAUDE_ENVIRONMENTS)
    if len(rows) >= ROW_LIMIT:
        raise Unreadable(f"{ROW_LIMIT} span names or more: the tool ranking would be partial")
    out = [{"tool": r["name"], "calls": int(number(r, "count_count")), "p50_ms": round(number(r, "p50_latency")),
            "p95_ms": round(number(r, "p95_latency")), "total_s": round(number(r, "sum_latency") / 1000)}
           for r in rows if TOOL_SPAN.match(r.get("name") or "") and r["name"] not in HUMAN_WAIT]
    return sorted(out, key=lambda t: -t["total_s"])[:TOP_TOOLS]


def share(part, whole):
    return round(part / whole, 4) if whole else None


def tool_errors(c):
    levels = {r.get("level"): int(number(r, "count_count"))
              for r in c.metrics((("count", "count"),), ["level"], "name", [EXEC_SPAN])}
    total, errors = sum(levels.values()), levels.get("ERROR", 0)
    by_class, truncated = c.errors_by(EXEC_SPAN, "attributes.error_class") if errors else ({}, False)
    return {"executions": total, "errors": errors, "share": share(errors, total), "by_class": by_class,
            "truncated": truncated}


def gateway(c):
    rows = c.metrics((("count", "count"), ("totalCost", "sum"), ("totalTokens", "sum"), ("latency", "p95")),
                     ["providedModelName", "level"], "name", [GATEWAY_SPAN])
    models = {}
    for r in rows:
        m = models.setdefault(r.get("providedModelName") or "unknown",
                              {"calls": 0, "errors": 0, "cost_usd": 0.0, "tokens": 0, "p95_ms": 0})
        n = int(number(r, "count_count"))
        m["calls"] += n
        failed = r.get("level") == "ERROR"
        m["errors"] += n if failed else 0
        m["cost_usd"] += number(r, "sum_totalCost")
        m["tokens"] += int(number(r, "sum_totalTokens"))
        m["p95_ms"] = m["p95_ms"] if failed else max(m["p95_ms"], round(number(r, "p95_latency")))
    calls, errors = sum(m["calls"] for m in models.values()), sum(m["errors"] for m in models.values())
    for m in models.values():
        m["cost_usd"] = round(m["cost_usd"], 4)
    by_error, truncated = c.errors_by(GATEWAY_SPAN, "attributes.error.type") if errors else ({}, False)
    return {"calls": calls, "errors": errors, "error_share": share(errors, calls),
            "cost_usd": round(sum(m["cost_usd"] for m in models.values()), 4),
            "tokens": sum(m["tokens"] for m in models.values()),
            "by_model": dict(sorted(models.items(), key=lambda kv: -kv[1]["cost_usd"])),
            "by_error": by_error, "truncated": truncated}


def utc(text):
    """An argparse type: a bad date is a usage error."""
    return dt.datetime.fromisoformat(text).astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def main():
    ap = argparse.ArgumentParser(prog="agent-usage langfuse", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--since", required=True, type=utc)
    ap.add_argument("--until", required=True, type=utc)
    a = ap.parse_args()
    try:
        c = Client(a.since, a.until)
        out = {"tools": tools(c), "tool_errors": tool_errors(c), "gateway": gateway(c)}
    except Unreadable as e:
        print(f"langfuse: {e}", file=sys.stderr)
        return 1
    print(json.dumps(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
