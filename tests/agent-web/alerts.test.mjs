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
const counts = { firing: 2, tripped: 1, errors: 1, no_owner: 0, fixes_open: 2, fixes_settled: 2, history: 1, history_older: 3, watches: 3, watches_tripped: 1, watches_error: 1, watches_ok: 1, watches_new: 0, alertmanager: 0, alertmanager_alerts: 0 };
const strip = { firing: 2, fixes: 2, watches: 2 };
// Watches' and History's summaries (hub_core::table over Watch and Action), each table's own.
const watchesTable = { q: "", state: "", sort: "", dir: "", total: 3, shown: 3,
  states: [{ name: "all", n: 3 }, { name: "trip", n: 1, tone: "bad" }, { name: "error", n: 1, tone: "bad" }, { name: "new", n: 0 }, { name: "ok", n: 1, tone: "ok" }],
  columns: ["name", "state", "severity", "project", "since", "lastrun", "place"].map(col), facets: [] };
const historyTable = { q: "", state: "", sort: "", dir: "", total: 1, shown: 1, states: [{ name: "all", n: 1 }, { name: "loud", n: 0 }, { name: "failed", n: 0 }],
  columns: ["when", "actor", "verb", "prio", "source", "text"].map(col), facets: [] };
const data = (o = {}) => ({
  at: NOW, level: "red", health: [{ name: "ci", level: "ok" }, { name: "k3s", level: "red" }], components: [{ domain: "k3s", name: "nodes", level: "red" }],
  firing, rows: firing, table, fixes, history: [{ at: NOW - 600, actor: "sentinel", verb: "tripped", text: "Sentinel: playground-nightly", source: "agent-notify" }],
  watches: [watch("playground-nightly", "TRIP"), watch("dream", "ERROR"), watch("disk", "OK")], counts, strip, errors: [],
  watches_table: watchesTable, history_table: historyTable, ...o,
});
const show = (d, inner = "") => { run(`st.tab = 'alerts'; st.arg = ${JSON.stringify(inner)}`); Object.assign(alst, { data: d, err: null, sel: null }); for (const k of Object.keys(run("alertsOpen"))) delete run("alertsOpen")[k]; run("alst.render()"); return box.innerHTML; };

