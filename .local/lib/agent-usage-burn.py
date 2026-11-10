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
  queue        $AGENT_QUEUE_DIR/**/*.md. A session's origin (plan, or the item's `origin:` hand,
               run, resume), item and #size/ tag. Joined by the item's `sessions:` ids, else by
               its tmux `session:` name matching the worktree the session ran in while the item
               ran (items older than `sessions:` carry only that). A session no item names is
               a runner when headless, else interactive.
  shepherd     $FLEET_SHEPHERD_DIR/passes.tsv and .pass: every fleet-shepherd pass id. A pass
               is an interactive cli session in ~/.dotfiles, so without this it reads as
               interactive; it gets origin shepherd.
  requests     the api-request lines Claude Code writes before each call, main threads and
               subagents alike: a shape (system prompt, tools) by shapeHash, and the messages
               as the base request's first `keep` plus a `tail` of blob hashes. Only blobs
               Claude Code adds itself (instructions, listings, reminders) are stored as
               api-request-blob lines; most conversation messages are in the transcript
               instead, so they count in a request's tokens, not its parts (`conversation` is
               only the stored ones). The response names its request
               (requestRef). Parts are chars, because only the request total has a token
               count: chars_per_token is the first requests' chars over their tokens, which
               are nearly all fixed text, and every request's context_share uses it.
There is no price table on purpose; see the agent-usage header.
"""
import argparse
import datetime as dt
import glob
import json
import os
import re
import statistics
import subprocess
import sys
from collections import Counter, defaultdict

WAIT_RE = re.compile(
    r"(^|[;&|\s(])sleep\s+\d|\buntil\b.*;\s*do\b|gh pr checks\b.*--watch|gh run watch\b|\bgh-run-wait\b"
    r"|/tasks/[^\s'\"]+\.output")
# A response's turn class, from its tool calls: write wins over wait, wait over investigate;
# a response with no tool call is a reply.
WRITE_TOOLS = {"Edit", "Write", "NotebookEdit", "MultiEdit"}
WRITE_RE = re.compile(r"\bgit\s+(commit|push|merge)\b|\bgh\s+pr\s+(create|merge|edit|comment)\b|\bagent-land\b")
MIX = ("investigate", "wait", "write", "reply")
IDLE_LONG = 3600     # the prompt cache TTL these sessions request ("1h")
IDLE_SHORT = 300     # the default cache TTL
ITEM_LEAD = 600      # seconds a session may start before its item records `started:`

# Where each part of a recorded request's system-role text starts. Text before the first
# marker is system_other.
SYS_PARTS = [("preflight", r"SessionStart hook additional context"), ("environment", r"^# Environment\n"),
             ("deferred_list", r"^The following deferred tools are now available"),
             ("agent_listing", r"^Available agent types for the Agent tool"),
             ("mcp_instructions", r"^# MCP Server Instructions"),
             ("skill_listing", r"^The following skills are available for use with the Skill tool")]


def shape_parts(shape):
    """(parts, tools) of a request shape: the system prompt and each tool's schema, in chars."""
    parts, tools = Counter(), Counter()
    parts["system_prompt"] = sum(len(b.get("text", "")) for b in shape.get("system") or [])
    for t in shape.get("tools") or []:
        n = t.get("name", "?")
        tools[n] = len(json.dumps(t))
        parts["tools_mcp" if n.startswith("mcp__") else "tools_builtin"] += tools[n]
    return parts, tools


def blob_parts(m):
    """Chars per part of one recorded message: the system-role listings, the CLAUDE.md /
    MEMORY.md files in a user message's first block, the prompt, and the rest."""
    parts = Counter()
    content = m.get("content") or []
    for j, b in enumerate([content] if isinstance(content, str) else content):
        if isinstance(b, str):
            b = {"type": "text", "text": b}
        elif not isinstance(b, dict):
            b = {}
        txt = b.get("text", "")
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
        elif m.get("role") == "user" and b.get("type") == "text":
            parts["prompt"] += len(txt)
        else:
            parts["conversation"] += len(json.dumps(b))
    return parts


