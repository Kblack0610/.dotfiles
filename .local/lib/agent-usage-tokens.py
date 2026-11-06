#!/usr/bin/env python3
"""agent-usage tokens: one JSON per day of token use, its one-line row, and a drift check.

  agent-usage tokens snapshot [--date D]                 write $TOKENS_DIR/<D>.json (default yesterday)
  agent-usage tokens line [--date D]                     the day's one-line row (default newest)
  agent-usage tokens json --date D                       the day's snapshot, for day-log
  agent-usage tokens check                               the newest day against the 7 before it

No scanner of its own: every number comes from one of the counted tools, so this file only
joins them. Who owns which number:
  claude-recall tool-output  per-response tokens, context per response, tool output and its
                             carried cost, by project, tool and Bash command head, and
                             the stretches that ran longest without a compaction (long_runs),
                             cache write by cause, the context split (start, tool,
                             conversation), responses per session, hook-forced turns
  claude-recall tool-calls   read discipline and read triggers (reads), hot_targets
  agent-usage langfuse       tool latency, tool errors by class, gateway calls, cost and errors;
                             null when Langfuse cannot answer
  agent-usage burn           cost (registry), merged PRs and cost per merged PR, start context
                             (first-turn median), compactions, tokens by model
A day is the local calendar day, the window both tools are given exactly.

check exits 0 unless a watched number moved the worse way by more than TOKENS_DRIFT_PCT of the
median of the TOKENS_BASELINE_DAYS days before it, or the better way by more than TOKENS_SUSPECT_PCT
(a broken counter looks like a cliff); 1 on either, 2 when there is no fresh snapshot. It only
reports: nothing here stops, limits or slows a session (dotfiles CLAUDE.md "Agent runtime").
"""
import argparse
import datetime as dt
import json
import math
import os
import shlex
import statistics
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ENV = os.environ
DIR = Path(ENV.get("TOKENS_DIR", Path.home() / ".agent" / "token-usage"))
RECALL = shlex.split(ENV.get("TOKENS_RECALL_CMD", "claude-recall tool-output"))
BURN = shlex.split(ENV.get("TOKENS_BURN_CMD", "agent-usage burn"))
CALLS = shlex.split(ENV.get("TOKENS_CALLS_CMD", "claude-recall tool-calls"))
LANGFUSE = shlex.split(ENV.get("TOKENS_LANGFUSE_CMD", "agent-usage langfuse"))
DRIFT_PCT = float(ENV.get("TOKENS_DRIFT_PCT", "25"))
SUSPECT_PCT = float(ENV.get("TOKENS_SUSPECT_PCT", "50"))
BASELINE_DAYS = int(ENV.get("TOKENS_BASELINE_DAYS", "7"))
MIN_BASELINE = 3      # fewer earlier days than this and there is no median to compare with
STALE_DAYS = 2        # the newest snapshot older than this means the nightly stopped
TOP_COMMANDS = 20
TOP_TARGETS = 20      # the files whose reads cost the most responses that day
# The watched numbers: (key, label, worse), worse the sign of a move for the worse. Each is a ratio,
# so a busy or a quiet day alone moves none.
WATCHED = (("context_per_response", "context per response", 1),
           ("carried_share", "carried share", 1),
           ("start_context_median", "start-context median", 1))


