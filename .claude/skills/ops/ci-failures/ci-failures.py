#!/usr/bin/env python3
"""Why CI is red: every failed job in a window, put in one bucket and grouped by signature.

    ci-failures.py --repo OWNER/NAME [--workflow FILE]... [--branch B]... [--base main]
                   [--days N] [--until TIME] [--cache DIR] [--offline] [--json]

Reads the finished GitHub Actions runs created in the N days (default 3) ending at --until
(default now), and for every red run each attempt's jobs, each failed job's check-run
annotations and, when those say nothing but an exit code, its `--log-failed` output. Each
failed job gets:

- a signature: workflow / job / failed step :: the line that says what broke, with numbers,
  SHAs and workspace paths normalized so the same failure on two branches groups as one;
- a bucket: infra (runner lost or killed, disk, network, rate limit, host key), timeout,
  test (a test step or a FAIL/Failed line), check (any other step: lint, docs, build), or
  derived (failed only because an earlier job in the run did; listed, never counted);
- main: the same signature is red on the base branch in the window, so every branch inherits it;
- green@sha: the same job (exact name) went green on the same commit in the same workflow
  (another run or attempt). A lead, not a verdict: the PR body, a variable, the tests a dispatch
  picked or a moving base can change between the two, so it is flaky only once those are ruled out.

A red run counts once, in the bucket of its first root (non-derived) job. A run whose own
conclusion is cancelled is not a red. A finished attempt's jobs, annotations and logs never
change, so they are cached under DIR (default ~/.cache/ci-failures/<owner>-<name>); the run
list is re-read online every time, since a rerun changes it. --offline reads only the cache.
On a gh error the script stops fetching, reports what it has, says PARTIAL and exits 3.
"""
import argparse
import datetime
import glob
import json
import os
import re
import subprocess
import sys

# What a line has to say to be infra or a timeout. Matched against the job's annotations, its
# signature line and its exit code, never the whole log: a test log may print these on purpose.
INFRA = [
    (r"exit code 137", "killed (exit 137: OOM or runner)"),
    (r"The operation was canceled", "job canceled mid-run: runner lost or shut down"),
    (r"lost communication with the server", "runner lost"),
    (r"runner has received a shutdown signal", "runner shut down"),
    (r"No space left on device", "disk full"),
    (r"Host key verification failed", "ssh host key"),
    (r"rate limit (exceeded|reached)|secondary rate limit", "rate limit"),
    (r"\b50[234]\b.{0,20}(Bad Gateway|Service Unavailable|Gateway Time)|HTTP.{0,12}\b50[234]\b|Internal Server Error", "server 5xx"),
    (r"Could not resolve host|Temporary failure in name resolution", "dns"),
    (r"early EOF|RPC failed|unexpected disconnect|Connection reset by peer", "network dropped mid-transfer"),
]
TIMEOUT = r"exceeded the maximum execution time|timed out after|Timeout of \d+"
# Case matters: "traceback" inside a Python ResourceWarning is noise, "Traceback (most recent" is not.
ERROR = re.compile(r"::error::|\b[Ee]rror\b|\bERROR\b|\bFAIL(ED)?\b|\bFailed\b|\bfatal\b|^Traceback \(most|\w(Error|Exception)\b|\bKilled\b")
TEST_STEP = re.compile(r"test|suite|spec|e2e|pytest|bats|playmode|editmode", re.I)
GENERIC = re.compile(r"^Process completed with exit code \d+\.?$")
STAMP = re.compile(r"^\ufeff?\d{4}-\d\d-\d\dT[\d:.]+Z ?")
ANSI = re.compile(r"(?:\x1b|\^\[)\[[0-9;]*m")
WORKSPACE = re.compile(r"\S*?/(?:_work|work)/[^/\s]+/[^/\s]+/")
RUN_FIELDS = "databaseId,workflowName,headBranch,headSha,event,status,conclusion,createdAt,attempt,url"


class Partial(Exception):
    pass


