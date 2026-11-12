// Unit tests for tblTab (.local/src/agent-web/static/table.js), the skeleton every tab on the
// shared table draws with, run by `node --test` from tests/unit/agent_web_queue.bats. The page's
// real scripts load into one vm context with a stub DOM; the tabs' own tests check what each draws,
// this checks what they all share: the placeholder, the repaint around a control in use, the more
// button, the scroll a whole draw keeps, and which of two tables in one block an event belongs to.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
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
// The document listeners table.js adds (the facet menus' open, tick, outside click and Escape),
// kept apart from the other scripts' so a test fires only these.
const docOn = {};
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "table.js"]) {
  doc.addEventListener = f === "table.js" ? (ev, fn) => { (docOn[ev] ||= []).push(fn); } : () => {};
  vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
}
const fireDoc = (ev, e) => (docOn[ev] || []).forEach((f) => f(e));
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
  hs[2].dataset.label = "";
  run("tblStamp(subject)");
  assert.equal(row.cells[2].dataset.label, "", "a label left blank on purpose stays blank");
});

test("a pfold is always open on a wide screen, and on a phone is a closed line until opened", () => {
  const draw = () => run(`pfold("x", "the line", "the part")`);
  assert.equal(draw(), `<details class="pfold" data-pf="x" open><summary>the line</summary>the part</details>`);
  ctx.matchMedia = () => ({ matches: true });
  assert.doesNotMatch(draw(), / open>/);
  run(`PFOLD.x = true`);
  assert.match(draw(), / open>/, "opened on a phone stays open across a redraw");
  run(`delete PFOLD.x`);
  const drawn = { dataset: { pf: "x" }, open: true }, real = doc.querySelectorAll;
  doc.querySelectorAll = (sel) => (sel === "details.pfold" ? [drawn] : real(sel));
  run(`pfoldFit()`);
  assert.equal(drawn.open, false, "narrowing closes a fold already drawn");
  delete ctx.matchMedia;
  run(`pfoldFit()`);
  assert.equal(drawn.open, true, "widening opens one, whose summary a wide screen hides");
  doc.querySelectorAll = real;
});

// A grid (a blank corner cell: days or periods one way, measures the other) keeps its columns, and so does an
// opened run's job list, which app.css draws a job per block (.rdjobs).
const KEEPS_COLUMNS = (h) => h.startsWith("<tr><th></th>") || h.includes("<th>job</th><th>class</th>");

