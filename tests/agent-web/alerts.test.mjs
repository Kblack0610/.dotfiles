// Unit tests for the Alerts tab (.local/src/agent-web/static/alerts.js), run by `node --test` from
// tests/unit/agent_web_queue.bats. The page's real scripts load into one vm context, as the
// browser loads them; only the DOM is a stub. What fires, its owner, the order and every count are
// hub_core::alerts, tested in Rust; this checks that the page draws them, each in its inner tab.
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
const alert = (what, o = {}) => ({ sev: "high", what, project: "", source: "sentinel", since: NOW - 3600, owner: "-", state: "no owner", about: "", place: "", action: "", evidence: "", ...o });
const col = (key) => ({ key, sort: null, next_sort: key, next_dir: "desc" });
const table = { q: "", state: "", sort: "", dir: "", total: 2, shown: 2, states: [{ name: "all", n: 2 }, { name: "trip", n: 1 }, { name: "error", n: 1 }, { name: "no owner", n: 1 }],
  columns: ["sev", "what", "project", "source", "since", "owner", "state"].map(col), facets: [] };
const watch = (name, state) => ({ name, state, severity: "normal", since: NOW - 60, lastrun: NOW - 30, lasttrip: null, place: "GitHub", what: "", action: "", evidence: "" });
const firing = [
  alert("playground-nightly", { project: "unity-core-playground", owner: "ar-9 fixing", state: "fixing", slug: "ar-9", about: "the nightly on main", place: "GitHub, unity", action: "read the run", evidence: "PlayMode 2 failed" }),
  alert("dream", { state: "error", sev: "normal" }),
];
const counts = { firing: 2, tripped: 1, errors: 1, no_owner: 0, fixes_open: 2, fixes_settled: 2, history: 1, history_older: 3, watches: 3, watches_tripped: 1, watches_error: 1, watches_ok: 1, watches_new: 0, alertmanager: 0, alertmanager_rules: 0 };
const strip = { firing: 2, fixes: 2, watches: 2 };
const data = (o = {}) => ({
  at: NOW, level: "red", health: [{ name: "ci", level: "ok" }, { name: "k3s", level: "red" }], components: [{ domain: "k3s", name: "nodes", level: "red" }],
  firing, rows: firing, table, fixes, history: [{ at: NOW - 600, actor: "sentinel", verb: "tripped", text: "Sentinel: playground-nightly", source: "agent-notify" }],
  watches: [watch("playground-nightly", "TRIP"), watch("dream", "ERROR"), watch("disk", "OK")], counts, strip, errors: [], ...o,
});
const show = (d, inner = "") => { run(`st.tab = 'alerts'; st.arg = ${JSON.stringify(inner)}`); Object.assign(alst, { data: d, err: null, sel: null }); for (const k of Object.keys(run("alertsOpen"))) delete run("alertsOpen")[k]; run("alst.render()"); return box.innerHTML; };

