// Unit tests for the Infra tab (.local/src/agent-web/static/infra.js), run by `node --test` from
// tests/unit/agent_web_queue.bats. The page's real scripts load into one vm context, as the
// browser loads them; only the DOM is a stub. Red now, Red fixes and health are Alerts'
// (alerts.test.mjs).
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);

const el = () => new Proxy({}, {
  get: (t, k) => (k in t ? t[k] : k === "classList" ? { add() {}, remove() {}, toggle() {} } : k === "dataset" ? {} : k === "style" ? {} : () => el()),
  set: (t, k, v) => { t[k] = v; return true; },
});
const doc = { getElementById: () => el(), addEventListener() {}, querySelector: el, querySelectorAll: () => [], createElement: el, body: el() };
const ctx = vm.createContext({
  console,
  document: doc,
  window: { addEventListener() {} },
  fetch: async () => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => ({}) }),
});
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "infra.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
const run = (src) => vm.runInContext(src, ctx);
const ist = run("ist");

test("CI lists no runs: one line links to Releases, whose Builds section has them", () => {
  Object.assign(ist, { open: {} });
  const h = run("ciSection({}, {}, Date.now(), { hosts: 0, slots: 0, busy: 0, queued: 0, oldest: 0, rows: [], queue: [], red: [] })");
  assert.ok(!h.includes("Recent runs"), "the runs are Releases'");
  assert.match(h, /<div class="cline">Runs: every CI run is on <a href="#releases\/builds">Releases, Builds<\/a><\/div>$/);
});

const slot = (o) => ({ host: "razer", slot: "1", state: "busy", job: "PlayMode", repo: "unity", pr: "412", branch: "feat", ran: 7000, usual: 600, late: true, note: "", ...o });
const queued = (o) => ({ job: "HD tests", repo: "unity", pr: "", branch: "main", n: 1, wait: 900, needs: ["unity-full", "hd-library"], can: [], missing: ["hd-library"], stuck: true, ...o });
const ci = { hosts: 2, slots: 3, busy: 1, queued: 1, oldest: 900, rows: [slot({}), slot({ slot: "2", state: "idle", job: "", late: false, ran: null, usual: null }), slot({ host: "mini", state: "off", late: false, ran: null, usual: null })], queue: [queued({})], red: ["HD tests (unity) needs [unity-full, hd-library]: no online runner holds hd-library"] };

test("CI runners: a job nobody can take is a red line naming the missing label, and a late run is marked", () => {
  Object.assign(ist, { open: {} });
  const h = run(`ciSection({}, {}, Date.now(), ${JSON.stringify(ci)})`);
  assert.match(h, /CI runners <span class="muted">2 hosts, 3 slots, 1 busy, 1 queued \(oldest 15m\)/);
  assert.match(h, /HD tests \(unity\) needs \[unity-full, hd-library\]: no online runner holds hd-library/);
  assert.match(h, /<td class="n warn">1h 57m!<\/td>/);
  assert.match(h, /<td class="bad">off<\/td>/);
  assert.match(h, /<td class="muted">idle<\/td>/);
  assert.match(h, /<tr class="bad"><td>HD tests/);
});

test("CI runners: a queued job some host can take names it, and is not red", () => {
  Object.assign(ist, { open: {} });
  const ok = { ...ci, red: [], queue: [queued({ can: [{ host: "razer", state: "idle" }], missing: [], stuck: false })] };
  const h = run(`ciSection({}, {}, Date.now(), ${JSON.stringify(ok)})`);
  assert.ok(!h.includes('class="panel down"'), "no red panel");
  assert.match(h, /razer <span class="muted">idle<\/span>/);
});

// The page's elements by id, kept, so a test can read back what renderInfra painted.
const els = {};
const page = (id) => (els[id] ||= Object.assign(el(), { id, dataset: {}, innerHTML: "" }));

