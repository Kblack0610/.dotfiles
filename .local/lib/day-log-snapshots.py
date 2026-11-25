#!/usr/bin/env python3
"""day-log-snapshots: the work, agents and ci sections of a day-log record, and the week.

  enrich --start S --end E [--prev FILE] [--ci-file FILE]   a record on stdin, the sections added
  ci --day D                                                a finished day's CI, slow: see below
  week [--date D] [--write] [--json | --line]               7 finished days against the 7 before
  agents --date D                                           the by-agent tally of the 7 days ending D, JSON

day-log runs this: it owns the record, and every env var read here is set and exported there.
No counter of its own: each number comes from the tool that owns it, so this file only joins
them, and a source it cannot read keeps the previous value and is named in .unreadable.
  agent-queue stats --json   queue flow per local day
  fleet-bench flow --json    plan phases
  fleet-sessions stages      time per delivery stage and reason, from the shepherd's watch.log
  ~/.notes history           board rows and points opened, done, dropped, by project
                             (`notes board --weigh` weighs each commit's rows)
  agent-usage tokens json    tokens, cost, sessions by kind and account (the nightly snapshot)
  outcomes/*.jsonl           sessions with no PR, time use (the nightly session-outcomes)
  agentctl runs.jsonl        last night's runner passes, priced from calls.jsonl, scored by
                             judge-eval --all --json (each lane's score_7d, as the Workers cell)
  ci-failures --json         pass rate per workflow, reds on main, failure buckets
  scripts/ci/ci-cost.py --json  gates, runner-hours, re-gates, quarantine (a repo that has one)
  hub ci hosts               each runner group's pass over its last 50 jobs, from the job archive (a week idle: left out)
  agent-queue list --json    who did what: each merged PR's author and reviewer, each closed trainee
                             row's outcome, and the per-agent tally (work.by_agent)

ci lists runs from the schedules-sync run ledger, but reads each red run's jobs, annotations and
logs from GitHub, a few hundred calls and minutes for a busy repo, so only `day-log nightly` runs
it, outside the record's lock; enrich keeps what it found.

week: a sum adds the days, a ratio is taken from those sums, a p50 or p90 is the median of the
daily values (a record keeps percentiles, not samples), a gauge is its last value, and cost is
and sessions are read over the whole window, because a session spans days.
A delta needs as many days with the metric in both weeks: fewer would read as a drop.
"""
import argparse
import datetime as dt
import io
import json
import os
import re
import shlex
import shutil
import statistics
import subprocess
import sys
import tarfile
import tempfile
import time
from pathlib import Path

ENV = os.environ
DIR = Path(ENV["DAYLOG_DIR"])
WEEKS = DIR / "weeks"
WINDOW = 7
CALL_TIMEOUT = 3600   # a guard, so a hung read fails its section instead of stalling the nightly
# The agent sheets and the version notes a release cut rolls their closed rows into.
SHEETS = ("*/projects/current/*/agent/README.md", "*/projects/current/*/agent/versions/*.md")


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


def local_epoch(date, time=dt.time()):
    return int(dt.datetime.combine(date, time).astimezone().timestamp())


def day_bounds(day):
    """(start, end) epochs of a local calendar day, YYYY-MM-DD: 23 or 25 hours when the clocks move."""
    date = dt.date.fromisoformat(day)
    return local_epoch(date), local_epoch(date + dt.timedelta(days=1))


# --- the day ---------------------------------------------------------------

def queue_flow(day):
    since = (dt.date.fromisoformat(day) - dt.timedelta(days=1)).isoformat()  # done/ is dated in UTC
    stats, err = run_json(cmd("DAYLOG_QUEUE_CMD") + ["stats", "--json", "--flow", "--since", since])
    return (stats.get("flow", {}).get(day) or {}, None) if stats else (None, err)


def notes_git(*args):
    return subprocess.run(["git", "-C", ENV["DAYLOG_NOTES_DIR"], *args],
                          capture_output=True, text=True)


