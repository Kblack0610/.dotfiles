#!/usr/bin/env python3
"""day-log-snapshots: the work, agents and ci sections of a day-log record, and the week.

  enrich --start S --end E [--prev FILE] [--ci-file FILE]   a record on stdin, the sections added
  ci --day D                                                a finished day's CI, slow: see below
  week [--date D] [--write] [--json | --line]               7 finished days against the 7 before

day-log runs this: it owns the record, and every env var read here is set and exported there.
No counter of its own: each number comes from the tool that owns it, so this file only joins
them, and a source it cannot read keeps the previous value and is named in .unreadable.
  agent-queue stats --json   queue flow per local day
  fleet-bench flow --json    plan phases
  ~/.notes history           board rows opened and closed
  agent-usage tokens json    tokens, cost, sessions by kind and account (the nightly snapshot)
  outcomes/*.jsonl           sessions with no PR, time use (the nightly session-outcomes)
  ci-failures --json         pass rate per workflow, reds on main, failure buckets
  scripts/ci-cost.py --json  gates, runner-hours, re-gates, quarantine (a repo that has one)

ci reads GitHub, a few hundred calls and minutes for a busy repo, so only `day-log nightly` runs
it, outside the record's lock; enrich keeps what it found.

week: a sum adds the days, a ratio is taken from those sums, a p50 or p90 is the median of the
daily values (a record keeps percentiles, not samples), a gauge is its last value, and cost is
and sessions are read over the whole window, because a session spans days.
A delta needs as many days with the metric in both weeks: fewer would read as a drop.
"""
import argparse
import datetime as dt
import json
import os
import re
import shlex
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path

ENV = os.environ
DIR = Path(ENV["DAYLOG_DIR"])
WEEKS = DIR / "weeks"
WINDOW = 7
CALL_TIMEOUT = 3600   # a guard, so a hung read fails its section instead of stalling the nightly
SHEETS = "*/projects/current/*/agent/README.md"
ROW = re.compile(r"^\s*- \[(.)\].*<!-- id:([\w-]+)[ >]")


def cmd(name):
    return shlex.split(ENV[name])


def run_json(argv, ok=(0,)):
    """(parsed stdout, error text); one of the two is None."""
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=CALL_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, str(e)
    if p.returncode not in ok:
        return None, (p.stderr.strip().splitlines() or [f"exit {p.returncode}"])[-1]
    try:
        return json.loads(p.stdout), None
    except ValueError:
        return None, "output is not JSON"


def load(path):
    try:
        return json.loads(Path(path).read_text())
    except (OSError, ValueError, TypeError):
        return None


def get(record, path):
    for key in path.split("."):
        record = record.get(key) if isinstance(record, dict) else None
    return record


def share(part, whole):
    return round(part / whole, 4) if whole else None


def day_bounds(day):
    """(start, end) epochs of a local calendar day, YYYY-MM-DD: 23 or 25 hours when the clocks move."""
    date = dt.date.fromisoformat(day)
    return tuple(int(dt.datetime.combine(d, dt.time()).astimezone().timestamp()) for d in (date, date + dt.timedelta(days=1)))


# --- the day ---------------------------------------------------------------

def queue_flow(day):
    since = (dt.date.fromisoformat(day) - dt.timedelta(days=1)).isoformat()  # done/ is dated in UTC
    stats, err = run_json(cmd("DAYLOG_QUEUE_CMD") + ["stats", "--json", "--flow", "--since", since])
    return (stats.get("flow", {}).get(day) or {}, None) if stats else (None, err)


def notes_git(*args):
    return subprocess.run(["git", "-C", ENV["DAYLOG_NOTES_DIR"], *args],
                          capture_output=True, text=True)


