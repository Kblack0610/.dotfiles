#!/usr/bin/env python3
"""fleet-stages: time per delivery stage over a window, read from the shepherd's watch.log.

  fleet-stages.py [--log FILE] [--from EPOCH] [--to EPOCH] [--json]

`fleet-sessions stages` runs this; `fleet-sessions tick` writes the log (one line per session
per minute in which something moved: "YYYY-MM-DD HH:MM  <session>  <field a -> b>, ...", a stage
change ending in "(<reason>)", plus "new: <STAGE> (<reason>)" and "gone"). The whole log is
replayed so a stage entered before the window is known; then:

  minutes spent in a stage are clipped to the window;
  an episode (a stage, a CI run, a PR, a conflict) is counted, with its full length, in the
  window it ENDS in; one still open at --to is counted under `open`;
  a session's lifetime is new..gone, so a reused tmux window starts clean.

No model, no gh: a minute the timer did not tick (an outage) reads as the stage carrying on.
"""
import argparse
import functools
import json
import math
import re
import statistics
import sys
import time
from datetime import datetime
from pathlib import Path

LINE = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d)  (\S+)  (.*)$")
STAGE = re.compile(r"stage ([A-Z]+) -> ([A-Z]+)(?:,.*?)?(?: \((.*)\))?$")
FIELDS = "sync|conflicts|tree|pr|ci|plan|quality|labels"
FIELD = re.compile(rf"({FIELDS}) (.+?) -> (.*?)(?=, (?:{FIELDS}|stage) |$| \()")
PLAN = re.compile(r"^(\d+)/(\d+)$")
PR = re.compile(r"^#(\d+) (open|merged)$")
# Why a session waits, first match wins: the reasons fleet-sessions writes (fleet_stages.bats pins each one),
# grouped by what clears them. A retired wording stays while watch.log still holds it.
NEEDS = (("plan_approval", ("plan awaiting approval",)), ("ask", ("pending ask",)),
         ("question", ("question to the human",)), ("prompt", ("prompt or permission",)))
STALLED = (("main_red", ("nightly red after", "main red after")), ("merged_dirty", ("merged, ",)),
           ("after_merge", ("commits after merged PR",)), ("ci_red", ("CI red",)),
           ("green_unmerged", ("green, not merged",)), ("conflict", ("conflicts with",)),
           ("ahead", ("not on the default branch",)), ("dirty", ("dirty file",)))
FINISHED = ("DONE", "LANDED")
FLICKER_MIN = 2   # a gone and a new of one window this close is one session the probe missed for a tick
AGENT_SUFFIX = re.compile(r"(-agent-\d+[\w-]*)?(:\d+)?$")


def project_of(name):
    """unity-core-playground-agent-10:1 -> unity-core-playground; dotfiles:3 -> "dotfiles (main)": a window in
    the repo's own tmux session is a hand session the human talks to, an agent worktree's is not, so a wait
    at the prompt means different things in each."""
    base = AGENT_SUFFIX.sub("", name) or name
    return base if "-agent-" in name else f"{base} (main)"


def classify(reason, table):
    return next((name for name, needles in table if any(n in (reason or "") for n in needles)), "other")


def pct(values):
    if not values:
        return {"n": 0, "p50": None, "p90": None}
    s = sorted(values)
    return {"n": len(s), "p50": round(statistics.median(s), 1), "p90": round(s[math.ceil(0.9 * len(s)) - 1], 1)}


EMPTY = {**pct([]), "open": 0}