def run_json(cmd, timeout=3600):
    """(parsed stdout, None) or (None, why)."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, f"{cmd[0]}: {e}"
    try:
        return json.loads(p.stdout), None
    except ValueError:
        return None, f"{' '.join(cmd[:3])}: exit {p.returncode}, {(p.stderr or p.stdout).strip()[-200:]}"


def today():
    return dt.date.fromisoformat(ENV["TOKENS_TODAY"]) if ENV.get("TOKENS_TODAY") else dt.date.today()


def day_window(day):
    start = dt.datetime.combine(day, dt.time()).astimezone()
    end = dt.datetime.combine(day + dt.timedelta(days=1), dt.time()).astimezone()
    return start, end


def snapshot(day):
    start, end = day_window(day)
    s, e = start.isoformat(timespec="seconds"), end.isoformat(timespec="seconds")
    recall = RECALL + ["--since", s, "--until", e, "--json", "--by"]
    jobs = {"recall --by project": recall + ["project", "--top", "0"],
            "recall --by command": recall + ["command", "--top", str(TOP_COMMANDS)],
            "recall --by session,tool": recall + ["session,tool", "--top", "0"],
            "tool-calls": CALLS + ["--since", s, "--until", e, "--json", "--top", str(TOP_TARGETS)],
            "burn": BURN + ["--before", e, "--days", f"{(end - start).total_seconds() / 86400:.6f}", "--json"],
            "langfuse": LANGFUSE + ["--since", s, "--until", e]}
    with ThreadPoolExecutor(len(jobs)) as pool:  # independent reads: the day costs the slowest one
        got = dict(zip(jobs, pool.map(run_json, jobs.values())))
    errors = [f"{name}: {err}" for name, (_, err) in got.items() if err]
    proj, cmd, tool, calls, burn = (got[k][0] or {} for k in ("recall --by project", "recall --by command",
                                                             "recall --by session,tool", "tool-calls", "burn"))

    t = proj.get("totals") or {}
    tu = usage(t)
    ctx, turns = tu["context"], tu["responses"]
    prs = burn.get("merged_prs")
    per_pr = burn.get("per_merged_pr") or {}
    by_project = {r["key"]: usage(r) for r in proj.get("rows") or []}
    for k, v in (burn.get("by_project") or {}).items():
        by_project.setdefault(k, {}).update(sessions=v.get("sessions"), cost_usd=round(v.get("cost_usd") or 0, 2))
    long_runs = proj.get("long_runs") or {}
    rd = (calls.get("buckets") or {}).get("all") or {}
    reads = {k: rd.get(k, 0) for k in ("reads", "locate_then_read", "reread_same_lines",
                                       "locate_then_read_ctx", "reread_same_lines_ctx",
                                       "read_after_compaction", "read_after_subagent", "read_rule_doc")}
    out = {
        "schema": 1,
        "date": day.isoformat(),
        "window": {"start": s, "end": e},
        "generated_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "errors": errors,
        "totals": {**tu, "input": t.get("input_tokens"), "cache_write": t.get("cache_creation_input_tokens"),
                   "cache_read": t.get("cache_read_input_tokens"), "tool_calls": t.get("calls"),
                   "cost_usd": (burn.get("registry") or {}).get("cost_usd"),
                   "sessions": (burn.get("registry") or {}).get("sessions")} if t else None,
        "context_per_response": ctx // turns if turns else None,
        "carried_share": round(tu["carried_tokens"] / ctx, 4) if ctx else None,
        "carried_x": t.get("carried", 0) // t["chars"] if t.get("chars") else None,
        "start_context_median": (burn.get("first_turn_context") or {}).get("median"),
        "merged_prs": prs,
        "cost_per_merged_pr": per_pr.get("cost_usd"),
        "context_per_merged_pr": ctx // prs if prs else None,
        "responses_per_merged_pr": round(turns / prs, 1) if prs else None,
        "tool_chars_per_call": tu["tool_chars"] // t["calls"] if t.get("calls") else None,
        "reads": reads if rd else None,
        "locate_read_share": round(reads["locate_then_read"] / reads["reads"], 4) if reads["reads"] else None,
        "reread_share": round(reads["reread_same_lines"] / reads["reads"], 4) if reads["reads"] else None,
        "hot_targets": [{"path": g["key"], "sessions": g["calls"], "ctx": g["ctx"]}
                        for g in (calls.get("groups") or {}).get("hot_target") or []][:TOP_TARGETS] or None,
        "compactions": burn.get("compactions"),
        "context_split": proj.get("context_split"),
        "cache_write_by_cause": proj.get("cache_write_by_cause"),
        "responses_per_session": proj.get("sessions"),
        "hook_turns": proj.get("hook_turns"),
        "by_project": dict(sorted(by_project.items(), key=lambda kv: -(kv[1].get("context") or 0))),
        **by_tool(tool, (burn.get("registry") or {}).get("cost_by_session")),
        "by_command": split(cmd, "head"),
        "by_model": burn.get("by_model"),
        "by_account": burn.get("by_account"),
        "by_kind": burn.get("by_kind"),
        "long_runs": long_runs or None,
        "langfuse": got["langfuse"][0],
    }
    out["line"] = line_of(out)
    DIR.mkdir(parents=True, exist_ok=True)
    path = DIR / f"{day.isoformat()}.json"
    tmp = path.with_suffix(".json.tmp")
    tmp.write_text(json.dumps(out, indent=1) + "\n")
    tmp.replace(path)
    return path, out


def usage(r):
    """A recall totals or row object in the snapshot's names; context is everything read."""
    c = r.get("input_tokens", 0) + r.get("cache_creation_input_tokens", 0) + r.get("cache_read_input_tokens", 0)
    return {"responses": r.get("turns", 0), "context": c, "output": r.get("output_tokens", 0),
            "tool_chars": r.get("chars", 0), "carried_tokens": r.get("carried", 0) // 4}


def split(recall, name):
    """A recall --by command result as [{<name>, calls, chars, carried_tokens}]."""
    return [{name: r["key"], "calls": r["calls"], "chars": r["chars"], "carried_tokens": r["carried"] // 4}
            for r in recall.get("rows") or []]


def by_tool(recall, costs):
    """by_tool from a recall --by session,tool result, and each session's registry cost split over
    its tools by their share of its carried tokens: an allocation, never a metered figure. A session
    with no carried tool output in the day allocates nothing; its cost is by_tool_unallocated_usd,
    so the allocations and it sum to totals.cost_usd. The registry books a session's whole cost on the
    day it was last updated, so the split uses that day's carried output: a multi-day session's
    earlier days carry no weight. No cost per session leaves both fields null."""
    tools, per = {}, {}
    for r in recall.get("rows") or []:
        sess, name = r["key"]
        t = tools.setdefault(name, {"tool": name, "calls": 0, "chars": 0, "carried_tokens": 0})
        t["calls"] += r["calls"]
        t["chars"] += r["chars"]
        t["carried_tokens"] += r["carried"]  # chars until the end, as tokens below
        per.setdefault(sess, {})[name] = per.get(sess, {}).get(name, 0) + r["carried"]
    unallocated = None
    for t in tools.values():
        t["allocated_cost_usd"] = None
    if costs is not None:
        alloc, unallocated = dict.fromkeys(tools, 0.0), 0.0
        for sess, cost in costs.items():
            carried = per.get(sess) or {}
            whole = sum(carried.values())
            if not whole:
                unallocated += cost or 0
                continue
            for name, n in carried.items():
                alloc[name] += (cost or 0) * n / whole
        for name, t in tools.items():
            t["allocated_cost_usd"] = round(alloc[name], 4)
        unallocated = round(unallocated, 4)
    for t in tools.values():
        t["carried_tokens"] //= 4
    rows = sorted(tools.values(), key=lambda t: -t["chars"])
    return {"by_tool": rows, "by_tool_unallocated_usd": unallocated}


def human(n):
    if n is None:
        return "?"
    for div, unit in ((1e9, "B"), (1e6, "M"), (1e3, "k")):
        if n >= div:
            return f"{math.floor(n / div * 10) / 10:.1f}{unit}"  # rounded down, as day-log's tok
    return str(n)


def line_of(s):
    """The one-line row day-log and the fleet-bench scorecard print. Built here, once."""
    t = s.get("totals")
    if not t:
        return f"tokens {s['date']}: unreadable ({'; '.join(s.get('errors') or []) or 'no totals'})"
    pr = s.get("cost_per_merged_pr")
    lr = s.get("long_runs") or {}
    parts = [f"tokens {s['date']}: {human(t['context'])} context over {t['responses']:,} responses",
             f"{human(s['context_per_response'])}/response",
             f"carried {100 * (s['carried_share'] or 0):.0f}% ({s['carried_x'] or '?'}x its size)",
             f"start median {human(s['start_context_median'])}",
             f"${pr:,.2f}/merged PR ({s['merged_prs']})" if pr is not None else f"{s.get('merged_prs') or 0} merged PRs",
             f"{lr.get('long', 0)} long runs without compaction"]
    if s.get("errors"):
        parts.append(f"{len(s['errors'])} source errors")
    return ", ".join(parts)


def num(v):
    return f"{v:,.0f}" if abs(v) >= 100 else f"{v:.3g}"


def snapshots():
    return sorted(p for p in DIR.glob("????-??-??.json"))


def load(p):
    try:
        return json.loads(p.read_text())
    except (OSError, ValueError):
        return None


def check():
    files = snapshots()
    if not files:
        print(f"no token-usage snapshot in {DIR} (agent-usage tokens snapshot)")
        return 2
    newest = load(files[-1])
    if newest is None:
        print(f"{files[-1]} is unreadable")
        return 2
    age = (today() - dt.date.fromisoformat(newest["date"])).days
    if age > STALE_DAYS:
        print(f"newest token-usage snapshot is {newest['date']}, {age} days old: the nightly agentctl token-usage run stopped")
        return 2
    base = [x for x in (load(p) for p in files[-1 - BASELINE_DAYS:-1]) if x]
    drift, suspect, said = [], [], []
    for key, label, worse in WATCHED:
        now = newest.get(key)
        vals = [x[key] for x in base if x.get(key) is not None]
        if now is None or len(vals) < MIN_BASELINE:
            said.append(f"{label} {now if now is not None else '?'} (baseline {len(vals)} days)")
            continue
        med = statistics.median(vals)
        pct = 100 * (now - med) / med if med else 0.0
        txt = f"{label} {num(now)} vs 7-day median {num(med)} ({pct:+.0f}%)"
        said.append(txt)
        if pct * worse > DRIFT_PCT:
            drift.append(txt)
        elif -pct * worse > SUSPECT_PCT:
            suspect.append(txt)
    out = ([f"worse past {DRIFT_PCT:.0f}%: " + "; ".join(drift)] if drift else []) \
        + ([f"better past {SUSPECT_PCT:.0f}%, measurement suspect: " + "; ".join(suspect)] if suspect else [])
    if out:
        print(f"{newest['date']}: " + "; ".join(out))
        return 1
    print(f"{newest['date']}: " + "; ".join(said))
    return 0


def main():
    ap = argparse.ArgumentParser(prog="agent-usage tokens", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="verb", required=True)
    sp = sub.add_parser("snapshot")
    sp.add_argument("--date", type=dt.date.fromisoformat)
    lp = sub.add_parser("line")
    lp.add_argument("--date", type=dt.date.fromisoformat)
    jp = sub.add_parser("json")
    jp.add_argument("--date", type=dt.date.fromisoformat, required=True)
    sub.add_parser("check")
    a = ap.parse_args()
    if a.verb == "snapshot":
        day = a.date or today() - dt.timedelta(days=1)
        if day >= today():
            ap.error(f"{day} is not over yet; a snapshot is of a finished day")
        path, out = snapshot(day)
        print(path)
        print(out["line"])
        return 1 if out["totals"] is None else 0
    if a.verb == "json":
        s = load(DIR / f"{a.date}.json")
        if not s:
            print(f"agent-usage tokens: no snapshot for {a.date} in {DIR}", file=sys.stderr)
            return 1
        print(json.dumps(s))
        return 0
    if a.verb == "line":
        p = DIR / f"{a.date}.json" if a.date else (snapshots() or [None])[-1]
        s = load(p) if p else None
        if not (s and s.get("line")):
            print(f"agent-usage tokens: no snapshot{' for ' + str(a.date) if a.date else ''} in {DIR}", file=sys.stderr)
            return 1
        print(s["line"])
        return 0
    return check()


if __name__ == "__main__":
    sys.exit(main())
