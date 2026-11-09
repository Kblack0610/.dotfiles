// Unit tests for tblTab (.local/src/agent-web/static/table.js), the skeleton every tab on the
// shared table draws with, run by `node --test` from tests/unit/agent_web_queue.bats. The page's
// real scripts load into one vm context with a stub DOM; the tabs' own tests check what each draws,
// this checks what they all share: the placeholder, the repaint around a control in use, the more
// button, the scroll a whole draw keeps, and which of two tables in one block an event belongs to.
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
const part = () => Object.assign(el(), { innerHTML: "", scrollTop: 0, querySelectorAll: () => [] });
const parts = {};
const box = (id) => (parts[id] ||= part());
box("tt").addEventListener = (ev, f) => { (on[ev] ||= []).push(f); };
const fire = (ev, e) => (on[ev] || []).forEach((f) => f(e));
const doc = { getElementById: (id) => (id.startsWith("t") ? box(id) : el()), addEventListener() {}, querySelector: el, querySelectorAll: () => [], createElement: el, body: el(), activeElement: null };
const asked = [];
let body = {};
const ctx = vm.createContext({
  console,
  document: doc,
  window: { addEventListener() {} },
  URLSearchParams,
  setInterval: () => 0,
  clearInterval() {},
  location: { pathname: "/", hash: "" },
  history: { url: "", replaceState(a, b, u) { this.url = u; } },
  fetch: async (url) => { asked.push(url); return { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => body, text: async () => "" }; },
});
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "table.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
const run = (src) => vm.runInContext(src, ctx);
const tick = () => new Promise((r) => setImmediate(r));

const summary = { q: "", state: "", sort: "", dir: "", total: 3, shown: 3, states: [{ name: "all", n: 3 }], columns: [], facets: [] };
// Two tables drawn into one element, as Home's are: the second's keys carry the prefix "n" and its
// block a data-tbl="n". The scroller is reset by every whole draw, as replacing innerHTML resets
// the scrolling parent in a browser.
run(`
  st.tab = "tt";
  var one = tblTab({ tab: "tt", id: "tt", api: "/api/one", hint: "", scroller: "tscroll", body: (t) => "rows " + t.data.rows.slice(0, t.all ? undefined : 1).join(",") + tblMore(t.all ? 0 : t.data.rows.length - 1),
    draw: (html) => { $("tt").innerHTML = html; $("tscroll").scrollTop = 0; } });
  var two = tblTab({ tab: "tt", id: "tn", el: "tt", pre: "n", refresh: () => {}, table: () => one.data?.table, body: () => "second", render: () => {} });
`);
const target = (data, tbl = "") => ({ dataset: data, closest: (sel) => (sel === "[data-tbl]" ? (tbl ? { dataset: { tbl } } : null) : sel === "[data-tsort]" && "tsort" in data ? { dataset: data } : null) });

test("no answer yet waits, a failed first read says why as an error", async () => {
  run(`one.data = null; one.err = null; one.render()`);
  assert.equal(box("tt").innerHTML, `<div class="empty">Loading...</div>`);
  run(`one.err = "502 bad gateway"; one.render()`);
  assert.equal(box("tt").innerHTML, `<div class="card err">502 bad gateway</div>`);
});

test("a whole draw keeps the scroller where the reader left it", () => {
  run(`one.err = null; one.data = { table: input, rows: ["a", "b", "c"] }`.replace("input", JSON.stringify(summary)));
  box("tscroll").scrollTop = 40;
  run(`one.render()`);
  assert.match(box("tt").innerHTML, /rows a<button class="btn sm" data-all="1">\+2 older/);
  assert.equal(box("tscroll").scrollTop, 40);
});

test("the more button lifts the cap, and a view change puts it back", async () => {
  fire("click", { type: "click", target: target({ all: "1" }) });
  assert.equal(run("one.all"), true);
  assert.match(box("tt").innerHTML, /rows a,b,c/);
  body = { table: summary, rows: ["a", "b", "c"] };
  fire("click", { type: "click", target: target({ tsort: "name", tdir: "asc" }) });
  await tick();
  assert.equal(run("one.all"), false);
  assert.equal(asked.at(-1), "/api/one?sort=name&dir=asc");
});

test("an event in the second table's block moves only that table's keys", () => {
  run(`st.views.tt = ""; two.all = false`);
  asked.length = 0;
  fire("click", { type: "click", target: target({ tsort: "when", tdir: "" }, "n") });
  assert.equal(run("st.views.tt"), "nsort=when");
  assert.equal(asked.length, 0, "the first table did not re-read");
  fire("click", { type: "click", target: target({ all: "1" }, "n") });
  assert.equal(run("two.all"), true);
  assert.equal(run("one.all"), false);
});