class Window:
    def __init__(self, start, end):
        self.start, self.end = start, end
        self.minutes = {}          # stage -> minutes inside the window
        self.ended = {}            # (kind, key) -> [durations of episodes ending in the window]
        self.open = {}             # (kind, key) -> count still open at the end
        self.count = {}            # counter name -> n
        self.by_project = {}       # project -> {counter or "<stage>_min": n}

    def inside(self, t):
        return self.start <= t < self.end

    def span(self, stage, a, b, project):
        lo, hi = max(a, self.start), min(b, self.end)
        if hi > lo:
            self.minutes[stage] = self.minutes.get(stage, 0) + (hi - lo) / 60
            self.add(project, f"{stage.lower()}_min", (hi - lo) / 60)

    def episode(self, kind, key, a, b):
        if self.inside(b):
            self.ended.setdefault((kind, key), []).append((b - a) / 60)

    def still_open(self, kind, key, a):
        if a < self.end:
            self.open[(kind, key)] = self.open.get((kind, key), 0) + 1

    def bump(self, name, n=1, t=None):
        if t is None or self.inside(t):
            self.count[name] = self.count.get(name, 0) + n

    def add(self, project, name, n=1):
        counts = self.by_project.setdefault(project, {})
        counts[name] = counts.get(name, 0) + n


class Session:
    def __init__(self, name, t):
        self.project = project_of(name)
        self.born = t
        self.stage, self.since, self.reason = None, t, None
        self.ci, self.ci_since = None, t
        self.conflict_since = None
        self.prs = {}              # number -> opened at (None when first seen merged)
        self.had_pr = False
        self.last_tick = None
        self.finished_at = None    # when it last entered DONE or LANDED


def stage_key(stage, reason):
    if stage == "NEEDS":
        return f"NEEDS:{classify(reason, NEEDS)}"
    if stage == "STALLED":
        return f"STALLED:{classify(reason, STALLED)}"
    return stage


def close_stage(w, s, t):
    if s.stage:
        for key in {s.stage, stage_key(s.stage, s.reason)}:
            w.span(key, s.since, t, s.project)
            w.episode("stage", key, s.since, t)


def enter_stage(w, s, t, stage, reason):
    close_stage(w, s, t)
    s.stage, s.since, s.reason = stage, t, reason
    if stage not in FINISHED:
        s.finished_at = None
    elif s.finished_at is None:
        s.finished_at = t


def on_ci(w, s, t, old, new):
    if old == "pending" and new != "pending":
        w.episode("ci", new if new in ("pass", "fail") else "dropped", s.ci_since, t)
        if new in ("pass", "fail") and w.inside(t):
            w.add(s.project, f"ci_{new}")
    if new == "pending":
        if old == "fail":
            w.bump("ci_rerun_after_red", t=t)
        elif old == "pass":
            w.bump("ci_rerun_after_green", t=t)
        else:
            w.bump("ci_started", t=t)
    s.ci, s.ci_since = new, t


def on_pr(w, s, t, old, new):
    m = PR.match(new)
    if not m:
        return
    num, state = m.groups()
    s.had_pr = True
    if state == "open" and num not in s.prs:
        s.prs[num] = t
        w.bump("pr_opened", t=t)
    elif state == "merged":
        opened = s.prs.pop(num, None)
        w.bump("pr_merged", t=t)
        if w.inside(t):
            w.add(s.project, "prs_merged")
        if opened is not None:
            w.episode("pr", "open_to_merged", opened, t)


def on_plan(w, s, t, old, new):
    a, b = PLAN.match(old), PLAN.match(new)
    if not b:
        return
    done, total = int(b[1]), int(b[2])
    if not a:
        w.bump("plans_started", t=t)
        s.last_tick = t
        return
    was_done, was_total = int(a[1]), int(a[2])
    if done > was_done:
        w.bump("phases_ticked", done - was_done, t=t)
        if s.last_tick is not None:
            w.episode("phase", "minutes_per_tick", s.last_tick, t)
        s.last_tick = t
    elif done < was_done:
        w.bump("phases_unticked", was_done - done, t=t)
    if total > was_total:
        w.bump("phases_added", total - was_total, t=t)
    elif total < was_total:
        w.bump("phases_removed", was_total - total, t=t)


def on_conflict(w, s, t, old, new):
    if new == "CONFLICT" and s.conflict_since is None:
        s.conflict_since = t
        w.bump("conflicts", t=t)
    elif new != "CONFLICT" and s.conflict_since is not None:
        w.episode("conflict", "resolved" if new == "no" else "dropped", s.conflict_since, t)
        s.conflict_since = None


