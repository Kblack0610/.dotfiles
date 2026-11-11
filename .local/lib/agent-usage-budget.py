#!/usr/bin/env python3
"""agent-usage budget: what the fleet pays this month, one line per bill, and what each fee carries.

The ledger ($BUDGET_LEDGER, default ~/.config/agentctl/budget, private) lists every bill as
`name kind usd_month [ref=...]`. Each kind has exactly one reader, and the cap or price comes from
the system that bills it wherever that system says it:
  subscription  a flat monthly fee, the only number the ledger holds. ref is a claude-acct account
                (its list-price work is the sum of the daily token-usage snapshots) or `codex`.
  litellm       the Lazer pool as the gateway meters it (`lazer-spend --json`), cap included; a budget
                window that does not reset on the 1st is named on the line.
  github        org billing (ref = the org): net month-to-date spend on every product; the cap is the
                sum of the product budgets.
  aws           the ci-burst budget the CI governor exports to Prometheus (actual, limit, AWS's forecast).
  digitalocean  month-to-date usage from doctl; there is no cap.
usd_month is `-` on a metered line (its system holds the cap) and `?` on a bill whose price is not known.
A reader that fails makes its line `unread`, and an unknown price makes it `unpriced`: both leave the
total partial and are never counted as $0. Subscription fees count whole in the month they are paid.
"""
import argparse
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
LAZER = ENV.get("BUDGET_LAZER_BIN", "lazer-spend")
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
            bills.append({"name": line[0], "kind": line[1], "usd_month": usd, "ref": opts.get("ref", line[0])})
    return bills


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
    """List-price dollars per payer key from this month's daily snapshots, and the days they cover."""
    days_due = today.day - 1 if (today.year, today.month) == month else calendar.monthrange(*month)[1]
    by, covered = {}, 0
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
    return by, covered, days_due


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
            key = account_dirs().get(b["ref"], b["ref"])
            if key in work:
                line["list_usd"] = round(work[key], 2)
        elif b["kind"] == "litellm":
            t = run_json([LAZER, "--json"])
            spent, cap = float(t.get("spend") or 0), t.get("max_budget")
            cap = float(cap) if cap is not None else None
            p = pace(spent, frac)
            # The gateway refuses a call once the team is at its cap, so the month ends at the higher of the two.
            line.update(cap=cap, spent=spent, projected=min(p, max(cap, spent)) if cap is not None else p)
            reset = str(t.get("budget_reset_at") or "")[:10]
            nxt = f"{month[0] + month[1] // 12:04d}-{month[1] % 12 + 1:02d}-01"
            if reset and reset != nxt:
                line["note"] = f"its budget window resets {reset}, not on the 1st"
        elif b["kind"] == "github":
            org = b["ref"]
            budgets = run_json(["gh", "api", f"/organizations/{org}/settings/billing/budgets"]).get("budgets") or []
            usage = run_json(["gh", "api", f"/organizations/{org}/settings/billing/usage?year={month[0]}&month={month[1]}"])
            caps = {x.get("budget_product_sku"): float(x.get("budget_amount") or 0) for x in budgets}
            caps = {k: v for k, v in caps.items() if v > 0}
            spent = sum(float(u.get("netAmount") or 0) for u in usage.get("usageItems") or [])
            cap = sum(caps.values()) or None
            p = pace(spent, frac)
            line.update(cap=cap, spent=spent, projected=min(p, max(cap, spent)) if cap else p,
                        note=", ".join(f"{k} ${v:,.0f}" for k, v in sorted(caps.items())))
        elif b["kind"] == "aws":
            vals = {r["metric"].get("kind"): float(r["value"][1]) for r in prom("ci_governor_budget_usd")}
            if "actual" not in vals:
                raise Unread("no ci_governor_budget_usd{kind=actual} in Prometheus")
            line.update(cap=vals.get("limit"), spent=vals["actual"], projected=vals.get("forecast", pace(vals["actual"], frac)),
                        note="AWS's own forecast" if "forecast" in vals else "")
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
    work, covered, due = list_work(month, now.date())
    lines = [read_bill(b, frac, work, month) for b in parse_ledger(LEDGER)]
    ok = [x for x in lines if x["spent"] is not None]
    return {
        "schema": 1,
        "month": f"{month[0]:04d}-{month[1]:02d}",
        "as_of": now.isoformat(timespec="seconds"),
        "day": now.day, "days": days,
        "list_days": {"covered": covered, "due": due},
        "total": {
            "spent": round(sum(x["spent"] for x in ok), 2),
            "projected": round(sum(x["projected"] for x in ok), 2),
            "caps": round(sum(x["cap"] for x in lines if x["cap"] is not None), 2),
            "list_usd": round(sum(x["list_usd"] or 0 for x in lines), 2),
        },
        "partial": [x["name"] for x in lines if x["status"] in ("unread", "unpriced")],
        "lines": lines,
    }


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
        if x["status"] != "ok":
            tail = f"{x['status']}: {tail}" if tail else x["status"]
        print(f"  {x['name']:<12} {x['kind']:<13} {money(x['cap']):>8} {money(x['spent']):>8} {money(x['projected']):>8}  {tail}")
    print(f"  list price is what the work would cost on the API; the subscriptions pay {money(t['list_usd'])} of it with their fees")


def main():
    ap = argparse.ArgumentParser(prog="agent-usage budget", description=__doc__.split("\n")[0])
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    if not os.path.exists(LEDGER):
        sys.exit(f"agent-usage budget: no ledger at {LEDGER} (set BUDGET_LEDGER)")
    now = dt.datetime.fromisoformat(ENV["BUDGET_NOW"]) if ENV.get("BUDGET_NOW") else dt.datetime.now().astimezone()
    d = budget(now)
    if a.json:
        print(json.dumps(d))
    else:
        print_budget(d)


if __name__ == "__main__":
    main()
