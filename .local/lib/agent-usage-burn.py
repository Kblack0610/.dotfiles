#!/usr/bin/env python3
"""agent-usage burn: where a window's Claude tokens went, from counted sources only.

Called by `agent-usage burn`; it owns every number the usage-cleanup skill reports, so a
pass and the next one measure the same way. Not on a render path: it reads every
transcript touched in the window (minutes for a week of a busy fleet).

Sources and what each one is trusted for:
  transcripts  $PROJECTS_ROOT/**/*.jsonl, main and subagent threads. Tokens, models,
               turns, triggers, tool calls. One assistant message is counted once, by
               message id (streamed chunks repeat the same usage).
  registry     $SESS_ROOT/*/sessions.jsonl. Cost (reported by Claude Code, never priced
               here) and the account, read from the transcript path's account dir.
  outcomes     $OUTCOMES_ROOT/*/*.jsonl. Merged PRs, one per repo#number merged in the window.
  dream log    $DREAM_LOG. Dream runs per night (dry runs left out).
  requests     the api-request-shape and api-request-blob lines Claude Code writes before a
               session's first response: what that first request carried, part by part, in
               chars (first_request_parts). Chars, because only the request total has a
               token count; chars_per_token is that total over these chars.
There is no price table on purpose; see the agent-usage header.
"""
import argparse
import datetime as dt
import glob
import json
import os
import re
import statistics
import sys
from collections import Counter, defaultdict

WAIT_RE = re.compile(
    r"(^|[;&|\s(])sleep\s+\d|\buntil\b.*;\s*do\b|gh pr checks\b.*--watch|gh run watch\b"
    r"|/tasks/[^\s'\"]+\.output")
IDLE_LONG = 3600     # the prompt cache TTL these sessions request ("1h")
IDLE_SHORT = 300     # the default cache TTL

# Where each part of the first request's system-role text starts. Text before the first
# marker is system_other.
SYS_PARTS = [("preflight", r"SessionStart hook additional context"), ("environment", r"^# Environment\n"),
             ("deferred_list", r"^The following deferred tools are now available"),
             ("agent_listing", r"^Available agent types for the Agent tool"),
             ("mcp_instructions", r"^# MCP Server Instructions"),
             ("skill_listing", r"^The following skills are available for use with the Skill tool")]


def request_parts(shape, blobs):
    """Chars per part of one recorded first request: system prompt, tool schemas, the
    system-role listings, and the CLAUDE.md / MEMORY.md files in the first user block."""
    parts, tools = Counter(), Counter()
    parts["system_prompt"] = sum(len(b.get("text", "")) for b in shape.get("system") or [])
    for t in shape.get("tools") or []:
        n = t.get("name", "?")
        tools[n] = len(json.dumps(t))
        parts["tools_mcp" if n.startswith("mcp__") else "tools_builtin"] += tools[n]
    for m in blobs:
        for j, b in enumerate(m.get("content") or []):
            txt = b.get("text", "") if isinstance(b, dict) else ""
            if m.get("role") == "system":
                pos = sorted((x.start(), n) for n, pat in SYS_PARTS for x in [re.search(pat, txt, re.M)] if x)
                parts["system_other"] += pos[0][0] if pos else len(txt)
                for k, (at, n) in enumerate(pos):
                    parts[n] += (pos[k + 1][0] if k + 1 < len(pos) else len(txt)) - at
            elif j == 0 and "Contents of /" in txt:
                for seg in re.split(r"(?=Contents of /)", txt):
                    f = re.match(r"Contents of (\S+)", seg)
                    if not f:
                        parts["instructions_other"] += len(seg)
                    elif f.group(1).endswith("MEMORY.md"):
                        parts["memory_md"] += len(seg)
                    elif os.path.basename(os.path.dirname(f.group(1))).startswith(".claude"):
                        parts["global_claude_md"] += len(seg)
                    else:
                        parts["repo_claude_md"] += len(seg)
            else:
                parts["prompt"] += len(txt)
    return parts, tools


def ts(s):
    try:
        return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return None


def text_of(msg):
    c = msg.get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, list):
        return "\n".join(x.get("text", "") for x in c if isinstance(x, dict) and x.get("type") == "text")
    return ""


def trigger(d):
    """What started the API call that follows this user line (agent-usage wakes' names)."""
    msg = d.get("message") or {}
    c = msg.get("content")
    if isinstance(c, list) and any(isinstance(x, dict) and x.get("type") == "tool_result" for x in c):
        return "tool-result"
    t = text_of(msg).lstrip()
    if "<task-notification>" in t:
        return "background-task"
    if t.startswith("Another Claude session sent a message"):
        return "peer-message"
    if "continued from a previous conversation" in t:
        return "compaction"
    if t.startswith("Stop hook"):
        return "stop-hook"
    if "<command-message>" in t:
        return "command"
    if d.get("isMeta") or t.startswith("Base directory for this skill") or not re.sub(
            r"<system-reminder>[\s\S]*?</system-reminder>", "", t).strip():
        return "meta"
    return "human"


