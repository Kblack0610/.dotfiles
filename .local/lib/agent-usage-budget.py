#!/usr/bin/env python3
"""agent-usage budget: what the fleet pays this month, one line per bill, and what each fee carries.

The ledger ($BUDGET_LEDGER, default ~/.config/agentctl/budget, private) lists every bill as
`name kind usd_month [ref=...]`. Each kind has exactly one reader, and the cap or price comes from
the system that bills it wherever that system says it:
  subscription  a flat monthly fee, the only number the ledger holds. ref is a claude-acct account
                (its list-price work is the sum of the daily token-usage snapshots) or `codex`.
  litellm       a gateway team (ref = the claude-acct account, default the line's name) as claude-acct
                publishes it to Prometheus (claude_account_usd_used, _usd_budget, _resets_timestamp_seconds),
                the one reader of the gateway's spend; a stale claude-acct textfile makes the line unread,
                and a budget window that does not reset on the 1st is named on the line.
  github        org billing (ref = the org): net month-to-date spend on every product; the cap is the
                sum of the product budgets, and each capped product is kept on the line for `check`.
  aws           the ci-burst budget the CI governor exports to Prometheus (actual, limit, AWS's forecast).
  digitalocean  month-to-date usage from doctl; there is no cap.
usd_month is `-` on a metered line (its system holds the cap) and `?` on a bill whose price is not known.
A reader that fails makes its line `unread`, and an unknown price makes it `unpriced`: both leave the
total partial and are never counted as $0. Subscription fees count whole in the month they are paid.

Options after the price: ref= (above), paid_by= (someone else pays this bill: it is shown, and left out
of our totals, the split and `check`), project= and lane= (where a metered bill's cash goes in the split;
by default project `unattributed` and lane the kind; github splits by repo, through project-map aliases).

The split: each subscription's fee goes to projects and lanes by its account's share of this month's
list-price work (the snapshots' fleet_cost.by_session: account, project, origin as the lane); a session
with no project, or an account with no work, goes to `unattributed`. by_project and by_lane each sum to
total.spent exactly. `check` reads $BUDGET_JSON (the fleet-bench step writes it from --json) and exits 1
(the fleet-budget-pace watch) on a file older than 2h, or on any of these, which --json also writes as `needs` for the Costs tab: a capped metered line or product over pace (spend over cap * elapsed share + $15,
or over 90% of the cap), a metered line whose month projection (AWS's own
forecast on aws) passes its cap, or a line unread for 24h (unread_since is carried over from the previous
file, the only record of how long a reader has failed). Fixed fees are never a trigger: they are spent whole.
"""
import argparse
import re
import calendar
import datetime as dt
import functools
import glob
import importlib.util
import json
import os
import subprocess
import sys

HOME = os.path.expanduser("~")
ENV = os.environ
LEDGER = ENV.get("BUDGET_LEDGER", f"{HOME}/.config/agentctl/budget")
ACCOUNTS = ENV.get("CLAUDE_ACCT_CONFIG", f"{ENV.get('XDG_CONFIG_HOME', HOME + '/.config')}/claude-acct/accounts")
TOKENS_DIR = ENV.get("TOKENS_DIR", f"{HOME}/.agent/token-usage")
BUDGET_JSON = ENV.get("BUDGET_JSON", f"{HOME}/.local/state/fleet/budget.json")
PROJECT_MAP = ENV.get("PROJECT_MAP", f"{HOME}/.config/shared-hooks/project-map.json")
CLAUDE_ACCT_STALE_SECS = 3600  # hub-core burn::STALE_AFTER_SECS, the same textfile
FILE_STALE_SECS = 2 * 3600     # hub-core fleet_cost::STALE_SECS, the fleet-bench step's 30-minute file
UNREAD_DAYS = 1
PACE_SLACK_USD = 15            # about one heavy merge day of Actions (set for Actions pace, 2026-09-28)
CAP_WARN = 0.9
UNATTRIBUTED = "unattributed"
SCHEMA = 2
READ_TIMEOUT = 30  # seconds per reader; each is one HTTP call or two
KINDS = ("subscription", "litellm", "github", "aws", "digitalocean")