def parse_time(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def stamp(t):
    return t.astimezone(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def normalize(text):
    text = WORKSPACE.sub("", ANSI.sub("", text)).strip()
    text = re.sub(r"\b[0-9a-f]{7,40}\b", "<sha>", text)
    # A path names one instance of a failure (which doc, which file changed); the cause is the
    # rest of the line. The record keeps the raw line.
    text = re.sub(r"(?<![\w<])[\w.-]*(?:/[\w.@-]+)+", "<path>", text)
    text = re.sub(r"<path>(?:,? (?:and )?<path>)+", "<path>", text)
    text = re.sub(r"\d+", "N", text)
    return re.sub(r"\s+", " ", text)[:160]


class Source:
    """GitHub through gh, behind a cache of everything that never changes."""

    def __init__(self, repo, cache, offline):
        self.repo, self.cache, self.offline = repo, cache, offline
        self.partial = 0
        os.makedirs(cache, exist_ok=True)

    def gh(self, *args):
        if self.partial:
            raise Partial()
        try:
            return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout
        except (subprocess.CalledProcessError, OSError) as e:
            err = getattr(e, "stderr", "") or str(e)
            print(f"gh {' '.join(args[:3])}: {err.strip()[:200]}", file=sys.stderr)
            self.partial = 1
            raise Partial()

    def cached(self, name, fetch, as_json=True):
        path = os.path.join(self.cache, name)
        if os.path.exists(path):
            with open(path, encoding="utf-8", errors="replace") as f:
                return json.load(f) if as_json else f.read()
        if self.offline:
            return None
        try:
            data = fetch()
        except Partial:
            return None
        with open(path, "w", encoding="utf-8") as f:
            f.write(data)
        return json.loads(data) if as_json else data

    def runs(self, workflows, since, until):
        if not self.offline:
            span = f"{stamp(since)}..{stamp(until)}"
            for wf in workflows or [None]:
                args = ["run", "list", "-R", self.repo, "--created", span, "-L", "5000", "--json", RUN_FIELDS]
                try:
                    listed = json.loads(self.gh(*args, *(["--workflow", wf] if wf else [])))
                except Partial:
                    break
                for run in listed:
                    if run.get("status") != "completed":
                        continue
                    # A run's file records every --workflow it was listed under, so an offline
                    # read can filter by the same file name gh was given.
                    path = os.path.join(self.cache, f"run-{run['databaseId']}.json")
                    seen = set()
                    if os.path.exists(path):
                        with open(path) as f:
                            seen = set(json.load(f).get("_listed_as", []))
                    run["_listed_as"] = sorted(seen | ({wf} if wf else set()))
                    with open(path, "w") as f:
                        json.dump(run, f)
        out = []
        for path in glob.glob(os.path.join(self.cache, "run-*.json")):
            with open(path) as f:
                run = json.load(f)
            if since <= parse_time(run["createdAt"]) <= until:
                out.append(run)
        return sorted(out, key=lambda r: r["createdAt"])

    def jobs(self, run, attempt):
        rid = run["databaseId"]
        data = self.cached(f"jobs-{rid}-{attempt}.json",
                           lambda: self.gh("api", f"repos/{self.repo}/actions/runs/{rid}/attempts/{attempt}/jobs?per_page=100"))
        return (data or {}).get("jobs", [])

    def annotations(self, job):
        return self.cached(f"ann-{job['id']}.json",
                           lambda: self.gh("api", f"repos/{self.repo}/check-runs/{job['id']}/annotations")) or []

    def log(self, job):
        return self.cached(f"log-{job['id']}.txt",
                           lambda: self.gh("run", "view", "-R", self.repo, "--job", str(job["id"]), "--log-failed"),
                           as_json=False) or ""


def read_log(text):
    """The signature line, every error-looking line, and the exit code, from --log-failed output.

    Each line is "<job>\\t<step>\\t<timestamp> <text>". The ##[group] blocks hold the step's own
    script and env, echoed back, so they are skipped: an `echo ::error::` there is source, not output."""
    out, errors, code, in_group = [], [], None, False
    for raw in text.splitlines():
        line = ANSI.sub("", STAMP.sub("", raw.split("\t", 2)[-1])).strip()
        if line.startswith("##[group]"):
            in_group = True
        elif line.startswith("##[endgroup]"):
            in_group = False
        elif in_group or not line:
            continue
        elif line.startswith("##[error]"):
            msg = line[len("##[error]"):]
            m = re.search(r"exit code (\d+)", msg)
            if GENERIC.match(msg) and m:
                if code is None:
                    code, cut = int(m.group(1)), len(out)
            else:
                errors.append(msg)
        elif not line.startswith("##["):
            out.append(line)
    # The failing step ends at its exit-code line; what follows is post-job cleanup.
    out = out[:cut] if code is not None else out
    errors += [l for l in out if ERROR.search(l)]
    return (errors[0] if errors else (out[-1] if out else "")), errors[:5], code


def record(src, run, attempt, job):
    failed = [s["name"] for s in job.get("steps") or [] if s.get("conclusion") in ("failure", "timed_out")]
    notes = [a.get("message", "") for a in src.annotations(job) if a.get("annotation_level") == "failure"]
    said = [n for n in notes if not GENERIC.match(n.strip())]
    line, errors, code = read_log(src.log(job)) if not said else (said[0], said[:5], None)
    if code is None:
        codes = [int(m.group(1)) for n in notes for m in [re.search(r"exit code (\d+)", n)] if m]
        code = codes[0] if codes else None
    probe = " ".join([*said, line, f"exit code {code}" if code is not None else ""])
    if job.get("conclusion") == "timed_out" or re.search(TIMEOUT, probe):
        bucket, why = "timeout", "timeout"
    else:
        hit = next(((p, w) for p, w in INFRA if re.search(p, probe, re.I)), None)
        bucket, why = ("infra", hit[1]) if hit else (None, "")
    step = failed[0] if failed else "(no failed step)"
    return {
        "run": run["databaseId"], "attempt": attempt, "url": job.get("html_url") or run.get("url"),
        "workflow": run["workflowName"], "branch": run["headBranch"], "sha": run["headSha"],
        "created": run["createdAt"], "job": job["name"], "job_key": normalize(job["name"]), "step": step,
        "runner": job.get("runner_name"), "started": job.get("started_at"), "completed": job.get("completed_at"),
        "line": line, "errors": errors, "exit_code": code, "why": why, "bucket": bucket,
        "specific": bool(said or errors), "signature": f"{run['workflowName']} / {normalize(job['name'])} / {step} :: {normalize(line)}",
    }


def finish_buckets(records):
    """Derived first (needs the whole attempt), then test or check for what is left."""
    by_attempt = {}
    for r in records:
        by_attempt.setdefault((r["run"], r["attempt"]), []).append(r)
    for rs in by_attempt.values():
        for r in rs:
            if r["bucket"] or r["specific"]:
                continue
            start = parse_time(r["started"])
            earlier = [o for o in rs if o is not r and o["completed"] and start and parse_time(o["completed"]) <= start]
            if earlier:
                r["bucket"], r["why"] = "derived", "failed after " + ", ".join(sorted({o["job"] for o in earlier}))
    for r in records:
        if not r["bucket"]:
            test = TEST_STEP.search(r["step"]) or any(re.search(r"\bFAIL\b|\bFailed\b", e) for e in r["errors"])
            r["bucket"] = "test" if test else "check"


def collect(src, runs):
    red = [r for r in runs if r["conclusion"] not in ("success", "cancelled", "skipped", "neutral", "action_required") or r.get("attempt", 1) > 1]
    red_ids = {r["databaseId"] for r in red}
    red_shas = {(r["workflowName"], r["headSha"]) for r in red}
    records, greens = [], set()
    for run in runs:
        attempts = range(1, run.get("attempt", 1) + 1)
        is_red = run["databaseId"] in red_ids
        if not is_red and (run["workflowName"], run["headSha"]) not in red_shas:
            continue
        for attempt in attempts:
            jobs = src.jobs(run, attempt)
            if not jobs and is_red and attempt == run.get("attempt", 1) and run["conclusion"] == "startup_failure":
                records.append({**record_stub(run, attempt), "bucket": "check", "why": "startup failure"})
            for job in jobs:
                # The exact name: shards "PlayMode 1" and "PlayMode 2" share a job_key, and a
                # green sibling shard is not the same job going green.
                key = (run["workflowName"], run["headSha"], job["name"])
                if job.get("conclusion") == "success":
                    greens.add(key)
                elif is_red and job.get("conclusion") in ("failure", "timed_out"):
                    records.append(record(src, run, attempt, job))
    finish_buckets(records)
    for r in records:
        r["green_sha"] = (r["workflow"], r["sha"], r["job"]) in greens
    return records


def record_stub(run, attempt):
    return {"run": run["databaseId"], "attempt": attempt, "url": run.get("url"), "workflow": run["workflowName"],
            "branch": run["headBranch"], "sha": run["headSha"], "created": run["createdAt"], "job": "(no jobs)",
            "job_key": "(no jobs)", "step": "(startup)", "runner": None, "started": None, "completed": None,
            "line": "startup failure", "errors": [], "exit_code": None, "specific": True,
            "signature": f"{run['workflowName']} / (no jobs) / (startup) :: startup failure"}


def analyse(runs, records, base, branches):
    on_main = {r["signature"] for r in records if r["branch"] == base and r["bucket"] != "derived"}
    for r in records:
        r["main"] = r["signature"] in on_main
    shown = [r for r in records if not branches or r["branch"] in branches or r["branch"] == base]
    roots = [r for r in shown if r["bucket"] != "derived"]
    first = {}
    for r in sorted(roots, key=lambda r: (r["completed"] or r["created"])):
        first.setdefault(r["run"], r)
    sigs = {}
    for r in roots:
        s = sigs.setdefault(r["signature"], {"signature": r["signature"], "bucket": r["bucket"], "why": r["why"],
                                             "runs": set(), "jobs": 0, "branches": set(), "main": r["main"],
                                             "green_sha": False, "first": r["created"], "last": r["created"], "sample": r["url"]})
        s["runs"].add(r["run"]); s["jobs"] += 1; s["branches"].add(r["branch"]); s["green_sha"] |= r["green_sha"]
        s["first"], s["last"] = min(s["first"], r["created"]), max(s["last"], r["created"])
    where = {}
    for r in first.values():
        w = r["signature"].split(" :: ")[0]
        where[w] = where.get(w, 0) + 1
    table = sorted(sigs.values(), key=lambda s: (-len(s["runs"]), -s["jobs"], s["signature"]))
    for s in table:
        s["runs"], s["branches"] = len(s["runs"]), sorted(s["branches"])
    scope = [r for r in runs if not branches or r["headBranch"] in branches or r["headBranch"] == base]
    buckets = {}
    for r in first.values():
        buckets[r["bucket"]] = buckets.get(r["bucket"], 0) + 1
    return {
        "runs": len(scope), "red_runs": len(first), "cancelled": sum(r["conclusion"] == "cancelled" for r in scope),
        "derived_jobs": sum(r["bucket"] == "derived" for r in shown), "buckets": buckets, "signatures": table,
        "where": sorted(where.items(), key=lambda kv: (-kv[1], kv[0])),
        "by_workflow": {wf: [sum(r["workflowName"] == wf for r in scope),
                             len({x for x, r in first.items() if r["workflow"] == wf})]
                        for wf in sorted({r["workflowName"] for r in scope})},
        "base": [len([r for r in scope if r["headBranch"] == base]),
                 len({x for x, r in first.items() if r["branch"] == base})],
    }


def report(a, args, since, until, partial):
    print(f"ci-failures: {args.repo}, {stamp(since)} to {stamp(until)}" + ("  PARTIAL: gh failed, counts are low" if partial else ""))
    pct = lambda n, d: f"{100 * n / d:.0f}%" if d else "-"
    print(f"runs: {a['runs']} finished, {a['red_runs']} red ({pct(a['red_runs'], a['runs'])}), {a['cancelled']} cancelled (not red)")
    print("red by workflow: " + ", ".join(f"{wf} {red}/{n}" for wf, (n, red) in a["by_workflow"].items()))
    print(f"{args.base}: {a['base'][1]} red of {a['base'][0]}")
    print("\nbucket    runs  share   (each red run counted once, by its first failed job)")
    for b in ("test", "check", "infra", "timeout"):
        if a["buckets"].get(b):
            print(f"{b:<9} {a['buckets'][b]:>4}  {pct(a['buckets'][b], a['red_runs']):>5}")
    print(f"derived jobs (failed only after another job did, not counted): {a['derived_jobs']}")
    print("\nruns  where (workflow / job / failed step of each red run's first failed job)")
    for w, n in a["where"][: args.top]:
        print(f"{n:>4}  {w}")
    print(f"\nruns  jobs  bucket   {args.base[:4]:<4}  green@sha  branches  first        last         signature")
    for s in a["signatures"][: args.top]:
        print(f"{s['runs']:>4}  {s['jobs']:>4}  {s['bucket']:<7}  {'yes' if s['main'] else '-':<4}  "
              f"{'yes' if s['green_sha'] else '-':<9}  {len(s['branches']):>8}  {s['first'][5:16]:<11}  {s['last'][5:16]:<11}  {s['signature']}")
        print(f"{'':>20}{s['why'] + '  ' if s['why'] else ''}{s['sample']}")
    if len(a["signatures"]) > args.top:
        print(f"... {len(a['signatures']) - args.top} more (--top N, or --json)")


def main(argv):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("--repo", required=True)
    p.add_argument("--workflow", action="append", default=[], help="workflow file or name; repeat; default every workflow")
    p.add_argument("--branch", action="append", default=[], help="report only these branches (the base is always read)")
    p.add_argument("--base", default="main")
    p.add_argument("--days", type=float, default=3)
    p.add_argument("--until", help="end of the window, UTC (2026-11-04T06:00:00Z); default now")
    p.add_argument("--cache")
    p.add_argument("--offline", action="store_true")
    p.add_argument("--json", action="store_true")
    p.add_argument("--top", type=int, default=25)
    args = p.parse_args(argv[1:])
    until = parse_time(args.until) if args.until else datetime.datetime.now(datetime.timezone.utc)
    since = until - datetime.timedelta(days=args.days)
    cache = args.cache or os.path.expanduser(f"~/.cache/ci-failures/{args.repo.replace('/', '-')}")
    src = Source(args.repo, cache, args.offline)
    runs = src.runs(args.workflow, since, until)
    if args.workflow:
        want = set(args.workflow)
        runs = [r for r in runs if r["workflowName"] in want or want & set(r.get("_listed_as", []))]
    records = collect(src, runs)
    a = analyse(runs, records, args.base, set(args.branch))
    if args.json:
        json.dump({"repo": args.repo, "since": stamp(since), "until": stamp(until), "partial": bool(src.partial),
                   **a, "records": records}, sys.stdout, indent=1, default=str)
        print()
    else:
        report(a, args, since, until, src.partial)
    return 3 if src.partial else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