def rows_at(epoch):
    """{row id: its checkbox} on the agent sheets at that time. Compared across all sheets at once,
    so a row moved between sheets counts as neither opened nor closed. A row with no id is not counted."""
    when = dt.datetime.fromtimestamp(epoch, dt.timezone.utc).isoformat()
    commit = notes_git("rev-list", "-1", f"--before={when}", "HEAD")
    if commit.returncode:
        raise OSError(commit.stderr.strip() or "no notes history")
    head = commit.stdout.strip()
    if not head:
        return {}
    found = notes_git("grep", "-h", "-E", "<!-- id:", head, "--", SHEETS)
    if found.returncode > 1:
        raise OSError(found.stderr.strip())
    return {m[2]: m[1] for m in map(ROW.match, found.stdout.splitlines()) if m}


def board_flow(start, end):
    try:
        was, now = rows_at(start), rows_at(end)
    except OSError as e:
        return None, str(e)
    is_open = lambda state: state != "x"
    if not was:  # rows have had ids since 2026-11-04: before that there is nothing to join on
        return {"opened": None, "closed": None, "open_end": sum(map(is_open, now.values())) if now else None}, None
    opened = [i for i in now if i not in was]
    closed = ([i for i, s in now.items() if not is_open(s) and is_open(was.get(i, " "))]
              + [i for i, s in was.items() if i not in now and is_open(s)])
    return {"opened": len(opened), "closed": len(closed), "open_end": sum(map(is_open, now.values()))}, None


def phase_flow(start, end):
    flow, err = run_json(cmd("DAYLOG_BENCH_CMD") + ["flow", "--from", str(start), "--to", str(end), "--json"])
    if not flow:
        return None, err
    return {k: flow.get(k) for k in ("ticked", "added", "removed", "started")}, None


def merges(record):
    by_repo, by_area = {}, {}
    for pr in record.get("merged") or []:
        by_repo[pr["repo"]] = by_repo.get(pr["repo"], 0) + 1
        by_area[pr["area"]] = by_area.get(pr["area"], 0) + 1
    return {"by_repo": by_repo, "by_area": by_area}


def outcome_rows(start, end):
    """The sessions last active in the window, by session-outcomes' own reader (newest row of each)."""
    lib = Path(__file__).resolve().parent / "session-outcomes.sh"
    p = subprocess.run(["bash", "-c", '. "$1"; so_latest "$2"', "-", str(lib), ENV["DAYLOG_OUTCOMES_DIR"]],
                       capture_output=True, text=True, check=True, timeout=CALL_TIMEOUT)
    return [r for r in map(json.loads, p.stdout.splitlines()) if start <= (r.get("updated_epoch") or 0) < end]


def outcomes(start, end):
    rows = outcome_rows(start, end)
    no_pr = [r for r in rows if not r.get("prs")]
    time_use = {}
    for row in rows:
        for key, minutes in (row.get("time_use") or {}).items():
            time_use[key] = round(time_use.get(key, 0) + (minutes or 0), 1)
    total = lambda rs, key: sum(r.get(key) or 0 for r in rs)
    faults = lambda r: sum((r.get("hard_errors") or {}).values())
    return {"sessions": len(rows), "no_pr": len(no_pr), "no_pr_with_edits": sum(1 for r in no_pr if r.get("edits")),
            "no_pr_cost_usd": round(total(no_pr, "cost_usd"), 2), "prs_merged": total(rows, "prs_merged"),
            "reverted_7d": total(rows, "reverted_7d"),
            "interrupts": sum((r.get("corrections") or {}).get("interrupts") or 0 for r in rows),
            "hard_errors": sum(map(faults, rows)), "time_use": time_use}


def ask_ages(asks, now):
    hours = sorted((now - dt.datetime.fromisoformat(a["created"].replace("Z", "+00:00")).timestamp()) / 3600
                   for a in asks if a.get("created"))
    return {"open": len(asks), "age_h_p50": round(statistics.median(hours), 1) if hours else None,
            "age_h_max": round(hours[-1], 1) if hours else None}


