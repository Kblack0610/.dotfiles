// Unit tests for the shared table (.local/src/agent-web/static/table.js) on its first caller,
// Infra's Jobs (jobs.js), run by `node --test` from tests/unit/agent_web_queue.bats. The page's
// real scripts load into one vm context, as the browser loads them; only the DOM is a stub.
// What a query keeps and how it sorts is hub_core::table, tested in Rust; this checks that the
// page draws the server's summary and turns each click into the view keys it sends back.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);

const el = () => new Proxy({}, {
  get: (t, k) => (k in t ? t[k] : k === "classList" ? { add() {}, remove() {}, toggle() {} } : k === "dataset" ? {} : k === "style" ? {} : () => el()),
  set: (t, k, v) => { t[k] = v; return true; },
});
const on = {};
const part = () => Object.assign(el(), { innerHTML: "", scrollTop: 0, querySelectorAll: () => [] });
const box = Object.assign(part(), { addEventListener: (ev, f) => { on[ev] = f; } });
const parts = { "jobs-head": part(), "jobs-facets": part(), "jobs-chips": part(), "jobs-body": part(), "jobs-tail": part() };
const doc = { getElementById: (id) => (id === "jobs" ? box : parts[id] || el()), addEventListener() {}, querySelector: el, querySelectorAll: () => [], createElement: el, body: el(), activeElement: null };
let asked = [];
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
  fetch: async (url) => { asked.push(url); return { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => body }; },
});
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "log.js", "infra.js", "actions.js", "table.js", "jobs.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
const run = (src) => vm.runInContext(src, ctx);
const jst = run("jst");

const col = (key, sort = null, next = [key, "desc"]) => ({ key, sort, next_sort: next[0], next_dir: next[1] });
// The shape hub_core::table::Summary serializes to, for `source:ci` sorted by start, oldest first.
const table = {
  q: "source:ci", state: "", sort: "started", dir: "asc", total: 3, shown: 2,
  states: [{ name: "all", n: 2 }, { name: "running", n: 1 }, { name: "queued", n: 0 }, { name: "done", n: 1 }, { name: "failed", n: 1 }],
  columns: [col("state"), col("source"), col("name"), col("started", "asc", ["", "desc"]), col("took"), col("result"), col("detail")],
  facets: [
    { key: "source", on: "ci", clear: "", values: [{ value: "agentctl", n: 1, q: "source:agentctl" }, { value: "ci", n: 2, q: "source:ci" }] },
    { key: "result", on: null, clear: "source:ci", values: [{ value: "failure", n: 1, q: "source:ci result:failure" }] },
  ],
};
const job = (name, o = {}) => ({ source: "ci", name, state: "done", ok: true, result: "success", started: 1793942659, finished: null, secs: 60, detail: "", runs: 1, ...o });
const data = { at: 1793942700, window_secs: 86400, errors: [], jobs: [job("playground / Tests", { ok: false, result: "failure" }), job("platform / e2e", { state: "running", ok: null, result: "" })], table };

const target = (attrs) => ({ dataset: attrs, closest: (sel) => (sel === "[data-tsort]" && "tsort" in attrs) || (sel === "[data-ts]" && "ts" in attrs) ? { dataset: attrs } : null });

test("the table draws the server's rows, sort, chips and dropdowns", () => {
  run("st.tab = 'infra'");
  Object.assign(jst, { data, err: null, hist: null, log: null, all: false });
  run("renderJobs()");
  const h = box.innerHTML;
  assert.match(h, /2 of 3 in 24h/);
  assert.match(h, /<th class="n" aria-sort="ascending"><button class="thsort" data-tsort="" data-tdir="desc" title="sort by started">started \^<\/button><\/th>/, "the sorted header says its direction and that a click goes back to the default");
  assert.match(h, /<th><button class="thsort" data-tsort="name" data-tdir="desc"[^>]*>name<\/button><\/th>/, "every other header sorts");
  assert.match(h, /<button class="on" data-ts="">all <span class="n">2<\/span><\/button>/, "no chip is every row");
  assert.match(h, /<button class="" data-ts="failed">failed <span class="n">1<\/span><\/button>/);
  assert.match(h, /<option value="source:ci" selected>ci \(2\)<\/option>/, "the dropdown shows the value the query picks");
  assert.match(h, /<option value="source:ci">every result<\/option>/, "its first option clears that column only");
  assert.match(h, /id="jobs-q" data-tsearch placeholder="[^"]*" value="source:ci"/);
  assert.ok(h.indexOf("playground / Tests") < h.indexOf("platform / e2e"), "the server's order is kept");
});

test("a click or a keystroke becomes the view keys the server reads", () => {
  const patch = (type, attrs, value) => JSON.parse(JSON.stringify(run("tblPatch")({ type, target: { ...target(attrs), value } })));
  assert.deepEqual(patch("click", { tsort: "started", tdir: "asc" }), { sort: "started", dir: "asc" });
  assert.deepEqual(patch("click", { tsort: "", tdir: "desc" }), { sort: "", dir: "" }, "back to the default drops both keys");
  assert.deepEqual(patch("click", { ts: "failed" }), { s: "failed" });
  assert.deepEqual(patch("input", { tsearch: "" }, "nightly -source:k8s"), { q: "nightly -source:k8s" });
  assert.deepEqual(patch("change", { tq: "" }, "source:ci result:failure"), { q: "source:ci result:failure" });
  assert.equal(patch("click", {}), null);
});

test("a view change lands in the URL and the API asks the server for it", async () => {
  asked = [];
  body = data;
  run("st.views.infra = 'q=source%3Aci&sort=started'");
  on.click({ type: "click", target: target({ ts: "failed" }) });
  await new Promise((r) => setImmediate(r));
  assert.equal(ctx.history.url, "#infra?q=source%3Aci&sort=started&s=failed");
  assert.equal(asked.at(-1), "/api/jobs?q=source%3Aci&s=failed&sort=started");
  on.click({ type: "click", target: target({ tsort: "", tdir: "desc" }) });
  await new Promise((r) => setImmediate(r));
  assert.equal(ctx.history.url, "#infra?q=source%3Aci&s=failed", "the plain sort is a bare URL");
  jst.hist = "dream";
  run("refreshJobs()");
  await new Promise((r) => setImmediate(r));
  assert.equal(asked.at(-1), "/api/jobs?q=source%3Aci&s=failed&name=dream", "a history keeps the view");
  jst.hist = null;
});

test("a refresh while the search box has focus leaves the box alone", () => {
  Object.assign(jst, { data, err: null });
  box.innerHTML = "KEEP";
  doc.activeElement = { id: "jobs-q" };
  run("renderJobs()");
  doc.activeElement = null;
  assert.equal(box.innerHTML, "KEEP");
  assert.match(parts["jobs-body"].innerHTML, /playground \/ Tests/);
  assert.match(parts["jobs-chips"].innerHTML, /data-ts="failed"/);
  assert.match(parts["jobs-facets"].innerHTML, /every source/);
});

test("a failed collection says why instead of drawing an empty table", () => {
  Object.assign(jst, { data: { jobs: [], errors: ["gh: rate limited"] }, err: null });
  run("renderJobs()");
  assert.match(box.innerHTML, /<div class="empty">gh: rate limited<\/div>/);
});