test("Infra's strip leads the page with nothing pinned above it; each section joins its inner tab", () => {
  doc.getElementById = page;
  Object.assign(ist, { open: {} });
  const instant = { cc: [], governor: [{ labels: { __name__: "ci_governor_up" }, value: 1 }], power: [{ labels: { __name__: "ci_governor_power_state", host: "aws-1", state: "off" }, value: 1 }] };
  ist.data = { ok: true, at: Date.now() / 1e3, instant, down: [], ci: { ...ci } };
  run(`st.tab = "infra"; st.arg = "machines"; renderInfra()`);
  const main = els["infra-main"].innerHTML, tail = els["infra-tail"].innerHTML;
  const at = (s) => main.indexOf(s);
  assert.ok(main.startsWith('<div class="seg fseg istrip" role="tablist">'), main);
  for (const gone of ['id="sec-red"', 'id="sec-fixes"', 'id="sec-health"', 'data-itab="reds"']) assert.equal(at(gone), -1, `${gone} moved to Alerts`);
  // The count: the red CI line on CI; none on Machines, Jobs or Cloud.
  assert.match(main, /data-itab="ci" [^>]*>CI <span class="pill warn">1<\/span>/);
  assert.match(main, /data-itab="machines" class="on" [^>]*>Machines<\/button>/);
  assert.match(main, /data-itab="jobs" [^>]*>Jobs<\/button>/);
  // The open inner tab shows; another one's sections are in the page, hidden.
  assert.match(main, /<div data-in="machines"><div class="tiles roomy">[\s\S]*<h2 class="sec" id="sec-machines">/);
  assert.match(main, /href="#alerts\/watches"/, "the watches tile opens Alerts' Watches");
  assert.match(main, /<div data-in="ci" hidden><h2 class="sec" id="sec-ci">/);
  assert.match(main, /<div data-in="machines"><h2 class="sec" id="sec-governor">/);
  assert.match(tail, /<div data-in="cloud" hidden><h2 class="sec" id="sec-cloud">/);
  // Jobs is its own element (jobs.js paints it): it joins the Jobs group and hides here.
  assert.equal(els.jobs.dataset.in, "jobs");
  assert.equal(els.jobs.hidden, true);
  run(`st.arg = "jobs"; renderInfra()`);
  assert.equal(els.jobs.hidden, false);
  // "Done today, queues by pool" starts open like every section; a fold the reader closed stays closed.
  run(`st.arg = "ci"; renderInfra()`);
  assert.match(els["infra-main"].innerHTML, /data-k="ci-more" open>/);
  ist.open["ci-more"] = false;
  run(`renderInfra()`);
  assert.match(els["infra-main"].innerHTML, /data-k="ci-more"><summary/);
  ist.open = {};
});

test("the strip leads Infra on the loading, failed-read and Prometheus-down paths too", () => {
  doc.getElementById = page;
  const lead = (st) => {
    Object.assign(ist, { open: {}, ...st });
    run(`st.tab = "infra"; st.arg = ""; renderInfra()`);
    return els["infra-main"].innerHTML;
  };
  for (const [name, state] of [["loading", { data: null, err: null }], ["read failed", { data: null, err: "fetch failed" }], ["prometheus down", { data: { ok: false, error: "no answer" }, err: null }]]) {
    assert.ok(lead(state).startsWith('<div class="seg fseg istrip" role="tablist">'), name);
  }
  assert.match(lead({ data: null, err: "fetch failed" }), /role="tablist">[\s\S]*fetch failed/, "the error under the strip");
  ist.data = null; ist.err = null;
});

test("a failed Prometheus read still draws the strip, so Jobs stays reachable", () => {
  ist.data = { ok: false, error: "no answer" };
  run(`st.arg = ""; renderInfra()`);
  const main = els["infra-main"].innerHTML;
  assert.match(main, /no answer/);
  assert.match(main, /role="tablist"/);
});

test("old Infra links open the inner tab holding their section", () => {
  const r = (h) => { const x = ctx.route(h); return [x.tab, x.arg, x.section]; };
  assert.deepEqual(r("#infra"), ["infra", "", undefined]);
  assert.deepEqual(r("#infra/ci"), ["infra", "ci", undefined]);
  assert.deepEqual(r("#infra/governor"), ["infra", "machines", "governor"]);
  assert.deepEqual(r("#infra/jobs"), ["infra", "jobs", undefined]);
  // Red now, Red fixes (and the Reds inner tab) and health moved to Alerts (layout::MOVED).
  assert.deepEqual(r("#infra/reds"), ["alerts", "", "fixes"]);
  assert.deepEqual(r("#infra/fixes"), ["alerts", "", "fixes"]);
  assert.deepEqual(r("#infra/red"), ["alerts", "", "firing"]);
  assert.deepEqual(r("#infra/health"), ["alerts", "", "health"]);
  // The retired #ci, #machines and #jobs tabs (layout::section) land on their inner tab too.
  assert.deepEqual(r("#ci"), ["infra", "ci", "ci"]);
  assert.deepEqual(r("#machines"), ["infra", "machines", "machines"]);
  assert.deepEqual(r("#jobs"), ["infra", "jobs", "jobs"]);
});