test("the sections come in the layout's order, each open: the strip, health pinned, then one inner tab each", () => {
  const h = show(data());
  const at = (k) => h.indexOf(`id="sec-${k}" data-k="${k}" open>`);
  const order = ["health", "firing", "fixes", "watches", "history"].map(at);
  assert.ok(order.every((i) => i >= 0), order.join(","));
  assert.deepEqual([...order].sort((a, b) => a - b), order);
  assert.ok(h.indexOf('class="seg fseg istrip"') < order[0], "the strip is the first row");
  assert.match(h, /cchip bad">FIRING<\/span>/);
  assert.match(h, /Firing <span class="muted">2: 1 trip, 1 error, 0 no owner, 0 alertmanager<\/span>/);
  // Health is pinned (in no group); Firing shows and the rest wait behind the strip.
  assert.ok(!/<div data-in="[a-z]+"( hidden)?><details class="sec-d" id="sec-health"/.test(h));
  assert.match(h, /<div data-in="firing"><details class="sec-d" id="sec-firing"/);
  for (const k of ["fixes", "watches", "history"]) assert.match(h, new RegExp(`<div data-in="${k}" hidden><details class="sec-d" id="sec-${k}"`));
  // Each label carries the reader's count, History none.
  assert.match(h, /data-itab="firing"[^>]*>Firing <span class="pill warn">2<\/span>/);
  assert.match(h, /data-itab="watches"[^>]*>Watches <span class="pill warn">2<\/span>/);
  assert.match(h, /data-itab="history"[^>]*>History<\/button>/);
});

test("an old #alerts/<section> link opens the inner tab holding it", () => {
  assert.equal(run("route('#alerts/watches').arg"), "watches");
  assert.equal(run("route('#alerts/history').arg"), "history");
  assert.equal(run("route('#alerts/firing').arg"), "firing");
  assert.equal(run("route('#infra/red').arg"), "firing");
  assert.equal(run("route('#infra/reds').arg"), "fixes");
  assert.equal(run("route('#alerts/health').arg"), "", "pinned: the first inner tab, Health on top");
  assert.equal(run("route('#infra/health').section"), "health", "a moved name still scrolls to it");
  const h = show(data(), "history");
  assert.match(h, /<div data-in="history"><details class="sec-d" id="sec-history"/);
  assert.match(h, /<div data-in="firing" hidden>/);
});

test("a rule firing in many places is one row with its count, and opens its alerts", () => {
  const page = (img, sev) => alert(`CVEs in ${img}`, { source: "alertmanager", sev, state: "firing", place: `image=${img}` });
  const rule = alert("HomelabCriticalVulnerability", { source: "alertmanager", state: "firing", action: "routed to ntfy", pages: [page("postgres", "high"), page("nginx", "normal")] });
  const h = show(data({ firing: [rule], rows: [rule] }));
  assert.match(h, /<td class="wrap">HomelabCriticalVulnerability <span class="muted">2 alerts<\/span><\/td>/);
  assert.ok(!h.includes("image=nginx"), "its alerts start closed");
  const tr = { dataset: { key: "alertmanager|HomelabCriticalVulnerability|" } };
  fire("click", { target: { closest: (sel) => (sel === "tr.jr" ? tr : null), dataset: {} } });
  const o = box.innerHTML;
  assert.match(o, /<b>What to do<\/b> routed to ntfy/);
  assert.ok(o.indexOf("image=postgres") < o.indexOf("image=nginx"), "the reader's order");
  assert.match(o, /<td class="wrap">CVEs in nginx<\/td><td class="wrap muted">image=nginx<\/td>/);
});

test("a firing row names its project, a fleet-wide one a dash, and the watches list carries it too", () => {
  const h = show(data({ watches: [{ ...watch("playground-nightly", "TRIP"), project: "unity-core-playground" }, watch("disk", "OK")] }));
  assert.match(h, /<td class="wrap">playground-nightly<\/td><td class="muted">unity-core-playground<\/td><td class="muted">sentinel<\/td>/);
  assert.match(h, /<td class="wrap">dream<\/td><td class="muted">-<\/td><td class="muted">sentinel<\/td>/);
  assert.match(h, /<td>playground-nightly<\/td><td class="bad">TRIP<\/td><td class="muted">normal<\/td><td class="muted">unity-core-playground<\/td>/);
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

test("watches open on their inner tab with nothing tripped, no count on the label, and a fold the reader set stays", () => {
  assert.match(show(data()), /Watches <span class="muted">3: 1 tripped, 1 error, 1 ok, 0 new<\/span>/);
  const quiet = data({ counts: { ...counts, watches_tripped: 0, watches_error: 0 }, strip: { ...strip, watches: 0 } });
  const h = show(quiet, "watches");
  assert.match(h, /id="sec-watches" data-k="watches" open>/);
  assert.match(h, /data-itab="watches"[^>]*>Watches<\/button>/);
  run("alertsOpen.watches = false; alst.render()");
  assert.match(box.innerHTML, /id="sec-watches" data-k="watches"><summary>/);
});

test("the watches needing a look are the table and the ok ones fold to their count", () => {
  const h = show(data(), "watches");
  const sec = h.slice(h.indexOf('id="sec-watches"'), h.indexOf('<div data-in="history"'));
  const fold = sec.indexOf('data-k="watches-ok"');
  assert.ok(fold > sec.indexOf("playground-nightly") && fold > sec.indexOf(">dream<"), sec);
  assert.ok(sec.indexOf(">disk<") > fold, "the ok watch sits in the fold");
  assert.match(sec, /<details class="sec-d" data-k="watches-ok"><summary class="muted fold">\+1 ok<\/summary>/);
  // Negative control: no ok watch, no fold.
  assert.doesNotMatch(show(data({ watches: [watch("dream", "ERROR")] }), "watches"), /watches-ok/);
});

test("an error body with no counts shows its error, not a blank tab", () => {
  const h = show({ rows: [], errors: ["join panicked"] });
  assert.match(h, /<div class="card err">join panicked<\/div>/);
});
