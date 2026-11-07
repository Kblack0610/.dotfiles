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
  fetch: async () => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => [] }),
});
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
function draw(r, proj = null) {
  ctx.input = { r, proj };
  return vm.runInContext(`lst.rec = input.r; lst.hist = []; lst.proj = input.proj; lst.open = {}; renderLog(); $("log-day").innerHTML`, ctx);
}
const between = (html, a, b) => html.slice(html.indexOf(a), b ? html.indexOf(b) : undefined);

test("the hour chart stacks each hour by project, top four by colour, the rest as Other", () => {
  const html = draw(rec());
  const legend = between(html, "Merged by hour", '<h2 class="sec">Merged');
  assert.deepEqual([...legend.matchAll(/data-proj="([^"]*)"/g)].map((m) => m[1]), ["dotfiles", "unity-core-playground", "dotfiles-private", "home-config", "\u0000other"]);
  assert.match(legend, />Other<\/button>/);
  assert.doesNotMatch(html, /Spend by project|Spend per day/, "spend is on Costs");
  assert.match(html, /<a class="tile" href="#costs\?by=project&w=24h"/, "and the Log links there");
  const h = hourOf("2026-11-05T11:00:00Z");
  const tip = legend.match(new RegExp(`data-key="h${h}" data-tip="([^"]*)"`))[1];
  assert.equal(tip, `${String(h).padStart(2, "0")}:00 3 merged\ndotfiles-private 1\nhome-config 1\nunity-core 1`);
});

test("the merged list groups by project, busiest first, folds past eight rows and keeps the area label", () => {
  const html = draw(rec());
  const list = between(html, '<h2 class="sec">Merged', '<h2 class="sec">Open PRs');
  assert.deepEqual([...list.matchAll(/<details class="panel area" data-k="m:([^"]*)"/g)].map((m) => m[1]), ["dotfiles", "unity-core-playground", "dotfiles-private", "home-config", "trader", "unity-core"]);
  const dot = between(list, 'data-k="m:dotfiles"', 'data-k="m:unity-core-playground"');
  assert.equal((dot.match(/<div class="pr">/g) || []).length, 10);
  assert.match(dot, /<details class="cfold" data-k="m:dotfiles\+"><summary>\+2 more<\/summary>/);
  assert.match(dot, />#709<\/a><span class="lbl" title="hub \/ web">hub \/ web<\/span>/, "a repo that is the project shows its number alone, newest first");
  assert.match(list, />freqtrade_trading_attempt#9<\/a>/, "a repo named apart from its project keeps its name");
  assert.match(between(html, '<h2 class="sec">Open PRs'), /data-k="o:bnb-platform".*bnb-platform <span class="muted">1<\/span>/s);
});

test("a legend pick shows one project's group in both lists; Other is every project past the slots", () => {
  const one = draw(rec(), "unity-core-playground");
  assert.deepEqual([...one.matchAll(/<details class="panel area" data-k="(\w):([^":]*)(?::only)?"/g)].map((m) => m[1] + m[2]), ["munity-core-playground"]);
  assert.match(one, /class="lg on" data-proj="unity-core-playground"/);
  assert.match(one, /unity-core-playground only, <a href="#" data-proj="unity-core-playground">show all<\/a>/);
  assert.match(one, /<h2 class="sec">Open PRs.*Nothing open\./s);
  const other = draw(rec(), "\u0000other");
  assert.deepEqual([...other.matchAll(/data-k="(\w):([^"+:]*)(?::only)?"/g)].map((m) => m[1] + m[2]), ["mtrader", "munity-core", "obnb-platform"]);
});

test("a day with nothing merged has no legend and says so", () => {
  const html = draw(rec({ merged: [], hours: { hours: [], rows: [], total: [] }, projects: ["bnb-platform"] }));
  assert.doesNotMatch(between(html, "Merged by hour", '<h2 class="sec">Merged'), /data-proj/);
  assert.match(html, /Nothing merged\./);
});

test("a busy day starts each group folded, and a legend pick opens the picked group", () => {
  const busy = [...merged, ...Array.from({ length: 20 }, (_, i) => pr(".dotfiles", "dotfiles", 800 + i, `2026-11-05T12:${String(i).padStart(2, "0")}:00Z`))];
  const g = grid(busy), r = rec({ merged: busy, hours: g, projects: g.rows.map((x) => x.project) });
  assert.match(draw(r), /<details class="panel area" data-k="m:trader"><summary>/);
  assert.match(draw(r, "\u0000other"), /<details class="panel area" data-k="m:trader:only" open><summary>/);
});

test("what waits on you is a count linking to Home, not a second list of it", () => {
  const html = draw(rec({ waiting: { asks: [{ project: "p", question: "Ship it?" }], needs: [{ who: "w", reason: "r", idle_min: 3 }] } }));
  assert.match(html, /<a href="#" data-asks><span class="chip sm"[^>]*>2 waiting on you<\/span> answer on Home<\/a>/);
  assert.doesNotMatch(html, /Ship it/);
  assert.doesNotMatch(draw(rec()), /waiting on you/);
});