class Parts:
    """Parts of a set of recorded requests: chars per part, and each tool's schema over the
    requests that carry it (a mean over all requests would shrink a tool few sessions load)."""

    def __init__(self):
        self.n, self.ctx = 0, 0
        self.parts, self.tool_chars, self.tool_n = defaultdict(list), Counter(), Counter()

    def add(self, ctx, parts, tools):
        self.n += 1
        self.ctx += ctx
        for k, v in parts.items():
            if v:
                self.parts[k].append(v)
        self.tool_chars.update(tools)
        self.tool_n.update(tools.keys())

    def chars(self):
        return sum(sum(v) for v in self.parts.values())

    def cpt(self):
        """Chars a token over these requests, or None with none recorded."""
        return self.chars() / self.ctx if self.ctx else None

    def summary(self, cpt=None):
        """cpt: chars a token, to turn each part into a share of these requests' context."""
        total, n = self.chars(), self.n
        keys = sorted(self.parts, key=lambda k: (-sum(self.parts[k]), k))
        out = {"requests": n, "parts": {}}
        if not cpt:  # these requests' own ratio, true only when they are nearly all fixed text
            out["chars_per_token"] = round(self.cpt(), 2) if self.ctx else None
        for k in keys:
            v = self.parts[k]
            out["parts"][k] = {"median_chars": int(statistics.median(v + [0] * (n - len(v)))),
                               "mean_chars": sum(v) // n, "share": round(sum(v) / total, 3)}
            if cpt:
                out["parts"][k]["context_share"] = round(sum(v) / cpt / self.ctx, 4) if self.ctx else None
        out["tools_mean_chars"] = {k: c // self.tool_n[k] for k, c in self.tool_chars.most_common(12)}
        out["tool_requests"] = {k: self.tool_n[k] for k, _ in self.tool_chars.most_common(12)}
        return out


class Requests:
    """One transcript's recorded requests, each resolved to its parts. A request keeps only its
    own tail: its parts are its base's plus the tail's, so a long session is one pass, and only
    a request that drops messages (keep under its base's length) walks the chain back. Shapes
    and blobs are keyed by content hash, so their parts are worked out once for every file."""
    shapes, blobs = {}, {}

    def __init__(self):
        self.reqs = {}

    def blob(self, h):
        return self.blobs.get(h) or Counter()

    def hashes(self, ref):
        chain = []
        while ref:
            chain.append(self.reqs[ref])
            ref = chain[-1]["base"]
        h = []
        for r in reversed(chain):
            h = h[:r["keep"]] + r["tail"]
        return h

    def line(self, d):
        t = d.get("type")
        if t == "api-request-shape":
            h = d.get("shapeHash")
            if h and h not in self.shapes:
                self.shapes[h] = shape_parts(d.get("shape") or {})
        elif t == "api-request-blob":
            h = d.get("hash")
            if h and h not in self.blobs:
                self.blobs[h] = blob_parts(d.get("message") or {})
        elif t == "api-request" and d.get("id"):
            base, keep, tail = d.get("base"), d.get("keep") or 0, d.get("tail") or []
            if base and base not in self.reqs:
                return  # its base is in another file (a resume): its parts are unknown
            b = self.reqs.get(base) or {"n": 0, "parts": Counter()}
            if keep < b["n"]:
                parts = Counter()
                for h in self.hashes(base)[:keep]:
                    parts.update(self.blob(h))
            else:
                parts = b["parts"].copy()
            for h in tail:
                parts.update(self.blob(h))
            self.reqs[d["id"]] = {"base": base, "keep": keep, "tail": tail, "n": min(keep, b["n"]) + len(tail),
                                  "parts": parts, "shape": d.get("shapeHash")}

    def parts(self, ref):
        """(parts, tools) of request `ref`, or None when it was not recorded."""
        r = self.reqs.get(ref)
        if r is None or r["shape"] not in self.shapes:  # no hash is never a key, so it is unrecorded
            return None
        sp, tools = self.shapes[r["shape"]]
        return sp + r["parts"], tools


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


def session_of(path):
    """The session a transcript belongs to: its own id, or its parent's for a subagent thread."""
    parts = path.split(os.sep)
    if "subagents" in parts:
        return parts[parts.index("subagents") - 1]
    return os.path.splitext(os.path.basename(path))[0]


def turn_class(tools):
    if not tools:
        return "reply"
    for c in ("write", "wait"):
        if c in tools:
            return c
    return "investigate"


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
    ctx_by_mid, wait_mids, tools_by_mid = {}, set(), defaultdict(set)
    sid = session_of(path)
    sess = acc["session"][sid]
    first, turns, seq = None, 0, 0  # seq: the session's responses, in the window or not
    reqs = Requests()
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
            if t in ("api-request-shape", "api-request-blob", "api-request"):
                reqs.line(d)
                continue
            if t == "system" and "compact" in str(d.get("subtype", "")):
                after_compact = True
                n = 1 if start <= (ts(d.get("timestamp", "")) or 0) < end else 0
                acc["compactions"] += n
                sess["compactions"] += n
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
                    probe = probe if isinstance(probe, str) else ""
                    tmid = msg.get("id") or d.get("requestId")
                    if WAIT_RE.search(probe):
                        acc["wait_calls"] += 1
                        wait_mids.add(tmid)
                        tools_by_mid[tmid].add("wait")
                    elif b.get("name") in WRITE_TOOLS or (b.get("name") == "Bash" and WRITE_RE.search(probe)):
                        tools_by_mid[tmid].add("write")
                    else:
                        tools_by_mid[tmid].add("investigate")
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
            sess[("s:" if kind == "subagent" else "m:") + model] += 1
            if kind == "subagent":
                sess["subagent_turns"] += 1
            elif sid not in acc["meta"]:
                acc["meta"][sid] = (kind, (first or {}).get("cwd") or "", ts((first or {}).get("timestamp", "")) or now)
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
            per_type = acc["tok"][(sid, model)]
            per_type["input"] += i
            per_type["output"] += o
            per_type["cache_write"] += cw
            per_type["cache_read"] += cr
            acc["kind_files"][kind].add(path)
            sess["turns"] += 1
            sess["context"] += ctx
            if kind == "subagent":
                sess["subagent_context"] += ctx
            req = reqs.parts(d.get("requestRef"))
            if req is not None:
                acc["every_parts"].add(ctx, *req)
                acc["every_kind"][kind] += 1
            else:
                acc["every_unrecorded"] += 1
            if seq == 1 and kind != "subagent":
                acc["first_ctx"].append(ctx)
                sess["first_turn_context"] = ctx
                if req is not None:
                    acc["first_parts"].add(ctx, *req)
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
    sess["wait_context"] += sum(ctx_by_mid.get(x, 0) for x in wait_mids)
    for mid, ctx in ctx_by_mid.items():
        c = turn_class(tools_by_mid.get(mid))
        acc["mix"][c]["turns"] += 1
        acc["mix"][c]["context"] += ctx
        sess[c] += 1


def registry(start, end, root):
    by_acct, by_proj, n, cost, last = defaultdict(lambda: Counter()), defaultdict(lambda: Counter()), 0, 0.0, {}
    by_sess = {}
    for f in glob.glob(os.path.join(root, "*", "sessions.jsonl")):
        rows = {}
        for line in open(f, errors="ignore"):
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("session_id"):
                rows[r["session_id"]] = r
        last.update(rows)
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
            by_sess[r["session_id"]] = by_sess.get(r["session_id"], 0) + c  # one sid in two registries counts in both, as cost does
    return n, cost, by_acct, by_proj, last, by_sess


def merged_prs(start, end, root):
    prs, zero_ctx, all_ctx, last, by_sess = set(), 0, 0, {}, defaultdict(set)
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
                by_sess[r["session_id"]].add(f"{p.get('repo')}#{p.get('number')}")
    return len(prs), zero_ctx, all_ctx, by_sess


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


def queue_items(root):
    items = []
    for f in glob.glob(os.path.join(root, "**", "*.md"), recursive=True):
        try:
            head, _, body = open(f, errors="ignore").read().partition("\n---\n")
        except OSError:
            continue
        fm = dict(m.groups() for m in re.finditer(r"^([a-z_]+): ?(.*)$", head, re.M))
        if not fm.get("slug"):
            continue
        size = re.search(r"#size/([sml])\b", body + " " + fm.get("title", ""))
        items.append({"slug": fm["slug"], "mode": fm.get("mode"), "origin": fm.get("origin"), "project": fm.get("project"),
                      "sessions": fm.get("sessions", "").split(), "tmux": fm.get("session", "").split(":")[-1],
                      "started": ts(fm.get("started", "")), "finished": ts(fm.get("finished", "")),
                      "size": size.group(1) if size else None})
    return items


def shepherd_passes(root):
    """Every fleet-shepherd pass's session id: passes.tsv (<start>\t<id>\t...) once scored,
    .pass (<id>\t...) while it runs."""
    ids = set()
    for name, col in (("passes.tsv", 1), (".pass", 0)):
        try:
            for line in open(os.path.join(root, name), errors="ignore"):
                f = line.rstrip("\n").split("\t")
                if len(f) > col and f[col]:
                    ids.add(f[col])
        except OSError:
            pass
    return ids


def origin_of(sid, meta, by_sid, by_tmux, passes=frozenset()):
    """(origin, item) for a session: a shepherd pass, a queue item names it, else its kind decides."""
    if sid in passes:
        return "shepherd", None
    kind, cwd, first_t = meta.get(sid, ("?", "", None))
    it = by_sid.get(sid)
    if it is None and cwd and first_t:
        for c in by_tmux.get(os.path.basename(cwd.rstrip("/")), ()):
            if c["started"] and c["started"] - ITEM_LEAD <= first_t <= (c["finished"] or float("inf")):
                it = c
                break
    if it is not None:
        return ("plan" if it["mode"] == "plan" else it["origin"] or "queue"), it
    return ("runner" if kind == "headless" else "interactive"), None


# The fleet's dollars. Rates are fitted to the sessions Claude Code billed, on every run, so no price
# table can drift. A model the fit cannot price stays named, never $0.
TOKEN_TYPES = ("input", "output", "cache_read", "cache_write")
PROM_TOKEN_TYPES = {"input": "input", "output": "output", "cacheRead": "cache_read", "cacheCreation": "cache_write"}
PROM_COST = "claude_code_cost_usage_USD_total"
PROM_TOKENS = "claude_code_token_usage_tokens_total"
FIT_HOURS = 24            # the priced sessions the rates come from
FIT_MIN_SESSIONS = 6      # half are held out to score the fit
FIT_MIN_MTOK = 5.0
FIT_MAX_ERROR_PCT = 5.0   # a fit that misses its held-out sessions by more prices nothing
GATEWAY_PROVIDERS = ("litellm", "gateway")
HELPER_MIN_BILLED = 5.0   # an origin billed less than this says nothing about its helper share
PROM_LOOKBACK = "7d"      # how far back a session's pre-window total is looked for
CARRY_SNAPSHOTS = 14      # newest token snapshots read for carried rates; each one keeps the rows it carried


class PromError(Exception):
    pass


def prom(query, at):
    """One instant query through prom.sh, the one owner of the URL and its env."""
    lib = os.environ.get("PROM_LIB") or os.path.join(os.path.dirname(os.path.realpath(__file__)), "prom.sh")
    env = {**os.environ, "PROM_TIMEOUT": "40"}
    r = subprocess.run(["bash", "-c", '. "$0"; prom_q "$1" "$2"', lib, query, str(int(at))],
                       capture_output=True, text=True, env=env)
    try:
        if r.returncode:
            raise ValueError
        return json.loads(r.stdout)["data"]["result"]
    except (ValueError, KeyError) as e:
        raise PromError(f"Prometheus did not answer: {query[:60]}") from e


def clean_model(m):
    return re.sub(r"\[.*\]$", "", m or "?")


def solve(rows):
    """Least squares over (x, y) with no negative rate: drop the most negative column and re-solve."""
    active = [i for i in range(len(TOKEN_TYPES)) if any(x[i] for x, _ in rows)]
    while active:
        m = [[sum(x[i] * x[j] for x, _ in rows) for j in active] + [sum(x[i] * y for x, y in rows)] for i in active]
        n = len(active)
        for c in range(n):
            piv = max(range(c, n), key=lambda r: abs(m[r][c]))
            if abs(m[piv][c]) < 1e-9:
                return None
            m[c], m[piv] = m[piv], m[c]
            for r in range(n):
                if r != c:
                    f = m[r][c] / m[c][c]
                    m[r] = [a - f * b for a, b in zip(m[r], m[c])]
        sol = [m[i][n] / m[i][i] for i in range(n)]
        if min(sol) >= 0:
            rates = [0.0] * len(TOKEN_TYPES)
            for i, v in zip(active, sol):
                rates[i] = v
            return rates
        active.pop(sol.index(min(sol)))
    return None


def price(rates, x):
    return sum(r * v for r, v in zip(rates, x))


CARRY_UNFIT = "too few priced tokens"   # the one unfit reason a carried rate may fill in for


def fit_rates(samples):
    """{model: [(session, [Mtok by type], usd)]} -> ({model: rate row}, {model: why it has none})."""
    rates, unfit = {}, {}
    for model, rows in samples.items():
        rows = sorted(rows)
        pairs = [(x, y) for _, x, y in rows]
        if len(pairs) < FIT_MIN_SESSIONS or sum(map(sum, (x for x, _ in pairs))) < FIT_MIN_MTOK:
            unfit[model] = CARRY_UNFIT
            continue
        train, held = pairs[::2], pairs[1::2]
        trial = solve(train)
        spent = sum(y for _, y in held)
        err = abs(sum(price(trial, x) for x, _ in held) - spent) / spent * 100 if trial and spent > 0 else None
        final = solve(pairs) if err is not None and err <= FIT_MAX_ERROR_PCT else None
        if final is None:
            unfit[model] = "the fit missed its held-out sessions"
            continue
        missing = [t for t, v in zip(TOKEN_TYPES, final) if v <= 0]
        if missing:   # no rate for a type is unknown, and would price that type at $0
            unfit[model] = f"no billed {missing[0]} tokens to fit"
            continue
        rates[model] = {**{t: round(v, 4) for t, v in zip(TOKEN_TYPES, final)},
                        "sessions": len(pairs), "fit_error_pct": round(err, 2)}
    return rates, unfit


def carried_rates(tokens_dir):
    """{model: rate row plus `from`, the day it was fitted} from the newest token snapshot that fitted each model.
    A per-token price belongs to the model, not the day, so a window Prometheus no longer covers (it keeps
    7 days) is priced at the last fitted rate instead of not at all."""
    out = {}
    for f in sorted(glob.glob(os.path.join(tokens_dir, "????-??-??.json")), reverse=True)[:CARRY_SNAPSHOTS]:
        try:
            with open(f) as fh:
                rates = json.load(fh)["fleet_cost"]["rates"]
            rows = {m: r for m, r in rates.items() if isinstance(r, dict) and all(
                isinstance(r.get(t), (int, float)) for t in TOKEN_TYPES)}
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            continue
        for model, row in rows.items():   # a row carried into that snapshot keeps the day it was fitted
            out.setdefault(model, {**row, "from": row.get("from") or os.path.basename(f)[:10]})
    return out


def price_samples(at):
    """What the rates are fitted to: each billed session's cost and tokens by model."""
    w = f"{FIT_HOURS}h"
    q = "sum by (session_id, model{})(max_over_time({}[" + w + "]))"
    cost = {(r["metric"].get("session_id"), clean_model(r["metric"].get("model"))): float(r["value"][1])
            for r in prom(q.format("", PROM_COST), at)}
    toks = defaultdict(lambda: [0.0] * len(TOKEN_TYPES))
    for r in prom(q.format(", type", PROM_TOKENS), at):
        kind = PROM_TOKEN_TYPES.get(r["metric"].get("type"))
        if kind:
            key = (r["metric"].get("session_id"), clean_model(r["metric"].get("model")))
            toks[key][TOKEN_TYPES.index(kind)] += float(r["value"][1]) / 1e6
    out = defaultdict(list)
    for key, usd in cost.items():
        if usd > 0 and key in toks:
            out[key[1]].append((key[0], toks[key], usd))
    return out


def measured_in_window(start, end):
    """{(session, model): (usd spent inside the window, runner label)}. A counter's window maximum less its
    last value before the window: `increase` loses the first sample of a short session."""
    secs = int(end - start)
    now = prom(f"sum by (session_id, model, agentctl_runner)(max_over_time({PROM_COST}[{secs}s]))", end)
    before = {(r["metric"].get("session_id"), clean_model(r["metric"].get("model"))): float(r["value"][1])
              for r in prom(f"sum by (session_id, model)(max_over_time({PROM_COST}[{PROM_LOOKBACK}] offset {secs}s))", end)}
    out = {}
    for r in now:   # one session can carry several runner labels; what came before comes off once
        key = (r["metric"].get("session_id"), clean_model(r["metric"].get("model")))
        usd, runner = out.get(key, (0.0, None))
        out[key] = (usd + float(r["value"][1]), runner or r["metric"].get("agentctl_runner"))
    return {k: (max(0.0, usd - before.get(k, 0.0)), runner) for k, (usd, runner) in out.items()}


def runner_calls(state_dir):
    """{session: (runner, account)} from agentctl's call records."""
    out = {}
    for f in glob.glob(os.path.join(state_dir, "calls.jsonl*")):
        if f.endswith(".gz"):
            continue
        for line in open(f, errors="ignore"):
            try:
                r = json.loads(line)
            except ValueError:
                continue
            if r.get("session_id"):
                out[r["session_id"]] = (r.get("agent"), os.path.basename(r.get("account") or "").lstrip("."))
    return out


def other_harnesses(start, end, root):
    """Every non-Claude harness from its session outcomes: newest row per session, tagged by its price source.
    Sessions that went through the gateway are left out: its metered line already has their dollars."""
    newest = {}
    for f in glob.glob(os.path.join(root, "*", "*.jsonl")):
        try:
            if os.path.getmtime(f) < start:
                continue
        except OSError:
            continue
        for line in open(f, errors="ignore"):
            try:
                r = json.loads(line)
            except ValueError:
                continue
            at = r.get("updated_epoch") or 0
            if (not (r.get("harness") or "claude").startswith("claude") and r.get("provider") not in GATEWAY_PROVIDERS
                    and start <= at < end and at >= (newest.get(r.get("session_id")) or {}).get("updated_epoch", 0)):
                newest[r.get("session_id")] = r
    out = defaultdict(lambda: {"usd": 0.0, "sessions": 0, "priced": 0, "sources": set()})
    rows = []
    for sid, r in newest.items():
        b = out[r["harness"]]
        b["sessions"] += 1
        if r.get("cost_usd") is not None:
            b["usd"] += r["cost_usd"]
            b["priced"] += 1
            b["sources"].add(r.get("cost_src") or "harness")
            rows.append({"sid": sid, "usd": r["cost_usd"], "measured": 0.0, "estimated": r["cost_usd"],
                         "origin": "runner" if r.get("runner") else "interactive", "harness": r["harness"],
                         "agent": r.get("agent"), "account": None, "project": r.get("project"),
                         "title": r.get("title"), "item": None})
    return out, rows


def fleet_cost(start, end, acc, reg_last, by_sid, by_tmux, passes, env, home):
    """The one estimate of what the whole fleet spent: billed sessions keep their billed cost, the rest are
    priced from their tokens, every figure says which it is."""
    rates, unfit = fit_rates(price_samples(end))
    state = env.get("XDG_STATE_HOME", f"{home}/.local/state")
    # only a model the window had too little to fit is carried; a fit tried and rejected stays unpriced
    carried = {m: r for m, r in carried_rates(env.get("TOKENS_DIR", f"{home}/.agent/token-usage")).items()
               if m not in rates and unfit.get(m, CARRY_UNFIT) == CARRY_UNFIT}
    fitted, rates = set(rates), {**rates, **carried}
    measured = measured_in_window(start, end)
    calls = runner_calls(env.get("AGENTCTL_STATE_DIR", f"{state}/agentctl"))

    def bucket():
        return {"usd": 0.0, "measured": 0.0, "estimated": 0.0, "sessions": 0, "sessions_measured": 0}
    by = {k: defaultdict(bucket) for k in ("origin", "runner", "account", "model")}
    sess = defaultdict(lambda: {"measured": 0.0, "estimated": 0.0, "priced": 0.0, "whole": True, "runner": None})
    # a name the direct bills also fit is direct traffic, whatever the gateway calls its own routes
    gateway_models = {r["metric"].get("model") for r in prom("sum by (model)(litellm_spend_metric_total)", end)} - fitted
    for (sid, model), (usd, runner) in measured.items():
        if usd > 0 and model not in gateway_models:
            sess[sid]["measured"] += usd
            sess[sid]["runner"] = sess[sid]["runner"] or runner
            by["model"][model]["measured"] += usd
    tokens_all = tokens_est = 0
    unpriced = defaultdict(lambda: {"tokens": 0, "sessions": set()})
    gateway_sessions = set()
    for (sid, raw), t in acc["tok"].items():
        model = clean_model(raw)
        n = sum(t[k] for k in TOKEN_TYPES)
        tokens_all += n
        s = sess[sid]
        if model in gateway_models:   # metered: its dollars are the gateway line below
            gateway_sessions.add(sid)
            continue
        usd = sum(rates[model][k] * t[k] / 1e6 for k in TOKEN_TYPES) if model in rates else None
        s["priced"] += usd or 0.0
        s["whole"] = s["whole"] and usd is not None
        if s["measured"] > 0:
            continue
        tokens_est += n
        if usd is None:
            unpriced[model]["tokens"] += n
            unpriced[model]["sessions"].add(sid)
        else:
            s["estimated"] += usd
            by["model"][model]["estimated"] += usd

    # Calls a transcript never records (helper Haiku, compaction) show as billed sessions costing more
    # than their transcript tokens price to. Unbilled sessions get that share as its own line, with
    # the range the origins' mix allows.
    billed, priced = defaultdict(float), defaultdict(float)
    by_session = []
    for sid, s in sess.items():
        origin, it = origin_of(sid, acc["meta"], by_sid, by_tmux, passes) if sid in acc["meta"] or sid in by_sid else (
            "runner" if s["runner"] else "interactive", None)
        name = "shepherd" if sid in passes else ((calls.get(sid) or (None, None))[0] or s["runner"] or "unattributed")
        account = re.search(r"/\.(claude[^/]*)/projects/", (reg_last.get(sid) or {}).get("transcript") or "")
        account = account.group(1) if account else ((calls.get(sid) or (None, None))[1] or "unknown")
        cuts = [("origin", origin), ("account", account)] + ([("runner", name)] if origin in ("runner", "shepherd") else [])
        for cut, key in cuts:
            b = by[cut][key]
            b["measured"] += s["measured"]
            b["estimated"] += s["estimated"]
            b["sessions"] += 1
            b["sessions_measured"] += s["measured"] > 0
        if s["measured"] + s["estimated"] > 0:   # a session that cost nothing has no row, never a $0 one
            reg = reg_last.get(sid) or {}
            cwd = acc["meta"].get(sid, ("", "", None))[1]
            agent = name if origin in ("runner", "shepherd") else ((it or {}).get("tmux") or os.path.basename(cwd.rstrip("/")) or None)
            by_session.append({"sid": sid, "usd": s["measured"] + s["estimated"], "measured": s["measured"],
                               "estimated": s["estimated"], "origin": origin, "harness": reg.get("harness") or "claude",
                               "agent": agent, "account": account, "project": (it or {}).get("project") or reg.get("project"),
                               "title": reg.get("title"), "item": (it or {}).get("slug")})
        if s["measured"] > 0 and s["priced"] > 0 and s["whole"]:
            billed[origin] += s["measured"]
            priced[origin] += s["priced"]
    measured_usd = sum(s["measured"] for s in sess.values())
    estimated_usd = sum(s["estimated"] for s in sess.values())
    share = max(0.0, sum(billed.values()) / sum(priced.values()) - 1) if priced else 0.0
    top = max([billed[o] / priced[o] - 1 for o in billed if billed[o] >= HELPER_MIN_BILLED] + [0.0])

    gateway = sum(float(r["value"][1]) for r in prom(f"sum(increase(litellm_spend_metric_total[{int(end - start)}s]))", end))
    other, other_rows = other_harnesses(start, end, env.get("OUTCOMES_ROOT", f"{home}/.agent/outcomes"))
    other = {k: {"usd": round(v["usd"], 2), "sessions": v["sessions"], "priced": v["priced"], "source": ",".join(sorted(v["sources"])) or None}
             for k, v in other.items()}
    by_session += other_rows
    priced_other = sum(v["usd"] for v in other.values())   # a price table or the harness's own sum, never a bill
    other["gateway"] = {"usd": round(gateway, 2), "sessions": len(gateway_sessions), "priced": len(gateway_sessions), "source": "metered"}
    helper_usd = estimated_usd * share

    def rows(cut):
        for b in cut.values():
            b["usd"] = round(b["measured"] + b["estimated"], 2)
            b["measured"], b["estimated"] = round(b["measured"], 2), round(b["estimated"], 2)
        return dict(sorted(cut.items(), key=lambda kv: -kv[1]["usd"]))
    return {
        "schema": 1,
        "window": {"start": dt.datetime.fromtimestamp(start).astimezone().isoformat(timespec="seconds"),
                   "end": dt.datetime.fromtimestamp(end).astimezone().isoformat(timespec="seconds")},
        "as_of": dt.datetime.now().astimezone().isoformat(timespec="seconds"),
        "as_of_epoch": int(dt.datetime.now().timestamp()),
        "rates": rates,
        "rates_from": {m: r["from"] for m, r in carried.items() if by["model"][m]["estimated"] > 0},
        "unpriced": {m: {"tokens": v["tokens"], "sessions": len(v["sessions"]), "why": unfit.get(m, "no billed sessions")}
                     for m, v in unpriced.items()},
        "coverage": {"tokens": tokens_all, "tokens_estimated": tokens_est,
                     "estimated_token_share": round(tokens_est / tokens_all, 4) if tokens_all else None,
                     "sessions": len(sess), "sessions_estimated": sum(1 for s in sess.values() if s["measured"] <= 0)},
        "total": {"usd": round(measured_usd + gateway + estimated_usd + helper_usd + priced_other, 2),
                  "measured": round(measured_usd + gateway, 2), "claude_measured": round(measured_usd, 2),
                  "estimated": round(estimated_usd + helper_usd + priced_other, 2),
                  "helper_usd": round(helper_usd, 2), "helper_range": [0, round(estimated_usd * top, 2)]},
        "by_origin": rows(by["origin"]), "by_runner": rows(by["runner"]),
        "by_account": rows(by["account"]), "by_model": rows(by["model"]),
        "other_harness": other,
        # Every session the window priced, dearest first. Their sum is the total less the gateway's
        # metered line and the helper estimate, which no session can be charged with.
        "by_session": [{**r, **{k: round(r[k], 2) for k in ("usd", "measured", "estimated")}}
                       for r in sorted(by_session, key=lambda r: -r["usd"]) if round(r["usd"], 2) > 0],
    }


def print_fleet_cost(d):
    t, c = d["total"], d["coverage"]
    print(f"fleet cost {d['window']['start']} to {d['window']['end']}: about ${t['usd']:,.0f} "
          f"(measured ${t['measured']:,.0f}, estimated ${t['estimated']:,.0f})")
    if c["estimated_token_share"] is not None:
        print(f"{c['estimated_token_share']:.0%} of tokens estimated: {c['sessions_estimated']} of {c['sessions']} sessions have no cost telemetry")
    for k, v in d["by_origin"].items():
        print(f"  {k:<14} ${v['usd']:>9,.2f}  {v['sessions']:>4} sessions, ${v['measured']:,.2f} measured")
    for k, v in d["other_harness"].items():
        print(f"  {k:<14} ${v['usd']:>9,.2f}  {v['source'] or 'unpriced'}")
    print(f"  {'helper calls':<14} ${t['helper_usd']:>9,.2f}  estimated, range $0 to ${t['helper_range'][1]:,.2f}")
    for m, day in d.get("rates_from", {}).items():
        print(f"  {m} priced at the rate fitted on {day} (none fitted in this window)")
    for m, u in d["unpriced"].items():
        print(f"  unpriced {m}: {u['tokens']:,} tokens in {u['sessions']} sessions ({u['why']})")


def main():
    ap = argparse.ArgumentParser(prog="agent-usage burn")
    ap.add_argument("--days", type=float, default=7)
    ap.add_argument("--since", help="start of the window (YYYY-MM-DD, an ISO time, or 90m/12h/2d ago); overrides --days")
    ap.add_argument("--before", help="end of the window (YYYY-MM-DD or ISO time), default now")
    ap.add_argument("--top", type=int, default=15, help="sessions in the by-session table (all in --json)")
    ap.add_argument("--sort", choices=("cost", "turns", "context"), default="cost",
                    help="order of the by-session table and its --json: registry cost (default), turns, or context tokens")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--fleet-cost", action="store_true", help="the whole fleet's measured and estimated dollars")
    a = ap.parse_args()
    end = ts(a.before) if a.before else dt.datetime.now().timestamp()
    if end is None:
        ap.error(f"bad --before {a.before!r} (use YYYY-MM-DD or an ISO time)")
    start = end - a.days * 86400
    if a.since:
        rel = re.fullmatch(r"(\d+)([mhd])", a.since)
        start = (dt.datetime.now().timestamp() - int(rel.group(1)) * {"m": 60, "h": 3600, "d": 86400}[rel.group(2)]
                 if rel else ts(a.since))
        if start is None or start >= end:
            ap.error(f"bad --since {a.since!r} (use YYYY-MM-DD, an ISO time, or 90m/12h/2d, before the end)")
    env = os.environ
    home = os.path.expanduser("~")
    proj_root = env.get("PROJECTS_ROOT", f"{home}/.claude/projects")

    def tok():
        return Counter()
    acc = {"kind": defaultdict(tok), "model": defaultdict(tok), "cw_cause": defaultdict(tok),
           "trigger": defaultdict(tok), "idle_wakes": defaultdict(tok), "first_ctx": [],
           "mix": defaultdict(tok), "session": defaultdict(tok), "meta": {},
           "first_parts": Parts(), "every_parts": Parts(), "every_kind": Counter(), "every_unrecorded": 0,
           "wait_calls": 0, "wait_ctx": 0, "compactions": 0, "kind_files": defaultdict(set),
           "tok": defaultdict(Counter)}
    for p in glob.glob(os.path.join(proj_root, "**", "*.jsonl"), recursive=True):
        try:
            if os.path.getmtime(p) < start:
                continue
        except OSError:
            continue
        scan(p, start, end, acc)

    n, cost, by_acct, by_proj, reg_last, reg_by_sess = registry(start, end, env.get("SESS_ROOT", f"{home}/.agent/sessions"))
    prs, zero_ctx, out_ctx, prs_by_sess = merged_prs(start, end, env.get("OUTCOMES_ROOT", f"{home}/.agent/outcomes"))
    ctx_all = sum(b["input"] + b["cache_write"] + b["cache_read"] for b in acc["kind"].values())
    fc = sorted(acc["first_ctx"])
    by_sid, by_tmux = {}, defaultdict(list)
    for it in queue_items(env.get("AGENT_QUEUE_DIR", f"{home}/.agent/queue")):
        for x in it["sessions"]:
            by_sid[x] = it
        if it["tmux"]:
            by_tmux[it["tmux"]].append(it)
    passes = shepherd_passes(env.get("FLEET_SHEPHERD_DIR", f"{home}/.agent/shepherd"))
    if a.fleet_cost:
        try:
            d = fleet_cost(start, end, acc, reg_last, by_sid, by_tmux, passes, env, home)
        except PromError as e:
            sys.exit(f"agent-usage fleet-cost: {e}")
        print(json.dumps(d, default=float) if a.json else "", end="\n" if a.json else "")
        if not a.json:
            print_fleet_cost(d)
        return
    sessions, by_origin = {}, defaultdict(Counter)
    for sid, v in acc["session"].items():
        if not v["turns"] and not v["compactions"]:
            continue
        r = reg_last.get(sid) or {}
        sp = sorted(prs_by_sess.get(sid, ()))
        c = r.get("cost_usd")
        origin, it = origin_of(sid, acc["meta"], by_sid, by_tmux, passes)
        models = Counter()
        for k, turns in v.items():
            if k[:2] in ("m:", "s:"):
                models[k[2:]] += turns
        models = dict(models.most_common())
        opus = lambda pre: sum(n for k, n in v.items() if k.startswith(pre) and "opus" in k)  # noqa: E731
        # The registry's cost is the whole session's, subagents included, so it stays with the
        # session's origin; the subagent row is subagent threads' turns and context only.
        o = by_origin[origin]
        o["sessions"] += 1
        o["cost_usd"] += c or 0
        o["turns"] += v["turns"] - v["subagent_turns"]
        o["context"] += v["context"] - v["subagent_context"]
        o["opus_turns"] += opus("m:")
        if v["subagent_turns"]:
            by_origin["subagent"]["sessions"] += 1
            by_origin["subagent"]["turns"] += v["subagent_turns"]
            by_origin["subagent"]["context"] += v["subagent_context"]
            by_origin["subagent"]["opus_turns"] += opus("s:")
        sessions[sid] = {
            "project": r.get("project") or "?", "cost_usd": round(c, 2) if c is not None else None,
            "origin": origin, "kind": acc["meta"].get(sid, ("subagent",))[0], "item": it["slug"] if it else None, "size": it["size"] if it else None,
            "models": models, "subagent_turns": v["subagent_turns"],
            "turns": v["turns"], "context": v["context"],
            "mix": {k: v[k] for k in MIX},
            "wait_share": round(v["wait_context"] / v["context"], 3) if v["context"] else None,
            "compactions": v["compactions"], "first_turn_context": v.get("first_turn_context"),
            "merged_prs": sp, "cost_per_merged_pr": round(c / len(sp), 2) if sp and c is not None else None}
    by_field = {"cost": lambda x: (-(x[1]["cost_usd"] or 0), -x[1]["context"]),
                "turns": lambda x: (-x[1]["turns"], -x[1]["context"]),
                "context": lambda x: (-x[1]["context"], -x[1]["turns"])}
    sessions = dict(sorted(sessions.items(), key=by_field[a.sort]))
    turns_all = sum(v["turns"] for v in acc["mix"].values())

    def q(p):
        return fc[min(len(fc) - 1, int(len(fc) * p))] if fc else None
    first = acc["first_parts"]
    out = {
        "window": {"start": dt.datetime.fromtimestamp(start).isoformat(timespec="minutes"),
                   "end": dt.datetime.fromtimestamp(end).isoformat(timespec="minutes"),
                   "transcripts": len(set().union(*acc["kind_files"].values()))},
        "registry": {"sessions": n, "cost_usd": round(cost, 2), "cost_by_session": reg_by_sess},
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
        "first_request_parts": first.summary(),
        "every_request_parts": {**acc["every_parts"].summary(first.cpt()),
                                "by_kind": dict(acc["every_kind"].most_common()),
                                "unrecorded": acc["every_unrecorded"]},
        "waits": {"calls": acc["wait_calls"], "context": acc["wait_ctx"],
                  "share": round(acc["wait_ctx"] / ctx_all, 3) if ctx_all else None},
        "turn_mix": {k: {"turns": acc["mix"][k]["turns"], "context": acc["mix"][k]["context"],
                         "share": round(acc["mix"][k]["turns"] / turns_all, 3) if turns_all else None}
                     for k in MIX},
        "by_origin": {k: {**v, "cost_usd": round(v["cost_usd"], 2)} if k != "subagent" else dict(v)
                      for k, v in sorted(by_origin.items(), key=lambda x: (-x[1]["cost_usd"], -x[1]["context"]))},
        "by_session": sessions,
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
    table("by origin (registry cost; subagent row is its threads' tokens, their cost is in the parent's row)",
          out["by_origin"], ["sessions", "cost_usd", "turns", "context", "opus_turns"])
    f = out["first_turn_context"]
    print(f"first-turn context (main threads): median {f['median']}, p10 {f['p10']}, p90 {f['p90']} over {f['sessions']} sessions")
    r = out["first_request_parts"]
    if r["requests"]:
        print(f"first request by part ({r['requests']} sessions, {r['chars_per_token']} chars a token): "
              + ", ".join(f"{k} {v['mean_chars']:,} ({v['share']:.0%})" for k, v in r["parts"].items() if v["share"] >= 0.005))
        print("  largest tools (mean chars over the requests that carry them): "
              + ", ".join(f"{k} {v:,}" for k, v in r["tools_mean_chars"].items()))
    r = out["every_request_parts"]
    if r["requests"]:
        print(f"every request by part ({r['requests']:,} recorded: "
              + ", ".join(f"{k} {v:,}" for k, v in r["by_kind"].items()) + f"; {r['unrecorded']:,} unrecorded), share of their context: "
              + ", ".join(f"{k} {v['context_share']:.1%}" for k, v in r["parts"].items()
                          if v.get("context_share") is not None and v["context_share"] >= 0.001))
    wt = out["waits"]
    print(f"wait-style calls: {wt['calls']:,}, context {m(wt['context'])} ({wt['share']} of all)")
    print("turn mix: " + ", ".join(f"{k} {v['turns']:,} ({v['share']})" for k, v in out["turn_mix"].items()))
    print(f"compactions: {out['compactions']}\n")
    print(f"by session (top {a.top} of {len(sessions)} by {a.sort}; cost is the session's whole run, from the registry)")
    print("  " + "\t".join(["session", "project", "origin", "model", "cost_usd", "turns", "context", "inv/wait/write/reply",
                            "wait_share", "compactions", "first_turn", "merged_prs", "per_pr"]))
    for sid, v in list(sessions.items())[:a.top]:
        print("  " + "\t".join(str(x) for x in (
            sid[:8], v["project"], v["origin"], next(iter(v["models"]), "-"), "-" if v["cost_usd"] is None else f"{v['cost_usd']:,.2f}", v["turns"],
            m(v["context"]), "/".join(str(v["mix"][k]) for k in MIX), v["wait_share"], v["compactions"],
            v["first_turn_context"] or "-", len(v["merged_prs"]),
            "-" if v["cost_per_merged_pr"] is None else f"{v['cost_per_merged_pr']:,.2f}")))
    print()
    table("cache write by cause", out["cache_write_by_cause"], ["turns", "cache_write"])
    table("wakes after an idle gap over 1h, by trigger", out["idle_wakes_by_trigger"], ["wakes", "cache_write"])
    table("turns by trigger", out["turns_by_trigger"], ["turns", "context"])
    print("dream runs by night: " + (", ".join(f"{k} {v}" for k, v in out["dream_runs_by_night"].items()) or "none"))


if __name__ == "__main__":
    main()