test("with a dropdown in use only what is around it repaints", () => {
  run(`one.render()`);
  box("tt").innerHTML = "the bar in use";
  doc.activeElement = { id: "", dataset: { tq: "" }, closest: (sel) => (sel === "#tt-facets" ? {} : null) };
  run(`one.data.rows = ["z"]; one.all = false; one.render()`);
  doc.activeElement = null;
  assert.equal(box("tt").innerHTML, "the bar in use");
  assert.match(box("tt-body").innerHTML, /rows z/);
});

const heads = (roles) => roles.map((role, i) => ({ dataset: { role, label: "col" + i } }));
const cells = (n) => Array.from({ length: n }, (_, i) => ({ dataset: {}, textContent: "text" + i, querySelector: () => null }));
const trOf = (c) => ({ cells: c, dataset: {}, textContent: c.map((x) => x.textContent).join(""), classList: { add(k) { this[k] = true; } } });
const tableOf = (roles, rows) => ({ rows: [trOf(heads(roles)), ...rows], classList: { add(k) { this[k] = true; } } });

test("a table is stamped from its own headers, and a row of another shape is left alone", () => {
  const row = trOf(cells(3)), detail = trOf(cells(1)), t = tableOf(["lead", "glance", ""], [row, detail]);
  ctx.subject = t;
  run("tblStamp(subject)");
  assert.equal(t.classList.tphone, true);
  assert.equal(t.rows[0].dataset.phone, "head");
  assert.equal(row.dataset.phone, "row");
  assert.deepEqual(row.cells.map((c) => c.dataset.role), ["lead", "glance", "rest"]);
  assert.deepEqual(row.cells.map((c) => c.dataset.label), ["col0", "col1", "col2"]);
  assert.equal(detail.dataset.phone, undefined);
  assert.equal(detail.cells[0].dataset.role, undefined);
});

test("a cell holding a control is never hidden, whatever its column", () => {
  const row = trOf(cells(3)), t = tableOf(["lead", "", ""], [row]);
  row.cells[2].querySelector = () => ({});
  ctx.subject = t;
  run("tblStamp(subject)");
  assert.deepEqual(row.cells.map((c) => c.dataset.role), ["lead", "rest", "glance"]);
});

test("a hand-written table's labels come from its header text, and a named glance cell keeps its name", () => {
  const hs = [["lead", "host"], ["glance", "temp"], ["", "where"]].map(([role, textContent], i) => ({ dataset: i === 1 ? { role, named: "" } : { role }, textContent }));
  const row = trOf(cells(3)), t = { rows: [trOf(hs), row], classList: { add() {} } };
  ctx.subject = t;
  run("tblStamp(subject)");
  assert.deepEqual(row.cells.map((c) => c.dataset.label), ["host", "temp", "where"]);
  assert.deepEqual(row.cells.map((c) => "named" in c.dataset), [false, true, false]);
});

test("a pfold is always open on a wide screen, and on a phone is a closed line until opened", () => {
  const draw = () => run(`pfold("x", "the line", "the part", "sec-x")`);
  assert.equal(draw(), `<details class="pfold" data-pf="x" id="sec-x" open><summary>the line</summary>the part</details>`);
  ctx.matchMedia = () => ({ matches: true });
  assert.doesNotMatch(draw(), / open>/);
  run(`PFOLD.x = true`);
  assert.match(draw(), / open>/, "opened on a phone stays open across a redraw");
  run(`delete PFOLD.x`);
  delete ctx.matchMedia;
});

test("every hand-written table header on Infra and Costs names a lead", () => {
  for (const f of ["infra.js", "costs.js"]) for (const [h] of readFileSync(new URL(f, dir), "utf8").matchAll(/<table class="tbl"><tr><th.*?<\/tr>/g))
    assert.match(h, /data-role="lead"/, `${f}: ${h}`);
});

test("an open session's action buttons are one fold, and a confirm or a result stays outside it", () => {
  const acts = { hidden: true, innerHTML: "" }, real = doc.getElementById;
  doc.getElementById = (id) => (id === "acts" ? acts : real(id));
  run(`st.sel = { target: "t1", account: "a", actions: ["interrupt"] }; st.act = { confirm: null, busy: false, msg: "done", err: false }; renderActs()`);
  assert.match(acts.innerHTML, /^<details class="pfold" data-pf="acts" open><summary>Actions<\/summary><div class="actrow"><button class="btn" data-act="interrupt"[^>]*>Interrupt<\/button><\/div><\/details><div class="msg">done<\/div>$/);
  run(`st.opts = { describe: {}, accounts: [] }; st.act.confirm = { action: "interrupt", target: "t1" }; renderActs()`);
  assert.doesNotMatch(acts.innerHTML, /pfold/, "a confirm is never folded away");
  assert.match(acts.innerHTML, /data-go/);
  run(`st.sel = null; st.act = { confirm: null, busy: false, msg: "", err: false }`);
  doc.getElementById = real;
});