class Unread(Exception):
    pass


def run_json(cmd):
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=READ_TIMEOUT)
    except (OSError, subprocess.TimeoutExpired) as e:
        raise Unread(f"{cmd[0]} did not run: {e}") from e
    if r.returncode:
        raise Unread(f"{cmd[0]} failed: {(r.stderr or r.stdout).strip()[:120]}")
    try:
        return json.loads(r.stdout)
    except ValueError as e:
        raise Unread(f"{cmd[0]} returned no JSON") from e


@functools.cache
def burn_module():
    path = os.path.join(os.path.dirname(os.path.realpath(__file__)), "agent-usage-burn.py")
    spec = importlib.util.spec_from_file_location("agent_usage_burn", path)
    burn = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(burn)
    return burn


def prom(query):
    """One instant query through agent-usage-burn.py's prom(), the one owner of the Prometheus call."""
    burn = burn_module()
    try:
        return burn.prom(query, dt.datetime.now().timestamp())
    except burn.PromError as e:
        raise Unread(str(e)) from e


def parse_ledger(path):
    bills = []
    with open(path) as f:
        for n, raw in enumerate(f, 1):
            line = raw.split("#", 1)[0].split()
            if not line:
                continue
            if len(line) < 3 or line[1] not in KINDS:
                sys.exit(f"agent-usage budget: {path}:{n}: want `name kind usd_month [ref=...]`, kind one of {', '.join(KINDS)}")
            opts = dict(o.split("=", 1) for o in line[3:] if "=" in o)
            usd = line[2]
            if usd not in ("-", "?"):
                try:
                    usd = float(usd)
                except ValueError:
                    sys.exit(f"agent-usage budget: {path}:{n}: usd_month {usd!r} is not a number, - or ?")
            if line[1] != "subscription" and usd != "-":
                sys.exit(f"agent-usage budget: {path}:{n}: a {line[1]} bill's cap comes from its system; write -")
            for k, v in opts.items():
                if not re.fullmatch(r"[A-Za-z0-9_.-]+", v):
                    sys.exit(f"agent-usage budget: {path}:{n}: {k}={v!r}: letters, digits, _ . - only")
            bills.append({"name": line[0], "kind": line[1], "usd_month": usd, "ref": opts.get("ref", line[0]),
                          "paid_by": opts.get("paid_by"), "project": opts.get("project"), "lane": opts.get("lane")})
    return bills


def payer_key(b):
    """The snapshot key a subscription's work is recorded under."""
    return account_dirs().get(b["ref"], b["ref"])


@functools.cache
def account_dirs():
    """claude-acct account name -> the config dir basename the snapshots key by_account on."""
    out = {}
    try:
        with open(ACCOUNTS) as f:
            for raw in f:
                p = raw.split("#", 1)[0].split()
                if len(p) >= 2:
                    out[p[0]] = "claude" if p[1] == "-" else os.path.basename(p[1].rstrip("/")).lstrip(".")
    except OSError:
        pass
    return out


