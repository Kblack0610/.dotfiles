// Unit tests for the Alerts tab (.local/src/agent-web/static/alerts.js), run by `node --test` from
// tests/unit/agent_web_queue.bats. The page's real scripts load into one vm context, as the
// browser loads them; only the DOM is a stub. What fires, its owner, the order and every count are
// hub_core::alerts, tested in Rust; this checks that the page draws them and folds as it says.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);

const el = () => new Proxy({}, {
  get: (t, k) => (k in t ? t[k] : k === "classList" ? { add() {}, remove() {}, toggle() {} } : k === "dataset" ? {} : k === "style" ? {} : (() => el())),
  set: (t, k, v) => { t[k] = v; return true; },
});
const on = {};
const box = Object.assign(el(), { innerHTML: "", scrollTop: 0, querySelectorAll: () => [], addEventListener: (ev, f) => { (on[ev] ||= []).push(f); } });
const fire = (ev, e) => (on[ev] || []).forEach((f) => f(e));
const doc = { getElementById: (id) => (id === "alerts" ? box : el()), addEventListener() {}, querySelector: el, querySelectorAll: () => [], createElement: el, body: el(), activeElement: null };
const ctx = vm.createContext({
  console,
  document: doc,
  window: { addEventListener() {} },
  URLSearchParams,
  setInterval: () => 0,
  clearInterval() {},
  location: { pathname: "/", hash: "" },
  history: { replaceState() {} },
  fetch: async () => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => ({}), text: async () => "" }),
});
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "table.js", "alerts.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
const run = (src) => vm.runInContext(src, ctx);
const alst = run("alst");

const NOW = Math.floor(Date.now() / 1e3);
const fix = (slug, outcome, o = {}) => ({ slug, red: `watch ${slug}`, outcome, queued: new Date(Date.now() - 3 * 3600e3).toISOString(), pr: null, pr_url: null, ...o });
const fixes = {
  open: [fix("ar-3", "came back", { pr: "Kblack0610/.dotfiles#1170", pr_url: "https://github.com/Kblack0610/.dotfiles/pull/1170" }), fix("ar-2", "queued", { pr: "986" })],
  settled: [fix("ar-1", "fixed"), fix("ar-4", "cancelled")],
  summary: "2 open: 1 came back, 1 queued | 1 fixed, 1 cancelled in 7d, fix p50 34m",
};
const alert = (what, o = {}) => ({ sev: "high", what, source: "sentinel", since: NOW - 3600, owner: "-", state: "no owner", about: "", place: "", action: "", evidence: "", ...o });
const col = (key) => ({ key, sort: null, next_sort: key, next_dir: "desc" });
const table = { q: "", state: "", sort: "", dir: "", total: 2, shown: 2, states: [{ name: "all", n: 2 }, { name: "trip", n: 1 }, { name: "error", n: 1 }, { name: "no owner", n: 1 }],
  columns: ["sev", "what", "source", "since", "owner", "state"].map(col), facets: [] };
const watch = (name, state) => ({ name, state, severity: "normal", since: NOW - 60, lastrun: NOW - 30, lasttrip: null, place: "GitHub", what: "", action: "", evidence: "" });
const firing = [
  alert("playground-nightly", { owner: "ar-9 fixing", state: "fixing", slug: "ar-9", about: "the nightly on main", place: "GitHub, unity", action: "read the run", evidence: "PlayMode 2 failed" }),
  alert("dream", { state: "error", sev: "normal" }),
];
const counts = { firing: 2, tripped: 1, errors: 1, no_owner: 0, fixes_open: 2, fixes_settled: 2, history: 1, history_older: 3, watches: 3, watches_tripped: 1, watches_error: 1, watches_ok: 1, watches_new: 0, alertmanager: 0 };
const data = (o = {}) => ({
  at: NOW, level: "red", health: [{ name: "ci", level: "ok" }, { name: "k3s", level: "red" }], components: [{ domain: "k3s", name: "nodes", level: "red" }],
  firing, rows: firing, table, fixes, history: [{ at: NOW - 600, actor: "sentinel", verb: "tripped", text: "Sentinel: playground-nightly", source: "agent-notify" }],
  watches: [watch("playground-nightly", "TRIP"), watch("dream", "ERROR"), watch("disk", "OK")], watches_folded: false, counts, errors: [], ...o,
});
const show = (d) => { run("st.tab = 'alerts'"); Object.assign(alst, { data: d, err: null, sel: null }); for (const k of Object.keys(run("alertsOpen"))) delete run("alertsOpen")[k]; run("alst.render()"); return box.innerHTML; };