def usage_of(snap):
    """What a token-usage snapshot says about the day, each value None when it has none yet."""
    snap = snap or {}
    t = snap.get("totals") or {}
    keep = lambda table, *keys: {k: {x: v.get(x) for x in keys} for k, v in table.items()} if table else None
    return {"sessions": t.get("sessions"),
            "tokens": {k: t.get(k) for k in ("context", "responses", "input", "cache_write", "cache_read")} if t else None,
            "cost_usd": t.get("cost_usd"), "merged_prs": snap.get("merged_prs"),
            "cost_per_merged_pr": snap.get("cost_per_merged_pr"),
            "by_kind": keep(snap.get("by_kind"), "sessions", "turns"),
            "by_account": keep(snap.get("by_account"), "sessions", "cost_usd")}


def enrich(a):
    record = json.load(sys.stdin)
    prev = load(a.prev) or {}
    day, live = record["date"], record["live"]
    bad = record["unreadable"]

    def read(name, path, source):
        """A section that fails must cost that section, never the snapshot that carries the rest."""
        try:
            value, err = source()
        except Exception as e:
            value, err = None, repr(e)
        if value is None:
            bad.append(f"{name}: {err}")
            return get(prev, path)
        return value

    # A missing snapshot is a day the nightly has not reached, so it is null and not a fault.
    snap = None if live else run_json(cmd("DAYLOG_USAGE_CMD") + ["tokens", "json", "--date", day])[0]
    now = float(ENV.get("DAYLOG_NOW") or time.time())
    record["work"] = {"queue": read("agent-queue", "work.queue", lambda: queue_flow(day)),
                      "merges": read("merges", "work.merges", lambda: (merges(record), None)),
                      "board": read("notes board", "work.board", lambda: board_flow(a.start, a.end)),
                      "phases": read("fleet-bench flow", "work.phases", lambda: phase_flow(a.start, a.end))}
    record["agents"] = {
        **usage_of(snap),
        # Today has no outcomes yet, and a past day has no live asks: it keeps its last gather's.
        "outcomes": None if live else read("outcomes", "agents.outcomes", lambda: (outcomes(a.start, a.end), None)),
        "asks": read("asks", "agents.asks", lambda: (ask_ages(record["waiting"]["asks"], now), None))
        if live and record.get("waiting") else get(prev, "agents.asks"),
    }
    record["ci"] = load(a.ci_file) if a.ci_file else prev.get("ci")
    bad.extend(f"ci {name}" for name in get(record, "ci.unreadable") or [])
    json.dump(record, sys.stdout)
    print()
    return 0


# --- CI, a finished day ----------------------------------------------------

def ci_repos():
    """[(owner/name, base branch, clone or None)] from DAYLOG_CI."""
    out = []
    with open(ENV["DAYLOG_CI"]) as f:
        for line in f:
            cols = line.split("#")[0].strip().split(None, 2)  # a clone's path may hold a space
            if cols:
                out.append((cols[0], cols[1], os.path.expanduser(cols[2]) if len(cols) > 2 else None))
    return out