def kind_of(path, first):
    if "/subagents/" in path:
        return "subagent"
    if first.get("entrypoint") == "sdk-cli":
        return "headless"
    if "/.worktrees/" in (first.get("cwd") or ""):
        return "worktree"
    return "interactive"


def scan(path, start, end, acc):
    seen, last_t, pending, after_compact = set(), None, "human", False
    ctx_by_mid, wait_mids = {}, set()
    first, turns, seq = None, 0, 0  # seq: the session's responses, in the window or not
    shape, blobs = None, []  # the first request, as recorded before the first response
    try:
        fh = open(path, errors="ignore")
    except OSError:
        return
    with fh:
        for line in fh:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if first is None and d.get("type") in ("user", "assistant"):
                first = d
            t = d.get("type")
            if t == "api-request-shape" and shape is None and seq == 0:
                shape = d.get("shape") or {}
                continue
            if t == "api-request-blob" and seq == 0 and len(blobs) < 2:
                blobs.append(d.get("message") or {})
                continue
            if t == "system" and "compact" in str(d.get("subtype", "")):
                after_compact = True
                acc["compactions"] += 1 if start <= (ts(d.get("timestamp", "")) or 0) < end else 0
                continue
            if t == "user":
                pending = trigger(d)
                continue
            if t != "assistant":
                continue
            msg = d.get("message") or {}
            now = ts(d.get("timestamp", ""))
            in_win = now is not None and start <= now < end
            if in_win:
                for b in msg.get("content") or []:
                    if not isinstance(b, dict) or b.get("type") != "tool_use":
                        continue
                    inp = b.get("input") or {}
                    probe = inp.get("command") or inp.get("file_path") or ""
                    if isinstance(probe, str) and WAIT_RE.search(probe):
                        acc["wait_calls"] += 1
                        wait_mids.add(msg.get("id") or d.get("requestId"))
            mid = msg.get("id") or d.get("requestId")
            if not mid or mid in seen:
                continue
            seen.add(mid)
            u = msg.get("usage") or {}
            if not u:
                continue
            gap = (now - last_t) if (now and last_t) else None
            last_t = now or last_t
            model = msg.get("model") or "?"
            seq += model != "<synthetic>"
            if not in_win or model == "<synthetic>":
                after_compact = False
                continue
            turns += 1
            kind = kind_of(path, first or {})
            i, o = u.get("input_tokens", 0), u.get("output_tokens", 0)
            cw, cr = u.get("cache_creation_input_tokens", 0), u.get("cache_read_input_tokens", 0)
            ctx = i + cw + cr
            ctx_by_mid[mid] = ctx
            for key in (("kind", kind), ("model", model)):
                b = acc[key[0]][key[1]]
                b["turns"] += 1
                b["input"] += i
                b["output"] += o
                b["cache_write"] += cw
                b["cache_read"] += cr
            acc["kind_files"][kind].add(path)
            if seq == 1 and kind != "subagent":
                acc["first_ctx"].append(ctx)
                if shape is not None:
                    parts, tools = request_parts(shape, blobs)
                    acc["first_parts"].append((ctx, parts))
                    acc["first_tools"].update(tools)
                cause = "first-turn"
            elif after_compact:
                cause = "after-compaction"
            elif gap is not None and gap > IDLE_LONG:
                cause = "idle-over-1h"
                acc["idle_wakes"][pending]["wakes"] += 1
                acc["idle_wakes"][pending]["cache_write"] += cw
            elif gap is not None and gap > IDLE_SHORT:
                cause = "idle-5m-to-1h"
            else:
                cause = "in-flow"
            acc["cw_cause"][cause]["turns"] += 1
            acc["cw_cause"][cause]["cache_write"] += cw
            acc["trigger"][pending]["turns"] += 1
            acc["trigger"][pending]["context"] += ctx
            after_compact = False
    # A message's tool_use blocks can sit on lines after the one carrying its usage.
    acc["wait_ctx"] += sum(ctx_by_mid.get(x, 0) for x in wait_mids)


def registry(start, end, root):
    by_acct, by_proj, n, cost = defaultdict(lambda: Counter()), defaultdict(lambda: Counter()), 0, 0.0
    for f in glob.glob(os.path.join(root, "*", "sessions.jsonl")):
        rows = {}
        for line in open(f, errors="ignore"):
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("session_id"):
                rows[r["session_id"]] = r
        for r in rows.values():
            up = r.get("updated") or 0
            if not isinstance(up, (int, float)) or not start <= up < end:
                continue
            tx = r.get("transcript") or ""
            m = re.search(r"/\.(claude[^/]*)/projects/", tx)
            acct = m.group(1) if m else "?"
            c = r.get("cost_usd") or 0.0
            tok = (r.get("tokens") or {})
            for b, k in ((by_acct, acct), (by_proj, r.get("project") or "?")):
                b[k]["sessions"] += 1
                b[k]["cost_usd"] += c
                b[k]["cache_read"] += tok.get("cacheRead", 0) or 0
                b[k]["output"] += tok.get("output", 0) or 0
            n += 1
            cost += c
    return n, cost, by_acct, by_proj


