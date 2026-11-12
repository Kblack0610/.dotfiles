// Unit tests for the Log tab (.local/src/agent-web/static/log.js), run by `node --test` from
// tests/unit/agent_web_queue.bats. The page's real scripts load into one vm context, as the
// browser loads them; only the DOM is a stub. The grid and the project order are
// hub_core::boards::log_view, tested in Rust; this checks how they are drawn.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);

const el = () => new Proxy({}, {
  get: (t, k) => (k in t ? t[k] : k === "classList" ? { add() {}, remove() {}, toggle() {} } : k === "dataset" ? {} : k === "style" ? {} : () => el()),
  set: (t, k, v) => { t[k] = v; return true; },
});
const box = Object.assign(el(), { innerHTML: "", scrollTop: 0, querySelectorAll: () => [] });
const doc = { getElementById: (id) => (id === "log-day" ? box : el()), addEventListener() {}, querySelector: el, querySelectorAll: () => [], createElement: el, body: el() };
const ctx = vm.createContext({
  console,
  document: doc,
  window: { addEventListener() {} },
  URLSearchParams,
  fetch: async () => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => [] }),
});
// watch.js loads before log.js in the page; its target helper is all the Sessions table uses.
vm.runInContext('const shortTarget = (t) => String(t).split("/").pop();', ctx);
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "log.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });

const pr = (repo, project, number, at, o = {}) => ({ repo, project, number, title: `t${number}`, url: `https://x/${number}`, merged_at: at, area: "hub", group: "web", ...o });
// Six projects merged, so two of them share Other; dotfiles has ten rows, so two fold.
const merged = [
  ...Array.from({ length: 10 }, (_, i) => pr(".dotfiles", "dotfiles", 700 + i, `2026-11-05T09:${String(i).padStart(2, "0")}:00Z`)),
  pr("unity-core-playground", "unity-core-playground", 50, "2026-11-05T10:00:00Z"),
  pr("unity-core-playground", "unity-core-playground", 51, "2026-11-05T10:05:00Z"),
  pr("freqtrade_trading_attempt", "trader", 9, "2026-11-05T10:10:00Z"),
  pr(".dotfiles-private", "dotfiles-private", 3, "2026-11-05T11:00:00Z"),
  pr("unity-core", "unity-core", 4, "2026-11-05T11:00:00Z"),
  pr("home-config", "home-config", 5, "2026-11-05T11:30:00Z"),
];
const hourOf = (iso) => new Date(iso).getHours();
function grid(prs) {
  const hours = [...new Set(prs.map((m) => hourOf(m.merged_at)))].sort((a, b) => a - b);
  const by = {};
  for (const m of prs) (by[m.project] ||= hours.map(() => 0))[hours.indexOf(hourOf(m.merged_at))]++;
  const rows = Object.entries(by).map(([project, counts]) => ({ project, counts, total: counts.reduce((a, b) => a + b, 0) }))
    .sort((a, b) => b.total - a.total || a.project.localeCompare(b.project));
  return { hours, rows, total: hours.map((_, i) => rows.reduce((a, r) => a + r.counts[i], 0)) };
}
const rec = (o = {}) => {
  const g = grid(merged);
  return { date: "2026-11-05", live: true, merged, open: [{ ...pr("bnb-platform", "bnb-platform", 77, null), created_at: "2026-11-05T08:00:00Z", ci: "SUCCESS" }],
    usage: [], waiting: {}, hours: g, projects: [...g.rows.map((r) => r.project), "bnb-platform"], ...o };
};
function draw(r) {
  ctx.input = { r };
  return vm.runInContext(`lst.rec = input.r; lst.hist = []; lst.open = {}; renderLog(); $("log-day").innerHTML`, ctx);
}
const between = (html, a, b) => html.slice(html.indexOf(a), b ? html.indexOf(b) : undefined);

test("the hour chart stacks each hour by project, top four by colour, the rest as Other", () => {
  const html = draw(rec());
  const legend = between(html, "Merged by hour");
  assert.deepEqual([...legend.split("</h3>")[0].matchAll(/<\/i>([^<]*)<\/span>/g)].map((m) => m[1]), ["dotfiles", "unity-core-playground", "dotfiles-private", "home-config", "Other"]);
  assert.doesNotMatch(html, /Spend by project|Spend per day/, "spend is on Costs");
  assert.match(html, /<a class="tile" href="#costs\?by=project&w=24h"/, "and the Log links there");
  const h = hourOf("2026-11-05T11:00:00Z");
  const tip = legend.match(new RegExp(`data-key="h${h}" data-tip="([^"]*)"`))[1];
  assert.equal(tip, `${String(h).padStart(2, "0")}:00 3 merged\ndotfiles-private 1\nhome-config 1\nunity-core 1`);
});

test("the lists of merged and open PRs are the Work table's now", () => {
  const html = draw(rec());
  assert.doesNotMatch(html, /<h2 class="sec">(Merged|Open PRs)/);
  assert.doesNotMatch(html, /data-proj|t709/);
});

test("a day with nothing merged has no hour legend", () => {
  const html = draw(rec({ merged: [], hours: { hours: [], rows: [], total: [] }, projects: ["bnb-platform"] }));
  assert.doesNotMatch(between(html, "Merged by hour").split("</h3>")[0], /class="legend"/);
});

test("the day shown is Work's wday when that is a date, and the live day for a window", () => {
  const day = (q) => { ctx.q = q; return vm.runInContext("st.views.log = q; urlDay()", ctx); };
  assert.equal(day("wday=2026-11-03&ws=done"), "2026-11-03");
  for (const q of ["", "wday=today", "wday=30d", "wday=all"]) assert.equal(day(q), null);
});

test("what waits on you is a count linking to Home, not a second list of it", () => {
  const html = draw(rec({ waiting: { asks: [{ project: "p", question: "Ship it?" }], needs: [{ who: "w", reason: "r", idle_min: 3 }] } }));
  assert.match(html, /<a href="#" data-asks><span class="chip sm"[^>]*>2 waiting on you<\/span> answer on Home<\/a>/);
  assert.doesNotMatch(html, /Ship it/);
  assert.doesNotMatch(draw(rec()), /waiting on you/);
});

test("a session row leads with what its plan is called, and a phone sees phase, PRs and cost", () => {
  const bench = { sessions: [
    { target: "lab/unity-core-playground-agent-21:1", plan: "ucp-145", name: "ucp-145: first premium sets", phase: "5/6", prs_merged: 2, cost_usd: 3 },
    { target: "hub/dotfiles:4", phase: "1/1" },
  ] };
  const html = between(draw(rec({ bench })), "Sessions");
  assert.match(draw(rec({ bench })), /<h2 class="sec">Sessions <span class="n">2<\/span><\/h2>/);
  const heads = [...html.matchAll(/<th([^>]*)>([^<]*)<\/th>/g)].map((m) => [m[2], (m[1].match(/data-role="(\w+)"/) || [])[1] || "rest"]);
  assert.deepEqual(heads.filter(([, r]) => r !== "rest").map(([l, r]) => `${l}:${r}`), ["what:lead", "phase:glance", "PRs:glance", "cost:glance"]);
  const rows = [...html.matchAll(/<tr><td[^>]*>([^<]*)<\/td>/g)].map((m) => m[1]);
  assert.deepEqual(rows, ["ucp-145: first premium sets", "dotfiles:4"], "a session with no plan says its target");
  assert.match(html, /<td class="muted" title="lab\/unity-core-playground-agent-21:1">unity-..-playground-agent-21:1<\/td>/);
});