test("every literal hand-written table header names a lead, so a phone draws its rows", () => {
  const files = readdirSync(dir).filter((f) => f.endsWith(".js"));
  let seen = 0;
  for (const f of files) for (const [h] of readFileSync(new URL(f, dir), "utf8").matchAll(/<tr><th.*?<\/tr>/g)) {
    if (KEEPS_COLUMNS(h)) continue;
    seen++;
    assert.match(h, /data-role="lead"/, `${f}: ${h}`);
  }
  // About two dozen literal headers today: far fewer means the pattern stopped matching, not that they went.
  assert.ok(seen >= 20, `the scan found only ${seen} headers: the pattern no longer matches how tables are written`);
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

// A facet as hub-core sends it: column a filtering on x and y, and a column the tab does not draw.
const facetTable = () => ({ columns: [{ key: "a", sort: null, next_sort: "a", next_dir: "desc" }, { key: "b", sort: null, next_sort: "b", next_dir: "desc" }],
  facets: [
    { key: "a", on: ["x", "y"], clear: "", values: [{ value: "x", n: 2, on: true, q: "a:y" }, { value: "y", n: 1, on: true, q: "a:x" }, { value: "<z>", n: 4, on: false, q: "a:x a:y a:<z>" }] },
    { key: "repo", on: [], clear: "", values: [{ value: "r", n: 1, on: false, q: "repo:r" }] },
  ] });

test("the filter row draws each facet under its column, and the bar draws only the rest", () => {
  ctx.t = facetTable();
  assert.match(run("tblFacets(t)"), /data-fkey="a".*data-fkey="repo"/, "before any header is drawn the bar has every facet");
  const head = run(`tblHead(t, { a: ["a"], b: ["b"] })`);
  assert.match(head, /<\/tr><tr class="tfilters" data-phone="filters"><th><details class="tfacet on" data-fkey="a"[^>]*><summary[^>]*>a: x \+1<\/summary>.*<\/details><\/th><td><\/td><\/tr>$/, "a cell per drawn column, the facet under its own");
  assert.match(head, /data-fv="x" value="a:y" checked>/);
  assert.match(head, /data-fv="y" value="a:x" checked>/);
  assert.match(head, /data-fv="&lt;z&gt;" value="a:x a:y a:&lt;z&gt;"> <span>&lt;z&gt;<\/span> <span class="n">4<\/span>/, "an unticked value adds itself, escaped");
  assert.doesNotMatch(head, /data-fkey="repo"/);
  const bar = run("tblFacets(t)");
  assert.match(bar, /data-fkey="repo"/, "a facet whose column is not drawn stays in the bar");
  assert.doesNotMatch(bar, /data-fkey="a"/, "and a drawn one is not drawn twice");
  ctx.t = { ...facetTable(), facets: [facetTable().facets[1]] };
  assert.doesNotMatch(run(`tblHead(t, { a: ["a"], b: ["b"] })`), /tfilters/, "no drawn column has a facet, no filter row");
});

test("a tick patches the query and keeps focus; clear patches the column's clear query", () => {
  ctx.e = { type: "change", target: { type: "checkbox", value: "a:x a:z", dataset: { tq: "", fv: "z" } } };
  assert.deepEqual({ ...run("tblPatch(e)") }, { q: "a:x a:z" });
  assert.equal(run("tblDropdown(e.target)"), false, "a checkbox is not let go of, so its menu stays open");
  ctx.e = { type: "click", target: { dataset: {}, closest: (sel) => (sel === "[data-tqc]" ? { dataset: { tqc: "b:1" } } : null) } };
  assert.deepEqual({ ...run("tblPatch(e)") }, { q: "b:1" });
});

// A drawn facet menu: its block, its column, and its boxes, as the redraw leaves it.
const menuOf = (key, tbl, fvs, fq = "") => {
  const boxes = fvs.map((fv) => ({ dataset: { fv }, focus() { this.focused = true; } }));
  const summary = { focus() { this.focused = true; } }, classes = new Set();
  return { dataset: { fkey: key, fq }, open: false, isConnected: true, boxes, summary, classes, classList: { add: (c) => classes.add(c), remove: (c) => classes.delete(c) },
    matches: (sel) => sel === "details.tfacet", closest: (sel) => (sel === "[data-tbl]" ? (tbl ? { dataset: { tbl } } : null) : sel.startsWith("details.tfacet") ? null : null),
    querySelector: (sel) => (sel === "summary" ? summary : null), querySelectorAll: () => boxes };
};

test("a menu ticked in waits for the answer, then stays open on the box last ticked", () => {
  const before = menuOf("a", "n", ["x", "y"]);
  before.closest = (sel) => (sel === "[data-tbl]" ? { dataset: { tbl: "n" } } : null);
  fireDoc("change", { target: { value: "a:x a:y", dataset: { fv: "y" }, closest: (sel) => (sel === "details.tfacet" ? before : null) } });
  assert.deepEqual(before.boxes.map((b) => b.disabled), [true, true], "no box built on the old view is ticked again");
  assert.ok(before.classes.has("busy"));
  assert.equal(before.summary.focused, true, "focus waits on the pill, where Escape still shuts it");
  // A redraw from the old view (the hash change, a poll) lands first: its boxes still wait.
  const stale = menuOf("a", "n", ["x", "y"], "a:x"), other = menuOf("a", "", ["x", "y"], "a:x a:y");
  ctx.root = { querySelectorAll: () => [other, stale] };
  run("tblMenuKeep(root)");
  assert.equal(stale.open, true);
  assert.deepEqual(stale.boxes.map((b) => b.disabled), [true, true]);
  assert.equal(stale.summary.focused, true);
  assert.equal(other.open, false, "the same column in another table block stays shut");
  // The answer's redraw: its boxes are built on the view asked for.
  const mine = menuOf("a", "n", ["x", "y"], " a:x  a:y");
  ctx.root = { querySelectorAll: () => [mine] };
  run("tblMenuKeep(root)");
  assert.equal(mine.open, true);
  assert.deepEqual(mine.boxes.map((b) => b.disabled), [undefined, undefined]);
  assert.equal(mine.boxes[1].focused, true, "focus is back on the box ticked");
  assert.equal(run("tblMenu.want"), null);
});

test("clear waits for its answer like a tick", () => {
  const d = menuOf("a", "n", ["x"]);
  d.closest = (sel) => (sel === "[data-tbl]" ? { dataset: { tbl: "n" } } : null);
  fireDoc("click", { target: { closest: (sel) => (sel === "details.tfacet" ? d : sel === "[data-tqc]" ? { dataset: { tqc: "b:1" } } : null) } });
  assert.equal(run("tblMenu.want"), "b:1");
  assert.ok(d.classes.has("busy"));
  const next = menuOf("a", "n", ["x"], "b:1");
  ctx.root = { querySelectorAll: () => [next] };
  run("tblMenuKeep(root)");
  assert.equal(run("tblMenu.want"), null);
  assert.equal(next.classes.has("busy"), false);
  run("tblMenu = null");
});

test("a click outside a menu or Escape inside it shuts it, and nothing reopens on the next draw", () => {
  const d = menuOf("a", "n", ["x"]);
  d.open = true;
  doc.querySelectorAll = (sel) => (sel === "details.tfacet[open]" ? [d] : []);
  fireDoc("click", { target: { closest: () => null } });
  assert.equal(d.open, false);
  assert.equal(run("tblMenu"), null);
  run(`tblMenu = { tbl: "n", key: "a", fv: null }`);
  d.open = true;
  fireDoc("keydown", { key: "Escape", target: { closest: (sel) => (sel === "details.tfacet[open]" ? d : null) } });
  doc.querySelectorAll = () => [];
  assert.equal(d.open, false);
  assert.equal(d.summary.focused, true, "Escape hands focus back to the pill");
  const next = menuOf("a", "n", ["x"]);
  ctx.root = { querySelectorAll: () => [next] };
  run("tblMenuKeep(root)");
  assert.equal(next.open, false);
});

test("a menu opens under its pill, or over it when the window has more room there, never past the edge", () => {
  ctx.innerWidth = 1280; ctx.innerHeight = 900;
  const at = (top) => {
    const m = { style: {}, scrollHeight: 300, offsetHeight: 300, offsetWidth: 150 };
    ctx.d = { querySelector: (sel) => (sel === ".tfmenu" ? m : { getBoundingClientRect: () => ({ top, bottom: top + 24, left: 589 }) }) };
    run("tblPlace(d)");
    return m.style;
  };
  assert.deepEqual({ ...at(100) }, { maxHeight: "360px", top: "126px", left: "589px" });
  assert.deepEqual({ ...at(839) }, { maxHeight: "360px", top: "537px", left: "589px" }, "a pill near the bottom opens its menu upward");
  assert.equal(at(500).top, "526px", "room enough below stays below");
  assert.equal(at(700).maxHeight, "360px");
  assert.equal(at(700).top, "398px", "more room above, too little below, flips up");
  ctx.innerHeight = 150;
  assert.equal(at(90).top, "4px", "a window too short for either side never puts the menu above its top");
  ctx.innerHeight = 900;
});

test("the filter row is never stamped as a phone row", () => {
  const filters = trOf(cells(2)), row = trOf(cells(2));
  filters.dataset.phone = "filters";
  ctx.subject = tableOf(["lead", ""], [filters, row]);
  run("tblStamp(subject)");
  assert.equal(filters.dataset.phone, "filters");
  assert.deepEqual(filters.cells.map((c) => c.dataset.role), [undefined, undefined]);
  assert.equal(row.dataset.phone, "row");
});

test("a body drawn again with no header leaves every facet to the bar", () => {
  ctx.t = facetTable();
  run(`tblHead(t, { a: ["a"], b: ["b"] })`);
  assert.doesNotMatch(run("tblFacets(t)"), /data-fkey="a"/);
  run(`tblBodyFirst(t, () => "No rows.")`);
  assert.match(run("tblFacets(t)"), /data-fkey="a"/, "the filter that emptied the table can still be taken off");
});

test("a menu kept open on one tab never opens the same column on another, and keeps its scroll", () => {
  run(`st.tab = "tt"; tblMenu = { tbl: "tt|n|", key: "a", fv: null, top: 120 }`);
  const list = { scrollTop: 0 };
  const mine = menuOf("a", "n", ["x"]);
  mine.querySelector = (sel) => (sel === ".tfmenu" ? list : sel === "summary" ? mine.summary : null);
  ctx.root = { querySelectorAll: () => [mine] };
  run("tblMenuKeep(root)");
  assert.equal(mine.open, true);
  assert.equal(list.scrollTop, 120, "a push redraw keeps where the menu was scrolled");
  assert.equal(mine.summary.focused, true, "with nothing ticked yet, focus goes back to the pill");
  const elsewhere = menuOf("a", "n", ["x"]);
  ctx.root = { querySelectorAll: () => [elsewhere] };
  run(`st.tab = "queue"; tblMenuKeep(root); st.tab = "tt"; tblMenu = null`);
  assert.equal(elsewhere.open, false);
});

test("the head is the state tiles, hued and explained by the server, over one search bar; a table with one state draws no tiles", () => {
  const t = { ...summary, state: "stuck", legend: "stuck: no progress in 2h", states: [{ name: "all", n: 3, tone: "none" }, { name: "stuck", n: 1, tone: "bad", means: "no progress in 2h" }, { name: "free", n: 0, tone: "none" }] };
  ctx.t = t;
  const h = run(`tblBar("tt", t, "search", "<i>extra</i>")`);
  assert.doesNotMatch(h, /fseg|bfilter|tlegend/, "no chip row, no search card, no legend line");
  assert.match(h, /^<div id="tt-tiles"><div class="tiles stiles"><button class="tile on t-bad" data-ts="" title="no progress in 2h"><span class="tl">STUCK<\/span><span class="tv">1<\/span><\/button><button class="tile zero" data-ts="free"><span class="tl">FREE<\/span><span class="tv">0<\/span><\/button><i>extra<\/i><\/div><\/div><div class="tqbar"><input id="tt-q" data-tsearch/);
  assert.match(h, /title="key:value matches a column[^"]*\. stuck: no progress in 2h"/, "the legend is the box's hover");
  ctx.t = { ...summary };
  assert.match(run(`tblBar("tt", t, "search")`), /^<div id="tt-tiles"><\/div><div class="tqbar">/, "a table whose only state is all has no tiles");
});