def merged_prs(start, end, root):
    prs, zero_ctx, all_ctx, last = set(), 0, 0, {}
    for f in glob.glob(os.path.join(root, "*", "*.jsonl")):
        for line in open(f, errors="ignore"):
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("session_id"):
                last[r["session_id"]] = r
    for r in last.values():
        if not start <= (r.get("updated_epoch") or 0) < end:
            continue
        all_ctx += r.get("tokens_total") or 0
        if not r.get("prs_merged"):
            zero_ctx += r.get("tokens_total") or 0
        for p in r.get("prs") or []:
            m = ts(p.get("merged_at") or "")
            if p.get("state") == "MERGED" and m and start <= m < end:
                prs.add((p.get("repo"), p.get("number")))
    return len(prs), zero_ctx, all_ctx


def dream_runs(start, end, path):
    nights, stamp = Counter(), None
    try:
        lines = open(path, errors="ignore")
    except OSError:
        return {}
    for line in lines:
        m = re.match(r"=== (\d{4}-\d\d-\d\dT[\d:]+[-+]\d\d:\d\d) ===", line)
        if m:
            stamp = ts(m.group(1))
        elif line.startswith("agent: dream") and "dry-run: 0" in line and stamp and start <= stamp < end:
            nights[dt.datetime.fromtimestamp(stamp).strftime("%Y-%m-%d")] += 1
    return dict(sorted(nights.items()))