def list_work(month, today):
    """List-price dollars per payer key from this month's daily snapshots, the days they cover, and per
    payer key the (project, lane) -> dollars its sessions ran."""
    days_due = today.day - 1 if (today.year, today.month) == month else calendar.monthrange(*month)[1]
    by, covered, cells, split_days = {}, 0, {}, 0
    for p in sorted(glob.glob(os.path.join(TOKENS_DIR, f"{month[0]:04d}-{month[1]:02d}-*.json"))):
        if os.path.basename(p)[8:10] > f"{days_due:02d}":
            continue  # a day the month has not finished yet
        try:
            with open(p) as f:
                d = json.load(f)
        except (OSError, ValueError):
            continue
        fc = (d.get("fleet_cost") if isinstance(d, dict) else None) or {}
        if not isinstance(fc, dict) or not isinstance(fc.get("by_account"), dict):
            continue
        covered += 1
        for k, v in fc["by_account"].items():
            by[k] = by.get(k, 0) + (v.get("usd") or 0)
        for k, v in (fc.get("other_harness") or {}).items():
            by[k] = by.get(k, 0) + (v.get("usd") or 0)
        split_days += bool(fc.get("by_session"))
        for r in fc.get("by_session") or []:
            if not isinstance(r, dict) or not r.get("usd"):
                continue
            key = r.get("account") or r.get("harness") or "unknown"   # codex sessions carry no account
            proj = r.get("project") if r.get("project") not in (None, "", "_unscoped") else UNATTRIBUTED
            cell = (proj, r.get("origin") or UNATTRIBUTED)
            cells.setdefault(key, {})[cell] = cells.get(key, {}).get(cell, 0) + r["usd"]
    return by, covered, days_due, cells, split_days


def gateway_team(ref):
    """A gateway team's spend, budget and reset as claude-acct publishes them, in one query; the textfile's
    age rides along the way hub-core burn::ACCOUNTS reads it, so a stopped claude-acct timer is unread, not
    a frozen number."""
    names = "usd_used|usd_budget|resets_timestamp_seconds"
    q = (f'{{__name__=~"claude_account_({names})",account="{ref}"}} or label_replace(max(time() - '
         f'node_textfile_mtime_seconds{{file=~".*claude_acct.prom"}}), "__name__", "claude_account_textfile_age_seconds", "", "")')
    t = {r["metric"].get("__name__", "").removeprefix("claude_account_"): float(r["value"][1]) for r in prom(q)}
    if "usd_used" not in t:
        raise Unread(f"claude-acct publishes no claude_account_usd_used{{account={ref}}}")
    age = t.get("textfile_age_seconds")
    if age is None:
        raise Unread("no claude-acct textfile age in Prometheus, so its numbers may be frozen")
    if age > CLAUDE_ACCT_STALE_SECS:
        raise Unread(f"claude-acct's textfile is {age / 3600:.1f}h old (timer claude-acct-usage)")
    return t


def project_aliases():
    try:
        with open(PROJECT_MAP) as f:
            return json.load(f).get("aliases") or {}
    except (OSError, ValueError, AttributeError):
        return {}


def split(lines, cells, work):
    """Each counted line's cash -> {(project, lane): usd}, unrounded."""
    aliases = project_aliases()
    out = {}

    def add(cell, usd):
        out[cell] = out.get(cell, 0) + usd

    for x in lines:
        if not counted(x):
            continue
        if x["kind"] == "subscription":
            mine = cells.get(payer_key(x), {})
            total = sum(mine.values())
            if total <= 0:
                add((UNATTRIBUTED, UNATTRIBUTED), x["spent"])
            for cell, usd in mine.items():
                add(cell, x["spent"] * usd / total)
        elif x.get("by_repo"):
            lane = x.get("lane") or x["kind"]
            for repo, usd in x["by_repo"].items():
                add((aliases.get(repo) or repo.lstrip("."), lane), usd)
        else:
            add((x.get("project") or UNATTRIBUTED, x.get("lane") or x["kind"]), x["spent"])
    return out


def rollup(cells, axis, total):
    """Cents per project or lane, largest first, the rounding remainder on the largest so the rows sum to total."""
    by = {}
    for cell, usd in cells.items():
        by[cell[axis]] = by.get(cell[axis], 0) + usd
    rows = sorted(({"name": k, "usd": round(v, 2)} for k, v in by.items() if round(v, 2)), key=lambda r: -r["usd"])
    if rows:
        rows[0]["usd"] = round(rows[0]["usd"] + total - sum(r["usd"] for r in rows), 2)
    return rows


def counted(x):
    """A line in our cash: read, priced, and paid by us."""
    return x["spent"] is not None and not x.get("paid_by")


def pace(spent, frac):
    return spent / frac if frac > 0 else spent