test("a table with no lead keeps its columns", () => {
  const row = trOf(cells(2)), t = tableOf(["", ""], [row]);
  ctx.subject = t;
  run("tblStamp(subject)");
  assert.equal(t.classList.tphone, undefined);
  assert.equal(row.dataset.phone, undefined);
});

test("a row expanded by a tap is still expanded after a redraw", () => {
  const before = trOf(cells(2)), t = tableOf(["lead", ""], [before]);
  ctx.subject = t;
  run("tblStamp(subject); tblExpanded.add('text0text1')");
  const after = trOf(cells(2));
  ctx.subject = tableOf(["lead", ""], [after]);
  run("tblStamp(subject); tblExpanded.clear()");
  assert.equal(after.classList.tx, true);
});

test("the sort dropdown lists each column, marks the sort, offers its reverse, and patches the view", () => {
  ctx.subject = { sort: "run", columns: [{ key: "run", sort: "desc", next_dir: "asc" }, { key: "name", sort: null, next_dir: "asc" }] };
  const html = run("tblSort(subject)");
  assert.match(html, /<option value="\|">default sort/);
  assert.match(html, /<option value="run\|desc" selected>sort: run</);
  assert.match(html, /<option value="run\|asc">sort: run reversed</);
  assert.match(html, /<option value="name\|asc">sort: name</);
  ctx.subject = { type: "change", target: { value: "run|asc", dataset: { tsv: "" } } };
  assert.deepEqual({ ...run("tblPatch(subject)") }, { sort: "run", dir: "asc" });
  ctx.subject = { type: "change", target: { value: "|", dataset: { tsv: "" } } };
  assert.deepEqual({ ...run("tblPatch(subject)") }, { sort: "", dir: "" });
  assert.equal(run("tblSort({columns: []})"), "");
});

test("with the sort dropdown in use only what is around it repaints", () => {
  run(`one.render()`);
  box("tt").innerHTML = "the bar in use";
  doc.activeElement = { id: "", dataset: { tsv: "" }, closest: (sel) => (sel === "#tt-facets" ? {} : null) };
  run(`one.data.rows = ["y"]; one.all = false; one.render()`);
  doc.activeElement = null;
  assert.equal(box("tt").innerHTML, "the bar in use");
  assert.match(box("tt-body").innerHTML, /rows y/);
});

const dayTarget = (attrs, tag = "BUTTON") => ({ tagName: tag, dataset: attrs, closest: (sel) => { const k = /^\[data-(.*)\]$/.exec(sel)?.[1].replace(/-(.)/g, (m, c) => c.toUpperCase()); return k in attrs ? { dataset: attrs } : null; } });

test("the day control marks the window on, shows a picked date and escapes what it draws", () => {
  ctx.a = { key: "day", on: "2026-11-03", windows: [["today", "Today"], ["", "7d"]], date: true };
  const picked = run("tblDays(a)");
  assert.match(picked, /<button class="" data-twin="day" data-tval="today">Today<\/button>/);
  assert.match(picked, /<input type="date" class="tdate" data-twin="day" value="2026-11-03"/);
  ctx.a = { key: "day", on: "", windows: [["", "7d"]], date: true };
  assert.match(run("tblDays(a)"), /class="on" data-twin="day" data-tval="">7d/);
  assert.match(run("tblDays(a)"), /class="tdate" data-twin="day" value=""/, "a window is no date");
  ctx.a = { key: "day", on: "<x>", windows: [], date: true };
  assert.doesNotMatch(run("tblDays(a)"), /<x>/);
  ctx.a = { key: "hours", on: "", windows: [["", "24h"]] };
  assert.doesNotMatch(run("tblDays(a)"), /tdate/, "no date asked, no picker");
});

test("a window click and a picked date each patch the control's one key; a blank window clears it", () => {
  ctx.ev = (type, t, value) => ({ type, target: Object.assign(t, { value }) });
  const patch = (type, t, value) => { ctx.e = ctx.ev(type, t, value); return JSON.parse(run("JSON.stringify(tblPatch(e))")); };
  assert.deepEqual(patch("click", dayTarget({ twin: "day", tval: "30d" })), { day: "30d" });
  assert.deepEqual(patch("click", dayTarget({ twin: "day", tval: "" })), { day: "" });
  assert.deepEqual(patch("change", dayTarget({ twin: "day" }, "INPUT"), "2026-11-03"), { day: "2026-11-03" });
  ctx.b = dayTarget({ twin: "day", tval: "30d" });
  ctx.i = dayTarget({ twin: "day" }, "INPUT");
  assert.equal(run("tblDropdown(b)"), false, "a window is a button, nothing to let go of");
  assert.equal(run("tblDropdown(i)"), true);
});