def main():
    ap = argparse.ArgumentParser(prog="agent-usage burn")
    ap.add_argument("--days", type=float, default=7)
    ap.add_argument("--before", help="end of the window (YYYY-MM-DD or ISO time), default now")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    end = ts(a.before) if a.before else dt.datetime.now().timestamp()
    if end is None:
        ap.error(f"bad --before {a.before!r} (use YYYY-MM-DD or an ISO time)")
    start = end - a.days * 86400
    env = os.environ
    home = os.path.expanduser("~")
    proj_root = env.get("PROJECTS_ROOT", f"{home}/.claude/projects")

    def tok():
        return Counter()
    acc = {"kind": defaultdict(tok), "model": defaultdict(tok), "cw_cause": defaultdict(tok),
           "trigger": defaultdict(tok), "idle_wakes": defaultdict(tok), "first_ctx": [],
           "first_parts": [], "first_tools": Counter(),
           "wait_calls": 0, "wait_ctx": 0, "compactions": 0, "kind_files": defaultdict(set)}
    for p in glob.glob(os.path.join(proj_root, "**", "*.jsonl"), recursive=True):
        try:
            if os.path.getmtime(p) < start:
                continue
        except OSError:
            continue
        scan(p, start, end, acc)

    n, cost, by_acct, by_proj = registry(start, end, env.get("SESS_ROOT", f"{home}/.agent/sessions"))
    prs, zero_ctx, out_ctx = merged_prs(start, end, env.get("OUTCOMES_ROOT", f"{home}/.agent/outcomes"))
    ctx_all = sum(b["input"] + b["cache_write"] + b["cache_read"] for b in acc["kind"].values())
    fc = sorted(acc["first_ctx"])

    def q(p):
        return fc[min(len(fc) - 1, int(len(fc) * p))] if fc else None
    fp = acc["first_parts"]
    fp_chars = sum(sum(p.values()) for _, p in fp)
    fp_keys = sorted({k for _, p in fp for k in p}, key=lambda k: (-sum(p.get(k, 0) for _, p in fp), k))
    out = {
        "window": {"start": dt.datetime.fromtimestamp(start).isoformat(timespec="minutes"),
                   "end": dt.datetime.fromtimestamp(end).isoformat(timespec="minutes"),
                   "transcripts": len(set().union(*acc["kind_files"].values()))},
        "registry": {"sessions": n, "cost_usd": round(cost, 2)},
        "by_account": {k: dict(v) for k, v in sorted(by_acct.items(), key=lambda x: -x[1]["cost_usd"])},
        "by_project": {k: dict(v) for k, v in sorted(by_proj.items(), key=lambda x: -x[1]["cost_usd"])},
        "by_kind": {k: {**v, "sessions": len(acc["kind_files"][k])}
                    for k, v in sorted(acc["kind"].items(), key=lambda x: -x[1]["cache_read"])},
        "by_model": {k: dict(v) for k, v in sorted(acc["model"].items(), key=lambda x: -x[1]["turns"])},
        "context_tokens": ctx_all,
        "merged_prs": prs,
        "per_merged_pr": {"context": ctx_all // prs if prs else None,
                          "cost_usd": round(cost / prs, 2) if prs else None},
        "zero_merge_context_share": round(zero_ctx / out_ctx, 3) if out_ctx else None,
        "first_turn_context": {"sessions": len(fc), "p10": q(0.1),
                               "median": int(statistics.median(fc)) if fc else None, "p90": q(0.9)},
        "first_request_parts": {
            "sessions": len(fp),
            "chars_per_token": round(fp_chars / sum(c for c, _ in fp), 2) if fp else None,
            "parts": {k: {"median_chars": int(statistics.median([p.get(k, 0) for _, p in fp])),
                          "mean_chars": sum(p.get(k, 0) for _, p in fp) // len(fp),
                          "share": round(sum(p.get(k, 0) for _, p in fp) / fp_chars, 3)} for k in fp_keys},
            "tools_mean_chars": {k: v // len(fp) for k, v in acc["first_tools"].most_common(12)} if fp else {},
        },
        "waits": {"calls": acc["wait_calls"], "context": acc["wait_ctx"],
                  "share": round(acc["wait_ctx"] / ctx_all, 3) if ctx_all else None},
        "cache_write_by_cause": {k: dict(v) for k, v in sorted(acc["cw_cause"].items(), key=lambda x: -x[1]["cache_write"])},
        "idle_wakes_by_trigger": {k: dict(v) for k, v in sorted(acc["idle_wakes"].items(), key=lambda x: -x[1]["wakes"])},
        "turns_by_trigger": {k: dict(v) for k, v in sorted(acc["trigger"].items(), key=lambda x: -x[1]["context"])},
        "compactions": acc["compactions"],
        "dream_runs_by_night": dream_runs(start, end, env.get("DREAM_LOG", f"{home}/.local/log/dream.log")),
    }
    if a.json:
        json.dump(out, sys.stdout, indent=1)
        print()
        return
    m = lambda x: f"{x / 1e6:,.1f}M" if x is not None else "-"  # noqa: E731
    w = out["window"]
    print(f"burn {w['start']} -> {w['end']}  ({w['transcripts']} transcripts with turns in the window)\n")
    print(f"registry: {n} sessions, ${cost:,.0f} reported; context read {m(ctx_all)}; "
          f"{prs} merged PRs, {m(out['per_merged_pr']['context'])} context and "
          f"${out['per_merged_pr']['cost_usd'] or 0:,.2f} per merged PR; "
          f"zero-merge sessions hold {out['zero_merge_context_share']} of outcome tokens\n")

    def table(title, rows, cols):
        print(title)
        print("  " + "\t".join(["name"] + cols))
        for k, v in rows.items():
            print("  " + "\t".join([k] + [f"{v.get(c, 0):,.0f}" if isinstance(v.get(c, 0), (int, float)) else str(v.get(c)) for c in cols]))
        print()
    table("by account (registry)", out["by_account"], ["sessions", "cost_usd", "cache_read", "output"])
    table("by project (registry)", out["by_project"], ["sessions", "cost_usd", "cache_read", "output"])
    table("by kind (transcripts)", out["by_kind"], ["sessions", "turns", "input", "output", "cache_write", "cache_read"])
    table("by model (transcripts)", out["by_model"], ["turns", "input", "output", "cache_write", "cache_read"])
    f = out["first_turn_context"]
    print(f"first-turn context (main threads): median {f['median']}, p10 {f['p10']}, p90 {f['p90']} over {f['sessions']} sessions")
    r = out["first_request_parts"]
    if r["sessions"]:
        print(f"first request by part ({r['sessions']} sessions, {r['chars_per_token']} chars a token): "
              + ", ".join(f"{k} {v['mean_chars']:,} ({v['share']:.0%})" for k, v in r["parts"].items() if v["share"] >= 0.005))
        print("  largest tools (mean chars): " + ", ".join(f"{k} {v:,}" for k, v in r["tools_mean_chars"].items()))
    wt = out["waits"]
    print(f"wait-style calls: {wt['calls']:,}, context {m(wt['context'])} ({wt['share']} of all)")
    print(f"compactions: {out['compactions']}\n")
    table("cache write by cause", out["cache_write_by_cause"], ["turns", "cache_write"])
    table("wakes after an idle gap over 1h, by trigger", out["idle_wakes_by_trigger"], ["wakes", "cache_write"])
    table("turns by trigger", out["turns_by_trigger"], ["turns", "context"])
    print("dream runs by night: " + (", ".join(f"{k} {v}" for k, v in out["dream_runs_by_night"].items()) or "none"))


if __name__ == "__main__":
    main()