def rows_at(epoch):
    """{row id: {project, id, state, weight}} on the agent sheets at that time, weighed by notes
    (`notes board --weigh`), so the points rule and the done/dropped split have one home.
    Compared across all sheets at once, so a row moved between sheets counts as neither opened
    nor closed. A row with no id is not counted."""
    when = dt.datetime.fromtimestamp(epoch, dt.timezone.utc).isoformat()
    commit = notes_git("rev-list", "-1", f"--before={when}", "HEAD")
    if commit.returncode:
        raise OSError(commit.stderr.strip() or "no notes history")
    head = commit.stdout.strip()
    if not head:
        return {}
    found = notes_git("grep", "-E", "<!-- id:", head, "--", *SHEETS)
    if found.returncode > 1:
        raise OSError(found.stderr.strip())
    try:
        weighed = subprocess.run(cmd("DAYLOG_NOTES_CMD") + ["board", "--weigh"], input=found.stdout,
                                 capture_output=True, text=True, timeout=CALL_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise OSError(str(e)) from e
    if weighed.returncode:
        raise OSError((weighed.stderr.strip().splitlines() or [f"notes board --weigh: exit {weighed.returncode}"])[-1])
    try:
        rows = [json.loads(line) for line in weighed.stdout.splitlines()]
    except ValueError as e:
        raise OSError("notes board --weigh: not JSON lines") from e
    # One id on a sheet and a version note at once (mid-roll): the closed record wins, whatever the grep order.
    by_id = {}
    for r in rows:
        if by_id.get(r["id"], {}).get("state", "open") == "open":
            by_id[r["id"]] = r
    return by_id


def flow_of(opened, left, now):
    """The board fields of one scope: rows and points opened, done, dropped and open at the end.
    closed is done plus dropped, the sum the week line and older records read."""
    pts = lambda rows: sum(r["weight"] for r in rows)
    done = [r for r in left if r["state"] == "done"]
    dropped = [r for r in left if r["state"] != "done"]
    still = [r for r in now if r["state"] == "open"]
    return {"opened": len(opened), "closed": len(left), "done": len(done), "dropped": len(dropped),
            "open_end": len(still), "opened_pts": pts(opened), "done_pts": pts(done),
            "dropped_pts": pts(dropped), "open_pts": pts(still)}


def board_flow(start, end):
    """The day's agent board: rows and points opened, done (closed delivered), dropped (closed
    undelivered, or gone from every sheet while open) and open at the end, in total and by project.
    Done is the burn; a cleanup lands in dropped, so it never reads as work done."""
    try:
        was, now = rows_at(start), rows_at(end)
    except OSError as e:
        return None, str(e)
    if not was:  # rows have had ids since 2026-11-04: before that there is nothing to join on
        still = [r for r in now.values() if r["state"] == "open"]
        unknown = dict.fromkeys(("opened", "closed", "done", "dropped", "opened_pts", "done_pts", "dropped_pts"))
        return {**unknown, "open_end": len(still) if now else None,
                "open_pts": sum(r["weight"] for r in still) if now else None}, None
    opened = [r for i, r in now.items() if i not in was]
    # A row leaves the open board by closing today (open at the start, or opened today) or by
    # leaving every sheet while open, which is a drop whatever it weighed.
    left = ([r for i, r in now.items() if r["state"] != "open" and was.get(i, {"state": "open"})["state"] == "open"]
            + [{**r, "state": "dropped"} for i, r in was.items() if i not in now and r["state"] == "open"])
    flow = flow_of(opened, left, list(now.values()))
    names = sorted({r["project"] for r in [*opened, *left, *now.values()]})
    by = [{"project": n, **flow_of([r for r in opened if r["project"] == n], [r for r in left if r["project"] == n],
                                   [r for r in now.values() if r["project"] == n])} for n in names]
    by = [b for b in by if b["open_end"] or b["opened"] or b["closed"]]
    return {**flow, "by_project": sorted(by, key=lambda b: (-b["open_pts"], b["project"]))}, None


def phase_flow(start, end):
    flow, err = run_json(cmd("DAYLOG_BENCH_CMD") + ["flow", "--from", str(start), "--to", str(end), "--json"])
    if not flow:
        return None, err
    return {k: flow.get(k) for k in ("ticked", "added", "removed", "started")}, None


def stage_flow(start, end):
    return run_json(cmd("DAYLOG_FLEET_CMD") + ["stages", "--from", str(start), "--to", str(end), "--json"])


def merges(record):
    by_repo, by_area = {}, {}
    for pr in record.get("merged") or []:
        by_repo[pr["repo"]] = by_repo.get(pr["repo"], 0) + 1
        by_area[pr["area"]] = by_area.get(pr["area"], 0) + 1
    return {"by_repo": by_repo, "by_area": by_area}


# --- who did what ----------------------------------------------------------

AGENT_COLS = ("merged", "waiting_review", "sent_back", "failed")
NO_ITEM = "no item"   # a PR no queue item carries has no author to credit
UNKNOWN = "unknown"   # an item that carries a PR but records no agent


def run_lines(argv):
    """(the objects of a JSON-lines stdout, error text); one of the two is None."""
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=CALL_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as e:
        return None, str(e)
    if p.returncode != 0:
        return None, (p.stderr.strip().splitlines() or [f"exit {p.returncode}"])[-1]
    try:
        return [json.loads(line) for line in p.stdout.splitlines() if line.strip()], None
    except ValueError:
        return None, "output is not JSON"


def agent_label(item):
    """harness:model of the run an item records, the harness alone while it has no model."""
    agent, model = item.get("agent") or "", item.get("model") or ""
    return (f"{agent}:{model}" if agent and model else agent) or None


def iso_epoch(text):
    try:
        return dt.datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()
    except (AttributeError, ValueError):
        return None


def trainee_authored(item):
    """The diff is the trainee's: its item still names the trainee's harness (a batch review lands or
    sends it back), or a lander session carries the trainee's PR. A row sent back is Claude's now."""
    pair = item.get("trainee") or ""
    ran_it = agent_label(item) == pair or (not item.get("model") and item.get("agent") == pair.split(":")[0])
    return bool(pair) and (ran_it or bool(item.get("pr_owner")))


def is_batch(item):
    return "trainee-batch" in (item.get("tags") or "").split()


def reviewers_of(items):
    """{trainee row slug: the batch review item's harness:model}, the newest batch naming it winning."""
    out = {}
    for batch in sorted(filter(is_batch, items), key=lambda i: i.get("queued") or ""):
        for slug in re.findall(r"^## Queue item (\S+)", batch.get("task") or "", re.M):
            out[slug] = agent_label(batch)
    return out


def reviewer_of(item, reviewers):
    return agent_label(item) if item.get("pr_owner") else reviewers.get(item["slug"])


def trainee_outcome(item, start, end, live):
    """What became of a trainee row, when it counts on this day: waiting for its review (live only, a
    row waits now), or closed in the window as merged, sent back to Claude, or failed."""
    if item.get("state") == "review":   # a row Claude is redoing waits on no one's review but its own
        return "waiting_review" if live and trainee_authored(item) else None
    finished = iso_epoch(item.get("finished"))
    if item.get("state") != "done" or finished is None or not start <= finished < end:
        return None
    if not trainee_authored(item):
        return "sent_back"
    if item.get("status") == "failed":
        return "failed"
    return "merged" if item.get("status") == "ok" and (item.get("pr") or item.get("merged")) else None


def trainee_rows(items, reviewers, start, end, live):
    rows = []
    for item in items:
        if not item.get("trainee") or is_batch(item):
            continue
        outcome = trainee_outcome(item, start, end, live)
        if outcome is None:
            continue
        reviewed = trainee_authored(item) and outcome in ("merged", "waiting_review")
        rows.append({"slug": item["slug"], "row": (item.get("row") or item["slug"]).split(":")[-1], "author": item["trainee"],
                     "outcome": outcome, "pr": item.get("pr") or None, "finished": item.get("finished") or None,
                     "reviewer": reviewer_of(item, reviewers) if reviewed else None, "why": item.get("end_reason") or None})
    return sorted(rows, key=lambda r: (r["finished"] or "~", r["slug"]))


def by_agent(record):
    out = {}
    cell = lambda who: out.setdefault(who or NO_ITEM, dict.fromkeys(AGENT_COLS, 0))
    for pr in record.get("merged") or []:
        cell(pr.get("author") or (UNKNOWN if pr.get("by") else None))["merged"] += 1
    for row in record.get("trainee") or []:
        if row["outcome"] != "merged":   # a merged row is its PR, already counted
            cell(row["author"])[row["outcome"]] += 1
    return out


def credit(record, prev, start, end, live):
    """Annotate merged[] with author and reviewer and set trainee[]; returns work.by_agent. The queue
    item that carries a PR (merged[].by) names its author: the trainee's pair for a diff a batch review
    or a lander landed, else the harness:model of the item's own run."""
    items, err = run_lines(cmd("DAYLOG_QUEUE_CMD") + ["list", "--json", "--state", "all", "--since", record["date"]])
    if items is None:
        return None, err
    by_slug, reviewers = {i["slug"]: i for i in items if i.get("slug")}, reviewers_of(items)
    for pr in record.get("merged") or []:
        item = by_slug.get(pr.get("by"))
        mine = item is not None and trainee_authored(item)
        pr["author"] = (item["trainee"] if mine else agent_label(item)) if item else None
        pr["reviewer"] = reviewer_of(item, reviewers) if mine else None
    rows = trainee_rows(items, reviewers, start, end, live)
    # a past day keeps the rows it last saw waiting: nothing is queried for a day that is over
    closed = {r["slug"] for r in rows}
    record["trainee"] = rows if live else rows + [r for r in prev.get("trainee") or []
                                                  if r["outcome"] == "waiting_review" and r["slug"] not in closed]
    return by_agent(record), None


def keep_credits(record, prev):
    """The queue could not be read: the PRs and rows the last record held keep their credits."""
    held = {(m["repo"], m["number"]): m for m in prev.get("merged") or []}
    for pr in record.get("merged") or []:
        old = held.get((pr["repo"], pr["number"])) or {}
        pr["author"], pr["reviewer"] = old.get("author"), old.get("reviewer")
    record["trainee"] = prev.get("trainee")


def agents(a):
    """The by-agent tally of the 7 days ending a.date: merged, sent back and failed add up, and a row
    waiting for review is a gauge (the same row waits on every day), so it is the day's own."""
    out, waiting = {}, {}
    for day in day_list(a.date, 0):
        tally = get(load(DIR / f"{day}.json") or {}, "work.by_agent")
        if tally is None:
            continue
        if day == a.date.isoformat():
            waiting = {who: cols.get("waiting_review", 0) for who, cols in tally.items()}
        for who, cols in tally.items():
            cell = out.setdefault(who, dict.fromkeys(AGENT_COLS, 0))
            for col in ("merged", "sent_back", "failed"):
                cell[col] += cols.get(col, 0)
    for who, cell in out.items():
        cell["waiting_review"] = waiting.get(who, 0)
    print(json.dumps(out))
    return 0


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
    faults = lambda r: sum(n or 0 for n in (r.get("hard_errors") or {}).values())
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


NIGHT = (dt.time(20), dt.time(7))   # the night a runner rollup covers, local: the day before to the day


def night_bounds(day):
    """(start, end) epochs of the night that ends on a local day's morning."""
    date = dt.date.fromisoformat(day)
    return local_epoch(date - dt.timedelta(days=1), NIGHT[0]), local_epoch(date, NIGHT[1])


def conf_keys(path):
    """A runner conf's KEY=value lines, quotes stripped; the conf is the one home of EFFECT and CALLER."""
    keys = {}
    for line in path.read_text().splitlines():
        m = re.match(r"^([A-Z_]+)=(.*)$", line.strip())
        if m:
            keys[m[1]] = m[2].strip().strip("'\"")
    return keys


def jsonl(path):
    """A log's rows; a missing log is empty, as on a fresh install."""
    if not Path(path).exists():
        return []
    with open(path) as f:
        return [json.loads(line) for line in f if line.strip()]


def runners(day):
    """Every agentctl runner pass that started in the night before the day, in time order: its
    verdict from runs.jsonl, its cost from the calls it or a call it makes (CALLER) logged while
    it ran, its conf's EFFECT, and its lane's judge-eval score."""
    start, end = night_bounds(day)
    runs = [r for r in jsonl(ENV["DAYLOG_RUNS"]) if isinstance(r.get("started"), int) and start <= r["started"] < end]
    confs = {p.stem: conf_keys(p) for p in Path(ENV["DAYLOG_AGENTS_DIR"]).glob("*.conf")}
    calls = []
    for c in jsonl(ENV["DAYLOG_CALLS"]):
        c["epoch"] = dt.datetime.fromisoformat(c.get("at") or "1970-01-01T00:00:00+00:00").timestamp()
        if start <= c["epoch"]:
            calls.append(c)
    judged, _ = run_json(cmd("DAYLOG_JUDGE_CMD") + ["--all", "--json"])
    # An unreadable judge-eval is "?" on every row, not "-": "-" says the lane has no score.
    score = {a["agent"]: (a.get("score_7d") or {}).get("text") for a in (judged or {}).get("agents", [])}
    unscored = "-" if judged else "?"
    passes = []
    for r in sorted(runs, key=lambda r: r["started"]):
        name, fin = r.get("name", ""), r.get("finished") or r["started"]
        mine = [c.get("cost_usd") or 0 for c in calls if r["started"] <= c["epoch"] <= fin
                and name in (c.get("agent"), confs.get(c.get("agent"), {}).get("CALLER"))]
        passes.append({"at": r["started"], "name": name,
                       "verdict": r.get("outcome") or ("-" if r.get("result") in ("success", None) else "FAILED"),
                       "cost_usd": round(sum(mine), 4) if mine else None,
                       "effect": confs.get(name, {}).get("EFFECT"), "score": score.get(name) or unscored})
    return {"from": start, "to": end, "passes": passes}, None


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
                      "phases": read("fleet-bench flow", "work.phases", lambda: phase_flow(a.start, a.end)),
                      "stages": read("fleet-sessions stages", "work.stages", lambda: stage_flow(a.start, a.end))}
    try:
        tally, err = credit(record, prev, a.start, a.end, live)
    except Exception as e:   # like read(): a fault here costs this section, never the snapshot
        tally, err = None, repr(e)
    if tally is None:   # the same read as the ledger day-log named: only a fault of its own is added
        if "queue ledger" not in bad:
            bad.append(f"queue credits: {err}")
        keep_credits(record, prev)
        tally = by_agent(record) if get(prev, "work.by_agent") is not None else None
    record["work"]["by_agent"] = tally
    record["agents"] = {
        **usage_of(snap),
        # Today has no outcomes yet, and a past day has no live asks: it keeps its last gather's.
        "outcomes": None if live else read("outcomes", "agents.outcomes", lambda: (outcomes(a.start, a.end), None)),
        "asks": read("asks", "agents.asks", lambda: (ask_ages(record["waiting"]["asks"], now), None))
        if live and record.get("waiting") else get(prev, "agents.asks"),
        "runners": read("runners", "agents.runners", lambda: runners(day)),
    }
    record["ci"] = load(a.ci_file) if a.ci_file else prev.get("ci")
    bad.extend(f"ci {name}" for name in get(record, "ci.unreadable") or [])
    json.dump(record, sys.stdout)
    print()
    return 0