test("the sections come in the layout's order: health, firing, fixes, history, watches, each open", () => {
  const h = show(data());
  const at = (k) => h.indexOf(`id="sec-${k}" data-k="${k}" open>`);
  const order = ["health", "firing", "fixes", "history", "watches"].map(at);
  assert.ok(order.every((i) => i >= 0), order.join(","));
  assert.deepEqual([...order].sort((a, b) => a - b), order);
  assert.match(h, /cchip bad">FIRING<\/span>/);
  assert.match(h, /Firing <span class="muted">2: 1 trip, 1 error, 0 no owner, 0 alertmanager<\/span>/);
});

test("health names every domain, the red first, then each component that is not green", () => {
  const h = show(data());
  assert.ok(h.indexOf("k3s RED") < h.indexOf("ci OK"), h);
  assert.match(h, /Health <span class="muted">1 not green of 2<\/span>/);
  assert.match(h, /<div><span class="cchip bad">RED<\/span> k3s\/nodes<\/div>/);
  assert.match(show(data({ health: [] })), /No health: Prometheus did not answer\./);
});

test("a firing row shows its owner as a link to its queue item, and opens what the watch says", () => {
  show(data());
  assert.match(box.innerHTML, /<a href="#queue\?q=ar-9">ar-9 fixing<\/a>/);
  assert.match(box.innerHTML, /<span class="cchip bad">error<\/span>/);
  assert.ok(!box.innerHTML.includes("PlayMode 2 failed"), "the detail starts closed");
  const tr = { dataset: { key: "sentinel|playground-nightly|GitHub, unity" } };
  fire("click", { target: { closest: (sel) => (sel === "tr.jr" ? tr : null), dataset: {} } });
  const h = box.innerHTML;
  assert.match(h, /<b>What it checks<\/b> the nightly on main/);
  assert.match(h, /<b>Where<\/b> GitHub, unity/);
  assert.match(h, /<b>What to do<\/b> read the run/);
  assert.match(h, /<pre class="joblog">PlayMode 2 failed<\/pre>/);
});

test("a source that failed is an error line, and nothing firing says so", () => {
  const h = show(data({ level: "nodata", firing: [], rows: [], table: { ...table, total: 0, shown: 0 }, errors: ["watches: no such dir"] }));
  assert.match(h, /<div class="panel down"><div>watches: no such dir<\/div><\/div>/);
  assert.match(h, /Nothing is firing\./);
  assert.match(h, /cchip ">NO DATA<\/span>/);
});

test("fixes: open rows with outcome, red, slug, PR and age; the settled fold to a count", () => {
  const h = run(`alertsFixes(${JSON.stringify(data())})`);
  assert.match(h, /Fixes <span class="muted">2 open: 1 came back, 1 queued \| 1 fixed, 1 cancelled in 7d, fix p50 34m<\/span>/);
  const [openPart, foldPart] = h.split('<details class="sec-d" data-k="fixes-settled">');
  assert.ok(openPart.indexOf("CAME BACK") < openPart.indexOf("QUEUED"), "the server's order is kept");
  assert.match(openPart, /<a href="https:\/\/github.com\/Kblack0610\/.dotfiles\/pull\/1170"[^>]*>PR Kblack0610\/.dotfiles#1170<\/a>/);
  assert.match(openPart, /<span class="by">PR 986<\/span>/, "a PR with no repo is text, not a link");
  assert.match(openPart, /<span class="by">3h<\/span>/);
  assert.match(foldPart, /<summary class="muted fold">\+2 settled<\/summary>/);
  assert.ok(!openPart.includes("FIXED") && foldPart.includes("FIXED"));
});

test("fixes: a failed read says so, never an empty list, and the open ones cap at LOG_ROWS", () => {
  const failed = run(`alertsFixes(${JSON.stringify(data({ fixes: { open: [], settled: [], summary: "" }, errors: ["fleet-bench reds: exit 1"] }))})`);
  assert.match(failed, /Fixes <span class="muted">read failed<\/span>/);
  assert.ok(!failed.includes("No red was queued"));
  const n = run("LOG_ROWS") + 2;
  const many = run(`alertsFixes(${JSON.stringify(data({ fixes: { open: Array.from({ length: n }, (_, i) => fix(`ar-${i}`, "queued")), settled: [], summary: `${n} open` } }))})`);
  assert.equal(many.match(/QUEUED/g).length, n - 2);
  assert.match(many, /<div class="muted more">\+2 more<\/div>/);
});

test("history counts the older pages and sends them to Log", () => {
  const h = show(data());
  assert.match(h, /History <span class="muted">4 pages in 7 days<\/span>/);
  assert.match(h, /\+3 older on <a href="#log\/actions">Log<\/a>/);
});

test("watches fold to their count when none is tripped, and a fold the reader set stays", () => {
  assert.match(show(data()), /Watches <span class="muted">3: 1 tripped, 1 error, 1 ok, 0 new<\/span>/);
  const quiet = data({ watches_folded: true, counts: { ...counts, watches_tripped: 0, watches_error: 0 } });
  assert.match(show(quiet), /id="sec-watches" data-k="watches"><summary>/);
  run("alertsOpen.watches = true; alst.render()");
  assert.match(box.innerHTML, /id="sec-watches" data-k="watches" open>/);
});

test("an error body with no counts shows its error, not a blank tab", () => {
  const h = show({ rows: [], errors: ["join panicked"] });
  assert.match(h, /<div class="card err">join panicked<\/div>/);
});