def gone(w, s, t):
    close_stage(w, s, t)
    if s.conflict_since is not None:
        w.episode("conflict", "dropped", s.conflict_since, t)
    if t >= w.start and s.born < w.end:
        w.bump("sessions")
    if not w.inside(t):
        return
    w.bump("sessions_ended")
    w.add(s.project, "ended")
    w.bump(f"sessions_ended_from_{(s.stage or 'unknown').lower()}")
    if not s.had_pr:
        w.bump("sessions_ended_no_pr")
        w.add(s.project, "ended_no_pr")
    if s.finished_at is not None:
        w.episode("wind_down", "finished_to_gone", s.finished_at, t)


HANDLERS = {"ci": on_ci, "pr": on_pr, "plan": on_plan, "conflicts": on_conflict}


@functools.lru_cache(maxsize=None)   # 25k lines share about 5k minute stamps, and strptime is most of a replay
def epoch(stamp):
    return int(datetime.strptime(stamp, "%Y-%m-%d %H:%M").astimezone().timestamp())


def replay(lines, w):
    sessions, pending = {}, {}   # pending: a gone not yet final, {name: (session, t)}

    def settle(now):
        for name, (s, t) in list(pending.items()):
            if now - t > FLICKER_MIN * 60:
                gone(w, s, t)
                del pending[name]

    for line in lines:
        m = LINE.match(line.rstrip("\n"))
        if not m:
            continue
        stamp, name, body = m.groups()
        t = epoch(stamp)
        if t >= w.end:
            break
        settle(t)
        if body.strip() == "gone":
            if name in sessions:
                pending[name] = (sessions.pop(name), t)
            continue
        if body.startswith("new: "):
            stage, _, reason = body[5:].partition(" (")
            if name in pending:      # the probe missed it for a tick: the same session
                s = sessions[name] = pending.pop(name)[0]
            else:
                if name in sessions:
                    gone(w, sessions[name], t)
                s = sessions[name] = Session(name, t)
                w.bump("sessions_started", t=t)
            enter_stage(w, s, t, stage.strip(), reason[:-1] if reason.endswith(")") else reason or None)
            continue
        s = sessions.get(name)
        if s is None:  # alive before the log began
            s = sessions[name] = Session(name, t)
        for field, old, new in FIELD.findall(body):
            handler = HANDLERS.get(field)
            if handler:
                handler(w, s, t, old, new)
        st = STAGE.search(body)
        if st:
            enter_stage(w, s, t, st[2], st[3])
    settle(float("inf"))
    for s in sessions.values():
        if s.born < w.end:
            w.bump("sessions")
        # Still open at --to: its minutes count, its episode has not ended (--to is outside [from, to)).
        close_stage(w, s, w.end)
        if s.stage:
            w.still_open("stage", stage_key(s.stage, s.reason), s.since)
        if s.ci == "pending":
            w.still_open("ci", "pending", s.ci_since)
        for opened in s.prs.values():
            w.still_open("pr", "open", opened)
        if s.conflict_since is not None:
            w.still_open("conflict", "open", s.conflict_since)


def report(w):
    def group(kind):
        keys = sorted({k for (kd, k) in list(w.ended) + list(w.open) if kd == kind})
        return {k: {**pct(w.ended.get((kind, k), [])), "open": w.open.get((kind, k), 0)} for k in keys}
    stages = group("stage")
    for stage, minutes in w.minutes.items():
        stages.setdefault(stage, dict(EMPTY))["minutes"] = round(minutes)
    c = w.count
    projects = {p: {k: round(v) for k, v in d.items()} for p, d in w.by_project.items()}
    return {"from": w.start, "to": w.end, "hours": round((w.end - w.start) / 3600, 1), "sessions": c.get("sessions", 0),
            "started": c.get("sessions_started", 0), "ended": c.get("sessions_ended", 0),
            "ended_no_pr": c.get("sessions_ended_no_pr", 0),
            "ended_from": {k[len("sessions_ended_from_"):]: v for k, v in sorted(c.items())
                           if k.startswith("sessions_ended_from_")},
            "stages": dict(sorted(stages.items())),
            "ci": {"started": c.get("ci_started", 0), "rerun_after_red": c.get("ci_rerun_after_red", 0),
                   "rerun_after_green": c.get("ci_rerun_after_green", 0), **group("ci")},
            "prs": {"opened": c.get("pr_opened", 0), "merged": c.get("pr_merged", 0), **group("pr")},
            "conflicts": {"entered": c.get("conflicts", 0), **group("conflict")},
            "plans": {k: c.get(k, 0) for k in ("plans_started", "phases_ticked", "phases_unticked",
                                                "phases_added", "phases_removed")} | group("phase"),
            "wind_down": group("wind_down").get("finished_to_gone", EMPTY),
            "by_project": dict(sorted(projects.items(), key=lambda kv: -kv[1].get("ended", 0)))}