def read_bill(b, frac, work, month):
    line = {**b, "cap": None, "spent": None, "projected": None, "list_usd": None, "status": "ok", "note": ""}
    fee = b["usd_month"]
    try:
        if b["kind"] == "subscription":
            if fee in ("-", "?"):
                line["status"] = "unpriced"
                return line
            line.update(cap=fee, spent=fee, projected=fee)
            key = payer_key(b)
            if key in work:
                line["list_usd"] = round(work[key], 2)
        elif b["kind"] == "litellm":
            t = gateway_team(b["ref"])
            spent, cap = t["usd_used"], t.get("usd_budget")
            p = pace(spent, frac)
            # The gateway refuses a call once the team is at its cap, so the month ends at the higher of the two.
            line.update(cap=cap, spent=spent, projected=min(p, max(cap, spent)) if cap is not None else p)
            reset = (dt.datetime.fromtimestamp(t["resets_timestamp_seconds"], dt.timezone.utc).strftime("%Y-%m-%d")
                     if t.get("resets_timestamp_seconds") else "")
            nxt = f"{month[0] + month[1] // 12:04d}-{month[1] % 12 + 1:02d}-01"
            if reset and reset != nxt:
                line["note"] = f"its budget window resets {reset}, not on the 1st"
                line["off_calendar"] = True
        elif b["kind"] == "github":
            org = b["ref"]
            budgets = run_json(["gh", "api", f"/organizations/{org}/settings/billing/budgets"]).get("budgets") or []
            usage = run_json(["gh", "api", f"/organizations/{org}/settings/billing/usage?year={month[0]}&month={month[1]}"])
            caps = {str(x.get("budget_product_sku")).lower(): float(x.get("budget_amount") or 0) for x in budgets}
            caps = {k: v for k, v in caps.items() if v > 0}
            items = usage.get("usageItems") or []
            spent = sum(float(u.get("netAmount") or 0) for u in items)
            by_sku, by_repo = {}, {}
            for u in items:
                n = float(u.get("netAmount") or 0)
                sku = str(u.get("product")).lower()
                by_sku[sku] = by_sku.get(sku, 0) + n
                repo = u.get("repositoryName") or UNATTRIBUTED
                by_repo[repo] = by_repo.get(repo, 0) + n
            cap = sum(caps.values()) or None
            p = pace(spent, frac)
            line.update(cap=cap, spent=spent, projected=min(p, max(cap, spent)) if cap else p,
                        note=", ".join(f"{k} ${v:,.0f}" for k, v in sorted(caps.items())),
                        products={k: {"cap": v, "spent": round(by_sku.get(k, 0), 2)} for k, v in sorted(caps.items())},
                        by_repo=by_repo)
        elif b["kind"] == "aws":
            rows = prom('{__name__=~"ci_governor_budget_(usd|ok)"}')
            # The governor keeps serving its last figure after a failed AWS Budgets read: not a current one.
            if any(r["metric"].get("__name__") == "ci_governor_budget_ok" and float(r["value"][1]) == 0 for r in rows):
                raise Unread('the governor\'s last AWS Budgets read failed (runbook, "budget read")')
            vals = {r["metric"]["kind"]: float(r["value"][1]) for r in rows if "kind" in r["metric"]}
            if "actual" not in vals:
                raise Unread("no ci_governor_budget_usd{kind=actual} in Prometheus")
            # AWS forecasts from history; on a new account it can sit below what is already spent.
            fc = vals.get("forecast")
            if fc is not None and fc < vals["actual"]:
                fc = None
            line.update(cap=vals.get("limit"), spent=vals["actual"], projected=pace(vals["actual"], frac) if fc is None else fc,
                        note="AWS's own forecast" if fc is not None else "")
        elif b["kind"] == "digitalocean":
            spent = float(run_json(["doctl", "balance", "get", "-o", "json"])["month_to_date_usage"])
            line.update(spent=spent, projected=pace(spent, frac))
    except (Unread, KeyError, TypeError, ValueError) as e:
        line.update(status="unread", note=str(e) if isinstance(e, Unread) else f"unexpected answer: {e}")
        return line
    if line["cap"] is not None and line["spent"] is not None and line["spent"] > line["cap"]:
        line["status"] = "over"
        line["note"] = f"past its ${line['cap']:,.0f} cap" + (f"; {line['note']}" if line["note"] else "")
    for k in ("cap", "spent", "projected"):
        if line[k] is not None:
            line[k] = round(line[k], 2)
    return line