test("the sections come in the layout's order, each open: the strip, then one inner tab each, health with firing", () => {
  const h = show(data());
  const at = (k) => h.indexOf(`id="sec-${k}" data-k="${k}" open>`);
  const order = ["health", "firing", "fixes", "watches", "history"].map(at);
  assert.ok(order.every((i) => i >= 0), order.join(","));
  assert.deepEqual([...order].sort((a, b) => a - b), order);
  assert.ok(h.indexOf('class="seg fseg istrip"') < order[0], "the strip is the first row");
  assert.match(h, /cchip bad">FIRING<\/span>/);
  // Each fold's head is its title and count, toned by its own level; the state chips break the firing count down.
  assert.match(h, /<summary><h2 class="sec bad">Firing <span class="n">2<\/span><\/h2><\/summary>/);
  assert.match(h, /data-ts="trip"[^>]*><span class="tl">TRIP<\/span><span class="tv">1<\/span>/);
  assert.match(h, /<span class="cchip bad">FIRING<\/span><\/span><\/div>/, "the tab's head row is the level chip alone");
  assert.match(show(data({ level: "ok" })), /<summary><h2 class="sec">Firing <span class="n">2<\/span><\/h2>/);
  // Health and Firing show; the rest wait behind the strip.
  assert.match(h, /<div data-in="firing"><details class="sec-d" id="sec-health"/);
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
  assert.equal(run("route('#alerts/health').arg"), "firing", "Health opens with Firing");
  assert.equal(run("route('#infra/health').section"), "health", "a moved name still scrolls to it");
  const h = show(data(), "history");
  assert.match(h, /<div data-in="history"><details class="sec-d" id="sec-history"/);
  assert.match(h, /<div data-in="firing" hidden><details class="sec-d" id="sec-health"/);
});

test("a rule firing in many places is one row with its count, and opens its alerts with their own text", () => {
  const page = (img, sev) => alert(`CVEs in ${img}`, { source: "alertmanager", sev, state: "firing", place: `image=${img}`, about: `${img} has 3`, action: "routed to ntfy" });
  const rule = alert("HomelabCriticalVulnerability", { source: "alertmanager", state: "firing", about: "", action: "routed to ntfy", pages: [page("postgres", "high"), page("nginx", "normal")] });
  const c = { ...counts, firing: 1, alertmanager: 1, alertmanager_alerts: 2 };
  const h = show(data({ firing: [rule], rows: [rule], counts: c }));
  assert.match(h, /<td class="wrap">HomelabCriticalVulnerability <span class="muted">\(2 alerts\)<\/span><\/td>/);
  assert.ok(!h.includes("image=nginx"), "its alerts start closed");
  const tr = { dataset: { key: "alertmanager|HomelabCriticalVulnerability|" } };
  fire("click", { target: { closest: (sel) => (sel === "tr.jr" ? tr : null), dataset: {} } });
  const o = box.innerHTML;
  assert.match(o, /<b>What to do<\/b> routed to ntfy/);
  assert.ok(o.indexOf("image=postgres") < o.indexOf("image=nginx"), "the reader's order");
  assert.match(o, /<td class="wrap">CVEs in nginx<div class="muted">nginx has 3<\/div><\/td><td class="wrap muted">image=nginx<\/td>/);
  assert.ok(!o.includes("What it checks"), "the descriptions differ: none on the row");
  assert.equal(o.split("routed to ntfy").length, 2, "the shared action once, on the row");
});

test("a rule firing in one place keeps its row and names its alert's summary", () => {
  const one = alert("CVEs in nginx", { source: "alertmanager", state: "firing", place: "image=nginx", about: "nginx has 3" });
  const rule = alert("HomelabCriticalVulnerability", { source: "alertmanager", state: "firing", about: "nginx has 3", pages: [one] });
  const h = show(data({ firing: [rule], rows: [rule], counts: { ...counts, firing: 1, alertmanager: 1, alertmanager_alerts: 1 } }));
  assert.doesNotMatch(h, /\(1 alerts?\)/, "rows and alerts agree: no second count");
  assert.match(h, /<td class="wrap">HomelabCriticalVulnerability <span class="muted">CVEs in nginx<\/span><\/td>/);
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
  assert.match(h, /<h2 class="sec bad">Health <span class="n">2<\/span><\/h2>/, "a red domain tones the head");
  assert.match(show(data({ health: [{ name: "ci", level: "ok" }] })), /<h2 class="sec">Health <span class="n">1<\/span><\/h2>/);
  const read = new RegExp(`<div class="cline"><b>read</b> ${run(`clock(${NOW} * 1e3)`)}</div></div>`);
  assert.match(h, read, "when it was read is a fact in Health's box");
  assert.match(h, /<div><span class="cchip bad">RED<\/span> k3s\/nodes<\/div>/);
  const none = show(data({ health: [] }));
  assert.match(none, /No health: Prometheus did not answer\./);
  assert.match(none, /<h2 class="sec">Health<\/h2>/);
  assert.match(none, read, "the read time stays with no health");
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
  assert.match(h, /<h2 class="sec">Fixes <span class="n">2<\/span><\/h2>/);
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
  assert.match(failed, /<h2 class="sec bad">Fixes<\/h2><\/summary><div class="panel down">Could not read the fixes\.<\/div>/);
  assert.ok(!failed.includes("No red was queued"));
  const n = run("LOG_ROWS") + 2;
  const many = run(`alertsFixes(${JSON.stringify(data({ fixes: { open: Array.from({ length: n }, (_, i) => fix(`ar-${i}`, "queued")), settled: [], summary: `${n} open` } }))})`);
  assert.equal(many.match(/QUEUED/g).length, n - 2);
  assert.match(many, /<div class="muted more">\+2 more<\/div>/);
});

test("history counts the older pages and sends them to Log", () => {
  const h = show(data());
  assert.match(h, /<h2 class="sec">History <span class="n">4<\/span><\/h2>/);
  assert.match(h, /\+3 older on <a href="#log\/actions">Log<\/a>/);
});

test("watches open on their inner tab with nothing tripped, no count on the label, and a fold the reader set stays", () => {
  // The head is the title and count; the tiles say how many tripped and failed, so no line repeats it.
  const h0 = show(data());
  assert.match(h0, /<h2 class="sec warn">Watches <span class="n">3<\/span><\/h2><\/summary><div data-tbl="w">/);
  assert.doesNotMatch(h0, /1 tripped, 1 error/);
  const quiet = data({ counts: { ...counts, watches_tripped: 0, watches_error: 0 }, strip: { ...strip, watches: 0 } });
  const h = show(quiet, "watches");
  assert.match(h, /id="sec-watches" data-k="watches" open>/);
  assert.match(h, /data-itab="watches"[^>]*>Watches<\/button>/);
  run("alertsOpen.watches = false; alst.render()");
  assert.match(box.innerHTML, /id="sec-watches" data-k="watches"><summary>/);
});

// One inner tab's section of the page.
const section = (h, k, next) => h.slice(h.indexOf(`id="sec-${k}"`), next ? h.indexOf(`<div data-in="${next}"`) : undefined);

test("watches are a shared table: state tiles in their hue, a search bar on the rows, every watch in the reader's order", () => {
  const sec = section(show(data(), "watches"), "watches", "history");
  assert.match(sec, /<div class="tiles stiles"><button class="tile t-bad" data-ts="trip"><span class="tl">TRIP<\/span><span class="tv">1<\/span><\/button>/);
  assert.match(sec, /<button class="tile t-ok" data-ts="ok"><span class="tl">OK<\/span><span class="tv">1<\/span>/);
  assert.match(sec, /<button class="tile zero" data-ts="new">/, "a state no watch is in is plain");
  assert.match(sec, /<div class="tqbar"><input id="al-w-q" data-tsearch/);
  assert.ok(sec.indexOf("tqbar") < sec.indexOf("<table"), "the bar sits on top of the table");
  const at = ["playground-nightly", "dream", "disk"].map((n) => sec.indexOf(`<td>${n}</td>`));
  assert.ok(at.every((i) => i >= 0) && at[0] < at[1] && at[1] < at[2], at.join(","));
  // The ok fold is gone: the OK tile filters to them.
  assert.doesNotMatch(sec, /watches-ok|\+1 ok/);
  const none = section(show(data({ watches: [], watches_table: { ...watchesTable, total: 3, shown: 0 } }), "watches"), "watches", "history");
  assert.match(none, /No watch matches\./);
  assert.match(section(show(data({ watches: [], watches_table: { ...watchesTable, total: 0, shown: 0 } }), "watches"), "watches", "history"), /No watch defined\./);
});

test("history is a shared table with its own search bar, and still sends the older pages to Log", () => {
  const sec = section(show(data(), "history"), "history");
  assert.match(sec, /<div data-tbl="h">/);
  assert.match(sec, /<div class="tqbar"><input id="al-h-q" data-tsearch/);
  assert.match(sec, /<td class="wrap">Sentinel: playground-nightly<\/td>/);
  assert.match(sec, /\+3 older on <a href="#log\/actions">Log<\/a>/);
  assert.match(section(show(data({ history: [], history_table: { ...historyTable, total: 1, shown: 0 } }), "history"), "history"), /No page matches\./);
});

test("a search in Watches or History asks the server with that table's own keys, beside the others", async () => {
  const asked = [];
  ctx.fetch = async (url) => { asked.push(url); return { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => data() }; };
  show(data(), "watches");
  run("st.views.alerts = 's=error'");
  const box = (tbl, v) => ({ type: "input", target: { value: v, dataset: { tsearch: "" }, closest: (sel) => (sel === "[data-tbl]" ? { dataset: { tbl } } : null) } });
  fire("input", box("w", "dotfiles"));
  await new Promise((r) => setTimeout(r, 0));
  fire("input", box("h", "tripped"));
  await new Promise((r) => setTimeout(r, 0));
  assert.deepEqual(asked, ["/api/alerts?s=error&wq=dotfiles", "/api/alerts?s=error&wq=dotfiles&hq=tripped"]);
  assert.equal(run("st.views.alerts"), "s=error&wq=dotfiles&hq=tripped", "a filtered view is a link");
  run("st.views.alerts = ''");
});

test("an error body with no counts shows its error, not a blank tab", () => {
  const h = show({ rows: [], errors: ["join panicked"] });
  assert.match(h, /<div class="card err">join panicked<\/div>/);
});