def text(r):

    fmt = lambda d: " ".join(f"{k} {'-' if d.get(k) is None else d[k]:>6}" for k in ("n", "p50", "p90"))
    out = [f"stages {datetime.fromtimestamp(r['from']):%Y-%m-%d %H:%M} .. {datetime.fromtimestamp(r['to']):%Y-%m-%d %H:%M}"
           f" ({r['hours']}h): {r['sessions']} sessions, {r['started']} started, {r['ended']} ended"
           f" ({r['ended_no_pr']} with no PR seen)", "",
           f"  {'stage':<22} {'minutes':>8}  episodes ending in the window, minutes each"]
    out += [f"  {k:<22} {d.get('minutes', 0):>8}  {fmt(d)}  open {d['open']}" for k, d in r["stages"].items()]
    ci, pr, cf, pl = r["ci"], r["prs"], r["conflicts"], r["plans"]
    out += ["", f"ci: {ci['started']} started, {ci['rerun_after_red']} again after a red, {ci['rerun_after_green']} again after a green;"
            f" to pass {fmt(ci.get('pass', EMPTY))}; to fail {fmt(ci.get('fail', EMPTY))}",
            f"prs: {pr['opened']} opened, {pr['merged']} merged; open to merged {fmt(pr.get('open_to_merged', EMPTY))}",
            f"conflicts: {cf['entered']} entered; resolved {fmt(cf.get('resolved', EMPTY))}",
            f"plans: {pl['plans_started']} started, {pl['phases_ticked']} ticked, {pl['phases_unticked']} unticked,"
            f" {pl['phases_added']} added, {pl['phases_removed']} removed; minutes per tick {fmt(pl.get('minutes_per_tick', EMPTY))}",
            f"wind-down, finished to gone: {fmt(r['wind_down'])}; ended from: "
            + (", ".join(f"{k} {v}" for k, v in r["ended_from"].items()) or "none"), "",
            f"  {'project':<24} {'ended':>5} {'no PR':>5} {'merged':>6} {'ci red':>6} {'ci ok':>5} {'NEEDS min':>9} {'STALLED min':>11}"]
    out += [f"  {p:<24} {d.get('ended', 0):>5} {d.get('ended_no_pr', 0):>5} {d.get('prs_merged', 0):>6} {d.get('ci_fail', 0):>6}"
            f" {d.get('ci_pass', 0):>5} {d.get('needs_min', 0):>9} {d.get('stalled_min', 0):>11}" for p, d in r["by_project"].items()]
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(prog="fleet-sessions stages")
    ap.add_argument("--log", default=str(Path.home() / ".agent/shepherd/watch.log"))
    ap.add_argument("--from", dest="start", type=int)
    ap.add_argument("--to", dest="end", type=int)
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args(argv)
    end = a.end or int(time.time())
    w = Window(a.start if a.start is not None else end - 86400, end)
    try:
        with open(a.log) as fh:
            replay(fh, w)
    except OSError as e:
        print(f"fleet-sessions stages: {e}", file=sys.stderr)
        return 1
    r = report(w)
    print(json.dumps(r) if a.json else text(r))
    return 0


if __name__ == "__main__":
    sys.exit(main())