def budget(now):
    month = (now.year, now.month)
    days = calendar.monthrange(*month)[1]
    start = now.replace(day=1, hour=0, minute=0, second=0, microsecond=0)
    # Pace from at least one day: a few hours of a new month would multiply any carried-over usage by hundreds.
    frac = max((now - start).total_seconds() / 86400, 1) / days
    work, covered, due, cells, split_days = list_work(month, now.date())
    lines = [read_bill(b, frac, work, month) for b in parse_ledger(LEDGER)]
    carry_unread(lines, now)
    ours = [x for x in lines if not x.get("paid_by")]
    ok = [x for x in ours if counted(x)]
    spent = round(sum(x["spent"] for x in ok), 2)
    by = split(lines, cells, work)
    for x in lines:
        x.pop("by_repo", None)
    d = {
        "schema": SCHEMA,
        "month": f"{month[0]:04d}-{month[1]:02d}",
        "as_of": now.isoformat(timespec="seconds"),
        "as_of_epoch": int(now.timestamp()),
        "day": now.day, "days": days, "elapsed": round(frac, 4),
        "list_days": {"covered": covered, "due": due, "split": split_days},
        "total": {
            "spent": spent,
            "projected": round(sum(x["projected"] for x in ok), 2),
            "caps": round(sum(x["cap"] for x in ours if x["cap"] is not None), 2),
            "list_usd": round(sum(x["list_usd"] or 0 for x in ours), 2),
        },
        "partial": [x["name"] for x in ours if x["status"] in ("unread", "unpriced")],
        "others_pay": [{"name": x["name"], "paid_by": x["paid_by"], "spent": x["spent"]} for x in lines if x.get("paid_by")],
        "by_project": rollup(by, 0, spent),
        "by_lane": rollup(by, 1, spent),
        "lines": lines,
    }
    d["needs"] = reasons(d, now)
    return d


def carry_unread(lines, now):
    """unread_since on each unread line: kept from the previous $BUDGET_JSON when that line was unread there too."""
    try:
        with open(BUDGET_JSON) as f:
            prev = {x["name"]: x.get("unread_since") for x in json.load(f).get("lines") or []}
    except (OSError, ValueError, AttributeError, KeyError, TypeError):
        prev = {}
    for x in lines:
        if x["status"] == "unread":
            x["unread_since"] = prev.get(x["name"]) or now.isoformat(timespec="seconds")


def check(now):
    """Reasons the budget needs a look, from $BUDGET_JSON; empty when it does not."""
    try:
        with open(BUDGET_JSON) as f:
            d = json.load(f)
    except (OSError, ValueError) as e:
        return [f"no readable {BUDGET_JSON}: {e}"]
    if not isinstance(d, dict) or d.get("schema") != SCHEMA:
        return [f"{BUDGET_JSON} is not schema {SCHEMA} (written by an older agent-usage budget?)"]
    age = now.timestamp() - d["as_of_epoch"]
    if age > FILE_STALE_SECS:
        return [f"{os.path.basename(BUDGET_JSON)} is {age / 3600:.1f}h old (the fleet-bench budget step)"]
    return reasons(d, now)