def stamp(epoch):
    return dt.datetime.fromtimestamp(epoch, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def window_args(start, end):
    return ["--days", f"{(end - start) / 86400:.6f}", "--until", stamp(end), "--json"]


def ci_failures(repo, base, start, end):
    reader = ENV.get("DAYLOG_CI_FAILURES_CMD", "python3 " + str(Path.home() / ".claude/skills/ci-failures/ci-failures.py"))
    got, err = run_json(shlex.split(reader) + ["--repo", repo, "--base", base] + window_args(start, end), ok=(0, 3))  # 3: partial
    if got is None:
        return None, err
    runs, red = got.get("runs"), got.get("red_runs")
    return {"runs": runs, "red": red, "red_rate": share(red, runs), "pending": got.get("pending_runs"),
            "cancelled": got.get("cancelled"), "partial": got.get("partial"), "buckets": got.get("buckets"),
            "main": dict(zip(("runs", "red"), got.get("base") or (None, None))),
            "workflows": {wf: {"runs": n, "red": r, "pass_rate": share(n - r, n)}
                          for wf, (n, r) in (got.get("by_workflow") or {}).items()}}, None


def ci_cost(clone, base, day, start, end):
    """scripts/ci-cost.py as the base branch has it, so a stale checkout never measures. The cache only
    serves a retry of the same day, so a finished read removes it."""
    subprocess.run(["git", "-C", clone, "fetch", "-q", "origin", base], capture_output=True)
    script = subprocess.run(["git", "-C", clone, "show", f"origin/{base}:scripts/ci-cost.py"], capture_output=True, text=True)
    if script.returncode:
        return None, script.stderr.strip() or f"no scripts/ci-cost.py on origin/{base}"
    cache = Path(ENV.get("DAYLOG_CI_CACHE", Path.home() / ".cache" / "day-log" / "ci-cost")) / day
    with tempfile.NamedTemporaryFile("w", suffix=".py") as f:
        f.write(script.stdout)
        f.flush()
        got, err = run_json([sys.executable, f.name, *window_args(start, end), "--cache", str(cache), "--repo-dir", clone])
    if got is not None:
        shutil.rmtree(cache, ignore_errors=True)
    return got, err


def ci(a):
    out = {"gathered_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"), "repos": {}, "unreadable": []}
    try:
        repos = ci_repos()
    except OSError as e:
        out["unreadable"].append(f"{ENV.get('DAYLOG_CI')}: {e.strerror}")
        repos = []
    start, end = day_bounds(a.day)
    for repo, base, clone in repos:
        row, err = ci_failures(repo, base, start, end)
        if row is None:
            out["unreadable"].append(f"{repo} ci-failures: {err}")
            row = {}
        elif row["partial"]:
            out["unreadable"].append(f"{repo} ci-failures: partial")
        if clone:
            row["cost"], err = ci_cost(clone, base, a.day, start, end)
            if row["cost"] is None:
                out["unreadable"].append(f"{repo} ci-cost: {err}")
        out["repos"][repo] = row
    json.dump(out, sys.stdout)
    print()
    return 1 if out["unreadable"] else 0


# --- the week --------------------------------------------------------------

SUM = {"queue.queued": "work.queue.queued", "queue.started": "work.queue.started", "queue.waiting": "work.queue.waiting",
       "queue.done": "work.queue.done", "queue.failed": "work.queue.failed", "board.opened": "work.board.opened",
       "board.closed": "work.board.closed", "phases.ticked": "work.phases.ticked", "tokens.context": "agents.tokens.context",
       "merged_prs": "agents.merged_prs"}
MEDIAN = {"queue.lead_p50_min": "work.queue.lead_minutes.p50", "queue.lead_p90_min": "work.queue.lead_minutes.p90",
          "queue.wait_p50_min": "work.queue.wait_minutes.p50", "queue.wait_p90_min": "work.queue.wait_minutes.p90"}
LAST = {"board.open": "work.board.open_end", "asks.open": "agents.asks.open", "asks.age_h_max": "agents.asks.age_h_max"}
CI_SUM = {"runs": "runs", "red": "red", "main_red": "main.red", "runner_hours": "cost.hours.pool", "regated": "cost.regates.gates",
          "regated_branches": "cost.regates.branches_regated", "reruns": "cost.reruns"}
CI_MEDIAN = {"gate_wall_p50_min": "cost.gate.wall.p50", "gate_wall_p90_min": "cost.gate.wall.p90",
             "gate_wait_p50_min": "cost.queue.Tests.p50", "gate_wait_p90_min": "cost.queue.Tests.p90"}
CI_LAST = {"quarantine_open": "cost.quarantine.open"}
last = lambda values: values[-1]
TABLES = ((SUM, sum), (MEDIAN, statistics.median), (LAST, last))
CI_TABLES = ((CI_SUM, sum), (CI_MEDIAN, statistics.median), (CI_LAST, last))


def day_list(end, offset):
    return [(end - dt.timedelta(days=offset + i)).isoformat() for i in range(WINDOW - 1, -1, -1)]