# --- CI, a finished day ----------------------------------------------------

def ci_repos():
    """[(owner/name, base branch, clone or None)] of the GitHub repos `schedules-sync repos`
    lists. A forgejo repo is left out: ci-failures reads a red run's jobs and logs from GitHub,
    and ci-cost reads GitHub; its runs are in the schedules-sync ledger all the same. A prs-only
    repo is left out too: only the PR store reads it. OSError when the list is unreadable."""
    got, err = run_json(shlex.split(ENV.get("SCHEDULES_SYNC", "schedules-sync")) + ["repos"])
    if got is None:
        raise OSError(err)
    return [(r["repo"], r["base"], r.get("clone")) for r in got if r.get("forge") == "github"]


def stamp(epoch):
    return dt.datetime.fromtimestamp(epoch, dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def window_args(start, end):
    return ["--days", f"{(end - start) / 86400:.6f}", "--until", stamp(end), "--json"]


def ci_failures(repo, base, start, end):
    reader = ENV.get("DAYLOG_CI_FAILURES_CMD", "python3 " + str(Path.home() / ".claude/skills/ci-cleanup/ci-failures.py"))
    got, err = run_json(shlex.split(reader) + ["--repo", repo, "--base", base] + window_args(start, end), ok=(0, 3))  # 3: partial
    if got is None:
        return None, err
    return {"runs": got.get("runs"), "red": got.get("red_runs"), "pending": got.get("pending_runs"),
            "cancelled": got.get("cancelled"), "partial": got.get("partial"), "partial_why": got.get("partial_why"),
            "buckets": got.get("buckets")}, None


def ci_pass(start, end, branch=None):
    """({forge:repo: {runs, green, pass, workflows}}, error) from `hub ci pass`: the one pass rate
    (hub_core::builds::verdict) of the run ledger's runs created in the day, on `branch` when given.
    Repo keys are lowered: the ledger may spell a repo in another case."""
    got, err = run_json(cmd("DAYLOG_HUB_CMD") + ["ci", "pass", "--since", str(start), "--until", str(end)]
                        + (["--branch", branch] if branch else []))
    return (None if got is None else {k.lower(): v for k, v in got.items()}), err


HOST_JOBS = 50   # a runner group's pass is over its last 50 jobs, so a quiet host is judged as a busy one
HOST_IDLE_DAYS = 7  # a group with no job in the week before the day ended is a retired host, not a quiet one


def ci_hosts(end):
    """({runner group: {runs, green, pass}}, error) from `hub ci hosts`: the same verdict over each
    runner group's last HOST_JOBS jobs that completed before the day ended, from the job archive,
    leaving out a group with no job in the HOST_IDLE_DAYS before it (a host the fleet retired)."""
    return run_json(cmd("DAYLOG_HUB_CMD") + ["ci", "hosts", "--since", str(end - HOST_IDLE_DAYS * 86400),
                                            "--until", str(end), "--last", str(HOST_JOBS)])


def ci_cost(clone, base, day, start, end):
    """scripts/ci/ci-cost.py as the base branch has it, so a stale checkout never measures. It runs from that
    branch's whole scripts/ tree, because it loads files beside it (test/train.py). The cache only serves a
    retry of the same day, so a finished read removes it."""
    subprocess.run(["git", "-C", clone, "fetch", "-q", "origin", base], capture_output=True)
    tree = subprocess.run(["git", "-C", clone, "archive", f"origin/{base}", "scripts"], capture_output=True)
    if tree.returncode:
        return None, tree.stderr.decode(errors="replace").strip() or f"no scripts/ on origin/{base}"
    cache = Path(ENV.get("DAYLOG_CI_CACHE", Path.home() / ".cache" / "day-log" / "ci-cost")) / day
    with tempfile.TemporaryDirectory() as tmp:
        try:
            with tarfile.open(fileobj=io.BytesIO(tree.stdout)) as t:
                t.extractall(tmp, filter="data")
        except (tarfile.TarError, OSError) as e:
            return None, f"scripts/ on origin/{base}: {e}"
        script = Path(tmp) / "scripts" / "ci" / "ci-cost.py"
        if not script.is_file():
            return None, f"no scripts/ci/ci-cost.py on origin/{base}"
        got, err = run_json([sys.executable, str(script), *window_args(start, end), "--cache", str(cache), "--repo-dir", clone])
    if got is not None:
        shutil.rmtree(cache, ignore_errors=True)
    return got, err


def ci(a):
    out = {"gathered_at": dt.datetime.now().astimezone().isoformat(timespec="seconds"), "repos": {}, "unreadable": []}
    try:
        repos = ci_repos()
    except OSError as e:
        out["unreadable"].append(f"schedules-sync repos: {e}")
        repos = []
    start, end = day_bounds(a.day)
    passes, err = ci_pass(start, end) if repos else ({}, None)
    if passes is None:
        out["unreadable"].append(f"hub ci pass: {err}")  # the rows go without a pass, never a zero one
    out["hosts"], err = ci_hosts(end)  # with no repos too: the job archive is every repo's
    if out["hosts"] is None:
        out["unreadable"].append(f"hub ci hosts: {err}")
    # main: the base branch's runs and its reds (runs that counted, less the green), one read per base
    on_base = dict.fromkeys(b for _, b, _ in repos)
    for base in on_base if passes is not None else ():  # a hub that failed once is named once
        on_base[base], err = ci_pass(start, end, base)
        if on_base[base] is None:
            out["unreadable"].append(f"hub ci pass --branch {base}: {err}")
    for repo, base, clone in repos:
        row, err = ci_failures(repo, base, start, end)
        if row is None:
            out["unreadable"].append(f"{repo} ci-failures: {err}")
            row = {}
        elif row["partial"]:
            # the read that failed, so a partial night can be told apart from the next one
            out["unreadable"].append(f"{repo} ci-failures: partial" + (f": {row['partial_why']}" if row["partial_why"] else ""))
        none = {"runs": 0, "green": 0, "pass": None}  # a repo with no run that day is absent: 0 runs
        if passes is not None:
            got = passes.get(f"github:{repo}".lower(), none)
            row["pass"] = {k: got[k] for k in ("runs", "green", "pass")}
            row["workflows"] = got.get("workflows", {})
        if on_base[base] is not None:
            got = on_base[base].get(f"github:{repo}".lower(), none)
            row["main"] = {"runs": got["runs"], "red": got["runs"] - got["green"]}
        if clone:
            row["cost"], err = ci_cost(clone, base, a.day, start, end)
            if row["cost"] is None:
                out["unreadable"].append(f"{repo} ci-cost: {err}")
        out["repos"][repo] = row
    json.dump(out, sys.stdout)
    print()
    # stdout is the record; stderr is the runner's log, so a failed nightly says why there too.
    for reason in out["unreadable"]:
        print("day-log-snapshots: ci:", " ".join(reason.split()), file=sys.stderr)
    return 1 if out["unreadable"] else 0


# --- the week --------------------------------------------------------------

SUM = {"queue.queued": "work.queue.queued", "queue.started": "work.queue.started", "queue.waiting": "work.queue.waiting",
       "queue.done": "work.queue.done", "queue.failed": "work.queue.failed", "board.opened": "work.board.opened",
       "board.closed": "work.board.closed", "board.done": "work.board.done", "board.dropped": "work.board.dropped",
       "board.opened_pts": "work.board.opened_pts", "board.done_pts": "work.board.done_pts",
       "board.dropped_pts": "work.board.dropped_pts", "phases.ticked": "work.phases.ticked", "tokens.context": "agents.tokens.context",
       "merged_prs": "agents.merged_prs", "cost_usd": "agents.cost_usd", "stages.needs_min": "work.stages.stages.NEEDS.minutes",
       "stages.ask_min": "work.stages.stages.NEEDS:ask.minutes", "stages.prompt_min": "work.stages.stages.NEEDS:prompt.minutes",
       "stages.plan_approval_min": "work.stages.stages.NEEDS:plan_approval.minutes",
       "stages.stalled_min": "work.stages.stages.STALLED.minutes", "stages.ci_rerun_after_red": "work.stages.ci.rerun_after_red",
       "stages.conflicts": "work.stages.conflicts.entered", "stages.phases_unticked": "work.stages.plans.phases_unticked",
       "stages.ended_no_pr": "work.stages.ended_no_pr"}
MEDIAN = {"queue.lead_p50_min": "work.queue.lead_minutes.p50", "queue.lead_p90_min": "work.queue.lead_minutes.p90",
          "queue.wait_p50_min": "work.queue.wait_minutes.p50", "queue.wait_p90_min": "work.queue.wait_minutes.p90",
          "stages.pr_to_merge_p50_min": "work.stages.prs.open_to_merged.p50"}
LAST = {"board.open": "work.board.open_end", "board.open_pts": "work.board.open_pts", "asks.open": "agents.asks.open", "asks.age_h_max": "agents.asks.age_h_max"}
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
    for who in sorted({k for r in records for k in get(r, "work.by_agent") or {}}):
        for col in AGENT_COLS:
            fold(f"agent.{who}.{col}", [None if get(r, "work.by_agent") is None else get(r, "work.by_agent").get(who, {}).get(col, 0)
                                        for r in records], last if col == "waiting_review" else sum)
    fold_tables(TABLES, records)
    for repo in sorted({k for r in records for k in (get(r, "ci.repos") or {})}):
        short = repo.split("/")[-1].lstrip(".")
        rows = [(get(r, "ci.repos") or {}).get(repo) or {} for r in records]
        fold_tables(CI_TABLES, rows, f"ci.{short}.")
        # The pass rate over the week is green over runs summed, never a mean of daily rates. A day
        # gathered before hub ci pass has no green, so it is left out.
        def fold_pass(name, cells):
            cells = [c for c in cells if c and "green" in c]
            if cells:
                out[name] = (share(sum(c["green"] for c in cells), sum(c["runs"] for c in cells)), len(cells))

        fold_pass(f"ci.{short}.pass", [row.get("pass") for row in rows])
        for wf in sorted({w for row in rows for w in row.get("workflows") or {}}):
            fold_pass(f"ci.{short}.pass.{wf}", [(row.get("workflows") or {}).get(wf) for row in rows])
    return out


def window_sessions(start, end):
    """Sessions over the window from the registry: a session counts once however many days it ran."""
    try:
        out = subprocess.run(cmd("DAYLOG_USAGE_CMD") + ["rollup", "--since", str(start), "--until", str(end)],
                             capture_output=True, text=True, timeout=CALL_TIMEOUT).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    rows = [line.split("\t") for line in out.splitlines() if line.count("\t") >= 4]
    total = [r for r in rows if r[0] == "TOTAL"] or rows
    return sum(int(r[1]) for r in total) if total else None


def side(span):
    """(records, metrics) of one week. Sessions are read over the window, never added up from the
    days, because a session spans days. Cost is the days' fleet cost summed (SUM): each day's is
    that day's spend alone, so the days add up."""
    records = [r for r in (load(DIR / f"{d}.json") for d in span) if r]
    out = rollup(records)
    if not records:
        return records, out
    start, end = day_bounds(span[0])[0], day_bounds(span[-1])[1]
    sessions = window_sessions(start, end)
    if sessions is not None:
        out["sessions.total"] = (sessions, WINDOW)
    prs, prs_days = out.get("merged_prs", (0, 0))
    cost, cost_days = out.get("cost_usd", (None, 0))
    if prs and prs_days == cost_days == WINDOW:  # the PRs burn counts per day, so it reads like the daily number
        out["cost_per_merged_pr"] = (round(cost / prs, 2), WINDOW)
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
    if cell("board.opened")["value"] is not None and cell("board.done")["value"] is not None:
        v = lambda k: f"{cell(k)['value']:g}"
        parts.append(f"board +{v('board.opened')} ({v('board.opened_pts')} pts), {v('board.done')} done ({v('board.done_pts')} pts),"
                     f" {v('board.dropped')} dropped ({v('board.dropped_pts')} pts)")
    elif cell("board.opened")["value"] is not None and cell("board.closed")["value"] is not None:
        parts.append(f"board +{cell('board.opened')['value']:g}/-{cell('board.closed')['value']:g}")
    if cell("cost_usd")["value"] is not None:
        parts.append(f"{usd(cell('cost_usd')['value'])}{signed(cell('cost_usd')['delta'], usd)}")
    for name in sorted(k for k in m if re.fullmatch(r"ci\.[^.]+\.pass", k) and m[k]["value"] is not None):
        pts = lambda v: f"{100 * v:.0f} pts"
        parts.append(f"{name.split('.')[1]} pass {100 * m[name]['value']:.0f}%{signed(m[name]['delta'], pts)}")
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
    g = sub.add_parser("agents")
    g.add_argument("--date", type=dt.date.fromisoformat, required=True)
    w = sub.add_parser("week")
    w.add_argument("--date", type=dt.date.fromisoformat)
    w.add_argument("--write", action="store_true", help="recompute and store it, for `day-log nightly`")
    w.add_argument("--json", action="store_true")
    w.add_argument("--line", action="store_true")
    a = ap.parse_args()
    return {"enrich": enrich, "ci": ci, "week": week, "agents": agents}[a.verb](a)


if __name__ == "__main__":
    sys.exit(main())
