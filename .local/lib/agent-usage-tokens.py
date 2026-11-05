#!/usr/bin/env python3
"""agent-usage tokens: one JSON per day of token use, its one-line row, and a drift check.

  agent-usage tokens snapshot [--date D] [--no-verify]   write $TOKENS_DIR/<D>.json (default yesterday)
  agent-usage tokens line [--date D]                     the day's one-line row (default newest)
  agent-usage tokens json --date D                       the day's snapshot, for day-log
  agent-usage tokens check                               the newest day against the 7 before it

No scanner of its own: every number comes from one of the two counted tools, so this file only
joins them. Who owns which number:
  claude-recall tool-output  per-response tokens, context per response, tool output and its
                             carried cost, by project, command head and token-filter method, and
                             the stretches that ran longest without a compaction (long_runs)
  agent-usage burn           cost (registry), merged PRs and cost per merged PR, start context
                             (first-turn median), compactions, tokens by model
  token-filter verify        the nightly rtk replay; --apply adds a local skip per failing shape
A day is the local calendar day, the window both tools are given exactly.

check exits 0 when every watched number is within TOKENS_DRIFT_PCT of the median of the
TOKENS_BASELINE_DAYS days before it, 1 on a drift, 2 when there is no fresh snapshot. It only
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
VERIFY = shlex.split(ENV.get("TOKENS_VERIFY_CMD", "token-filter verify --apply --json"))
DRIFT_PCT = float(ENV.get("TOKENS_DRIFT_PCT", "25"))
BASELINE_DAYS = int(ENV.get("TOKENS_BASELINE_DAYS", "7"))
MIN_BASELINE = 3      # fewer earlier days than this and there is no median to compare with
STALE_DAYS = 2        # the newest snapshot older than this means the nightly stopped
TOP_COMMANDS = 20
# The watched numbers: (key, label). Each is a ratio, so a busy or a quiet day alone moves none.
WATCHED = (("context_per_response", "context per response"),
           ("carried_share", "carried share"),
           ("start_context_median", "start-context median"))


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


def snapshot(day, verify):
    start, end = day_window(day)
    s, e = start.isoformat(timespec="seconds"), end.isoformat(timespec="seconds")
    recall = RECALL + ["--since", s, "--until", e, "--json", "--by"]
    jobs = {"recall --by project": recall + ["project", "--top", "0"],
            "recall --by command": recall + ["command", "--top", str(TOP_COMMANDS)],
            "recall --by method": recall + ["method", "--top", "0"],
            "burn": BURN + ["--before", e, "--days", f"{(end - start).total_seconds() / 86400:.6f}", "--json"]}
    if verify:
        jobs["token-filter verify"] = VERIFY
    with ThreadPoolExecutor(len(jobs)) as pool:  # independent reads: the day costs the slowest one
        got = dict(zip(jobs, pool.map(run_json, jobs.values())))
    errors = [f"{name}: {err}" for name, (_, err) in got.items() if err]
    proj, cmd, meth, burn = (got[k][0] or {} for k in
                             ("recall --by project", "recall --by command", "recall --by method", "burn"))
    tf = got.get("token-filter verify", (None, None))[0]

    t = proj.get("totals") or {}
    tu = usage(t)
    ctx, turns = tu["context"], tu["responses"]
    prs = burn.get("merged_prs")
    per_pr = burn.get("per_merged_pr") or {}
    by_project = {r["key"]: usage(r) for r in proj.get("rows") or []}
    for k, v in (burn.get("by_project") or {}).items():
        by_project.setdefault(k, {}).update(sessions=v.get("sessions"), cost_usd=round(v.get("cost_usd") or 0, 2))
    long_runs = proj.get("long_runs") or {}
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
        "compactions": burn.get("compactions"),
        "by_project": dict(sorted(by_project.items(), key=lambda kv: -(kv[1].get("context") or 0))),
        "by_command": [{"head": r["key"], "calls": r["calls"], "chars": r["chars"], "carried_tokens": r["carried"] // 4}
                       for r in cmd.get("rows") or []],
        "by_method": {r["key"]: {**usage(r), "bash_calls": r.get("bash_calls", 0), "filtered": r.get("rewritten", 0)}
                      for r in meth.get("rows") or []},
        "by_model": burn.get("by_model"),
        "by_account": burn.get("by_account"),
        "by_kind": burn.get("by_kind"),
        "long_runs": long_runs or None,
        "token_filter": verify_summary(tf),
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


def verify_summary(tf):
    if tf is None:
        return None
    out = {k: tf.get(k) for k in ("method", "replayed", "rewritten", "ok", "bad", "saved_pct", "skips_added")}
    out["bad_cmds"] = [{"cmd": (b.get("cmd") or "")[:120], "verdict": b.get("verdict")} for b in tf.get("bad_cmds") or []]
    return out


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
    tf = s.get("token_filter")
    parts = [f"tokens {s['date']}: {human(t['context'])} context over {t['responses']:,} responses",
             f"{human(s['context_per_response'])}/response",
             f"carried {100 * (s['carried_share'] or 0):.0f}% ({s['carried_x'] or '?'}x its size)",
             f"start median {human(s['start_context_median'])}",
             f"${pr:,.2f}/merged PR ({s['merged_prs']})" if pr is not None else f"{s.get('merged_prs') or 0} merged PRs",
             f"{lr.get('long', 0)} long runs without compaction"]
    if tf:
        parts.append(f"token-filter {tf.get('ok')}/{tf.get('rewritten')} ok, {len(tf.get('skips_added') or [])} skips added")
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
    drift, said = [], []
    for key, label in WATCHED:
        now = newest.get(key)
        vals = [x[key] for x in base if x.get(key) is not None]
        if now is None or len(vals) < MIN_BASELINE:
            said.append(f"{label} {now if now is not None else '?'} (baseline {len(vals)} days)")
            continue
        med = statistics.median(vals)
        pct = 100 * (now - med) / med if med else 0.0
        txt = f"{label} {num(now)} vs 7-day median {num(med)} ({pct:+.0f}%)"
        said.append(txt)
        if abs(pct) > DRIFT_PCT:
            drift.append(txt)
    if drift:
        print(f"{newest['date']}: drift past {DRIFT_PCT:.0f}%: " + "; ".join(drift))
        return 1
    print(f"{newest['date']}: " + "; ".join(said))
    return 0


def main():
    ap = argparse.ArgumentParser(prog="agent-usage tokens", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="verb", required=True)
    sp = sub.add_parser("snapshot")
    sp.add_argument("--date", type=dt.date.fromisoformat)
    sp.add_argument("--no-verify", action="store_true", help="skip token-filter verify --apply")
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
        path, out = snapshot(day, not a.no_verify)
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