def reasons(d, now):
    """What `check` trips on in one budget, other than its age; the file carries them as `needs`, which
    the Costs Budget tab shows, so the tab and the watch say the same thing."""
    why, el = [], d["elapsed"]
    for x in d.get("lines") or []:
        if x.get("paid_by"):
            continue
        if x.get("status") == "unread" and x.get("unread_since"):
            since = dt.datetime.fromisoformat(x["unread_since"])
            if (now - since).total_seconds() > UNREAD_DAYS * 86400:
                why.append(f"{x['name']} unread since {x['unread_since'][:16]}: {x.get('note', '')}")
        caps = [(f"{x['name']} {k}", v["cap"], v["spent"]) for k, v in (x.get("products") or {}).items()]
        if not caps and x.get("cap") and x.get("spent") is not None and x["kind"] != "subscription":
            caps = [(x["name"], x["cap"], x["spent"])]
        if x.get("off_calendar"):
            caps = []  # its spend covers another window; the calendar share would misjudge its pace
        mine = []
        for name, cap, spent in caps:
            limit = min(cap * el + PACE_SLACK_USD, CAP_WARN * cap)
            if spent > limit:
                mine.append(f"{name} ${spent:,.0f} is ahead of pace: past ${limit:,.0f} of its ${cap:,.0f} cap on day {d['day']}")
        if not mine and x["kind"] != "subscription" and x.get("cap") and (x.get("projected") or 0) > x["cap"]:
            mine.append(f"{x['name']} projects to ${x['projected']:,.0f} this month, past its ${x['cap']:,.0f} cap")
        why += mine
    return why


def money(v):
    return "-" if v is None else f"${v:,.0f}"


def print_budget(d):
    t = d["total"]
    print(f"fleet budget {d['month']}, day {d['day']} of {d['days']}: about {money(t['projected'])} cash this month, "
          f"{money(t['spent'])} so far, {money(t['caps'])} in fees and caps")
    if d["partial"]:
        print(f"  partial, not counted: {', '.join(d['partial'])}")
    lc = d["list_days"]
    print(f"  {'bill':<12} {'kind':<13} {'fee/cap':>8} {'so far':>8} {'month':>8}  list-price work, {lc['covered']} of {lc['due']} days")
    for x in d["lines"]:
        tail = x["note"]
        if x["list_usd"] is not None:
            tail = f"{money(x['list_usd'])}" + (f" ({x['list_usd'] / x['cap']:.0f}x the fee)" if x["cap"] else "")
        if x.get("paid_by"):
            tail = f"paid by {x['paid_by']}; {tail}" if tail else f"paid by {x['paid_by']}"
        if x["status"] != "ok":
            tail = f"{x['status']}: {tail}" if tail else x["status"]
        print(f"  {x['name']:<12} {x['kind']:<13} {money(x['cap']):>8} {money(x['spent']):>8} {money(x['projected']):>8}  {tail}")
    for o in d.get("others_pay") or []:
        print(f"  {o['name']} is paid by {o['paid_by']}: shown, not in our total")
    for axis in ("by_project", "by_lane"):
        rows = d.get(axis) or []
        print(f"  {axis.replace('_', ' ')}: " + ", ".join(f"{r['name']} {money(r['usd'])}" for r in rows[:8])
              + (f", +{len(rows) - 8} more" if len(rows) > 8 else ""))
    print(f"  list price is what the work would cost on the API; the subscriptions pay {money(t['list_usd'])} of it with their fees")


def main():
    ap = argparse.ArgumentParser(prog="agent-usage budget", description=__doc__.split("\n")[0])
    ap.add_argument("action", nargs="?", choices=["check"], help="check: exit 1 when $BUDGET_JSON needs a look")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    now = dt.datetime.fromisoformat(ENV["BUDGET_NOW"]) if ENV.get("BUDGET_NOW") else dt.datetime.now().astimezone()
    if a.action == "check":
        if a.json:
            ap.error("check prints its reasons as text; --json is for the budget itself")
        why = check(now)
        print("\n".join(why) if why else "budget on pace")
        sys.exit(1 if why else 0)
    if not os.path.exists(LEDGER):
        sys.exit(f"agent-usage budget: no ledger at {LEDGER} (set BUDGET_LEDGER)")
    d = budget(now)
    if a.json:
        print(json.dumps(d))
    else:
        print_budget(d)


if __name__ == "__main__":
    main()