def rollup(records):
    """{metric: (value, days it was read on)} over the records."""
    out = {}

    def fold(name, values, how):
        have = [v for v in values if v is not None]
        if have:
            out[name] = (round(how(have), 4), len(have))

    def fold_tables(tables, rows, prefix=""):
        for table, how in tables:
            for name, path in table.items():
                fold(prefix + name, [get(r, path) for r in rows], how)

    fold("merged", [len(r["merged"]) if "merged" in r else None for r in records], sum)
    fold_tables(TABLES, records)
    for repo in sorted({k for r in records for k in (get(r, "ci.repos") or {})}):
        short = repo.split("/")[-1].lstrip(".")
        rows = [(get(r, "ci.repos") or {}).get(repo) or {} for r in records]
        fold_tables(CI_TABLES, rows, f"ci.{short}.")
        if f"ci.{short}.runs" in out:
            days = out[f"ci.{short}.runs"][1]
            out[f"ci.{short}.red_rate"] = (share(out[f"ci.{short}.red"][0], out[f"ci.{short}.runs"][0]), days)
        for wf in sorted({w for row in rows for w in row.get("workflows") or {}}):
            cells = [c for c in ((row.get("workflows") or {}).get(wf) for row in rows) if c]
            out[f"ci.{short}.pass.{wf}"] = (share(sum(c["runs"] - c["red"] for c in cells), sum(c["runs"] for c in cells)), len(cells))
    return out


def window_usage(start, end):
    """(sessions, cost) over the window from the registry: a session counts once however many days it ran."""
    try:
        out = subprocess.run(cmd("DAYLOG_USAGE_CMD") + ["rollup", "--since", str(start), "--until", str(end)],
                             capture_output=True, text=True, timeout=CALL_TIMEOUT).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    rows = [line.split("\t") for line in out.splitlines() if line.count("\t") >= 4]
    total = [r for r in rows if r[0] == "TOTAL"] or rows
    return (sum(int(r[1]) for r in total), round(sum(float(r[4]) for r in total), 2)) if total else None


def side(span):
    """(records, metrics) of one week. Sessions and cost are read over the window, never added up
    from the days, because a session spans days."""
    records = [r for r in (load(DIR / f"{d}.json") for d in span) if r]
    out = rollup(records)
    if not records:
        return records, out
    start, end = day_bounds(span[0])[0], day_bounds(span[-1])[1]
    usage = window_usage(start, end)
    if usage:
        out["sessions.total"], out["cost_usd"] = (usage[0], WINDOW), (usage[1], WINDOW)
        prs, days_read = out.get("merged_prs", (0, 0))
        if prs and days_read == WINDOW:  # the PRs burn counts per day, so it reads like the daily number
            out["cost_per_merged_pr"] = (round(usage[1] / prs, 2), WINDOW)
    try:
        rows = outcome_rows(start, end)
    except (subprocess.SubprocessError, ValueError):
        rows = []
    if rows:
        out["sessions.no_pr"] = (sum(1 for r in rows if not r.get("prs")), WINDOW)
    return records, out


def compare(now, before):
    out = {}
    for name in sorted(set(now) | set(before)):
        value, days = now.get(name, (None, 0))
        prev, prev_days = before.get(name, (None, 0))
        like = days == prev_days and value is not None and prev is not None
        delta = round(value - prev, 4) if like else None
        out[name] = {"value": value, "prev": prev, "delta": delta, "days": days, "prev_days": prev_days,
                     "pct": round(100 * delta / prev, 1) if like and prev else None}
    return out


def signed(v, fmt):
    return "" if v is None else f" ({'+' if v >= 0 else '-'}{fmt(abs(v))})"


def line_of(week):
    m = week["metrics"]
    cell = lambda name: m.get(name) or {"value": None, "delta": None}
    plain = lambda v: f"{v:g}"
    usd = lambda v: f"${v:,.0f}"
    parts = [f"{cell('merged')['value'] or 0:g} merged{signed(cell('merged')['delta'], plain)}"]
    if cell("queue.done")["value"] is not None:
        parts.append(f"{cell('queue.done')['value']:g} queue items done{signed(cell('queue.done')['delta'], plain)}")
    if cell("board.opened")["value"] is not None and cell("board.closed")["value"] is not None:
        parts.append(f"board +{cell('board.opened')['value']:g}/-{cell('board.closed')['value']:g}")
    if cell("cost_usd")["value"] is not None:
        parts.append(f"{usd(cell('cost_usd')['value'])}{signed(cell('cost_usd')['delta'], usd)}")
    for name in sorted(k for k in m if k.endswith(".red_rate")):
        pts = lambda v: f"{100 * v:.0f} pts"
        parts.append(f"{name.split('.')[1]} red {100 * m[name]['value']:.0f}%{signed(m[name]['delta'], pts)}")
    return f"week to {week['end']} ({week['days_present']} of {WINDOW} days): " + ", ".join(parts)


def compute(end):
    days, before = day_list(end, 0), day_list(end, WINDOW)
    (records, now), (earlier, was) = side(days), side(before)
    week = {"schema": 1, "end": end.isoformat(), "start": days[0], "prev_start": before[0], "prev_end": before[-1],
            "days_present": len(records), "prev_days_present": len(earlier),
            "generated_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"), "metrics": compare(now, was)}
    week["line"] = line_of(week)
    return week


def markdown(week):
    def num(v):
        return "-" if v is None else f"{v:,.4g}" if abs(v) < 1000 else f"{v:,.0f}"

    def change(c):
        if c["delta"] is None:
            return "-"
        return f"{c['delta']:+,.4g}" + (f" ({c['pct']:+.0f}%)" if c["pct"] is not None else "")

    out = [f"# What moved, {week['start']} to {week['end']}", "", week["line"], "",
           f"Against {week['prev_start']} to {week['prev_end']} ({week['prev_days_present']} of {WINDOW} days). "
           "A change shows only when both weeks read the metric on as many days.", "",
           "| Metric | This week | Last week | Change |", "|---|---|---|---|"]
    out += [f"| {name} | {num(c['value'])} | {num(c['prev'])} | {change(c)} |" for name, c in week["metrics"].items()]
    return "\n".join(out)


def week(a):
    newest = sorted(WEEKS.glob("????-??-??.json"))
    path = WEEKS / f"{a.date}.json" if a.date else (newest[-1] if newest else None)
    data = None if a.write else load(path) if path else None
    if data is None:
        now = dt.date.fromtimestamp(float(ENV.get("DAYLOG_NOW") or time.time()))
        data = compute(a.date or now - dt.timedelta(days=1))
    if a.write:
        WEEKS.mkdir(parents=True, exist_ok=True)
        path = WEEKS / f"{data['end']}.json"
        tmp = path.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(data, indent=1) + "\n")
        tmp.replace(path)
        print(path)
    elif a.line:
        print(data["line"])
    elif a.json:
        print(json.dumps(data, indent=1))
    else:
        print(markdown(data))
    return 0


def main():
    ap = argparse.ArgumentParser(prog="day-log-snapshots", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="verb", required=True)
    e = sub.add_parser("enrich")
    e.add_argument("--start", type=int, required=True)
    e.add_argument("--end", type=int, required=True)
    e.add_argument("--prev")
    e.add_argument("--ci-file")
    c = sub.add_parser("ci")
    c.add_argument("--day", required=True)
    w = sub.add_parser("week")
    w.add_argument("--date", type=dt.date.fromisoformat)
    w.add_argument("--write", action="store_true", help="recompute and store it, for `day-log nightly`")
    w.add_argument("--json", action="store_true")
    w.add_argument("--line", action="store_true")
    a = ap.parse_args()
    return {"enrich": enrich, "ci": ci, "week": week}[a.verb](a)


if __name__ == "__main__":
    sys.exit(main())
