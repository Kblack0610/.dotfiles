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
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "table.js", "infra.js", "ci.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
const run = (src) => vm.runInContext(src, ctx);
const ist = run("ist");

// One shared-table read (hub_core::table Summary) and its rows, as agent-web's /api/infra sends
// each of ist.data.tables.
const col = (key) => ({ key, sort: "", next_sort: key, next_dir: "desc" });
const tbl = (rows, keys) => ({ table: { q: "", state: "", sort: "", dir: "", total: rows.length, shown: rows.length, states: [{ name: "all", n: rows.length }], columns: keys.map(col), facets: [] }, rows });
const SLOT_KEYS = ["host", "slot", "state", "pool", "ran", "usual", "job", "ref"];
const QUEUED_KEYS = ["job", "pool", "ref", "n", "wait", "needs", "can"];
const tables = (ci) => ({
  machines: tbl([], ["machine", "state"]), pools: tbl([], ["pool"]),
  runners: tbl(ci.rows, SLOT_KEYS), queued: tbl(ci.queue, QUEUED_KEYS), finished: tbl([], ["repo"]),
});
const done = { runs: 0, ok: 0, bad: 0, can: 0 };
const section = (c) => {
  ist.data = { ok: true, tables: tables(c) };
  return run(`ciSection({}, Date.now(), ${JSON.stringify(c)})`);
};

test("the CI runners section lists no runs: they are the Runs section under it (ci.js)", () => {
  Object.assign(ist, { open: {} });
  const h = section({ hosts: 0, slots: 0, busy: 0, queued: 0, oldest: 0, rows: [], queue: [], red: [], done });
  assert.ok(!h.includes("Recent runs"), "the runs are ci.js's");
  assert.doesNotMatch(h, /releases\/builds/, "no link to the retired Releases Builds section");
});

const slot = (o) => ({ host: "razer", slot: "1", state: "busy", pool: "unity", job: "PlayMode", repo: "unity", pr: "412", branch: "feat", ran: 7000, usual: 600, late: true, note: "", ...o });
const queued = (o) => ({ job: "HD tests", pool: "unity", repo: "unity", pr: "", branch: "main", n: 1, wait: 900, needs: ["unity-full", "hd-library"], can: [], missing: ["hd-library"], stuck: true, ...o });
const ci = { hosts: 2, slots: 3, busy: 1, queued: 1, oldest: 900, done: { runs: 10, ok: 8, bad: 1, can: 1 }, rows: [slot({}), slot({ slot: "2", state: "idle", job: "", late: false, ran: null, usual: null }), slot({ host: "mini", state: "off", late: false, ran: null, usual: null })], queue: [queued({})], red: ["HD tests (unity) needs [unity-full, hd-library]: no online runner holds hd-library"] };

test("CI runners: a job nobody can take is a red line naming the missing label, and a late run is marked", () => {
  Object.assign(ist, { open: {} });
  const h = section(ci);
  assert.match(h, /CI runners <span class="muted">2 hosts, 3 slots, 1 busy, 1 queued \(oldest 15m\)/);
  assert.match(h, /<div class="panel down">[\s\S]*HD tests \(unity\) needs \[unity-full, hd-library\]: no online runner holds hd-library/);
  assert.match(h, /<td class="n warn">1h 57m!<\/td>/);
  assert.match(h, /<td class="bad">off<\/td>/);
  assert.match(h, /<td class="muted">idle<\/td>/);
  assert.match(h, /<td class="bad">HD tests<\/td>/, "a stuck queued job is red");
  assert.match(h, /<td class="wrap">nobody<\/td>/);
  assert.match(h, /Finished 24h <span class="muted">10 runs, 89% pass, 1 failed, 1 cancelled/);
});

test("CI runners: a queued job some host can take names it, and is not red", () => {
  Object.assign(ist, { open: {} });
  const h = section({ ...ci, red: [], queue: [queued({ can: [{ host: "razer", state: "idle" }], missing: [], stuck: false })] });
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
  ist.data = { ok: true, at: Date.now() / 1e3, instant, down: [], ci: { ...ci }, tables: tables(ci) };
  run(`st.tab = "infra"; st.arg = "machines"; renderInfra()`);
  const main = els["infra-main"].innerHTML;
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
  // The governor and cloud sections folded into Machines' columns (layout::MOVED); Pools joins Machines.
  for (const gone of ['id="sec-governor"', 'id="sec-cloud"']) assert.equal(at(gone), -1, `${gone} folded into Machines`);
  assert.match(main, /<div data-in="machines"><h2 class="sec" id="sec-pools">/);
  // Jobs is its own element (jobs.js paints it): it joins the Jobs group and hides here.
  assert.equal(els.jobs.dataset.in, "jobs");
  assert.equal(els.jobs.hidden, true);
  run(`st.arg = "jobs"; renderInfra()`);
  assert.equal(els.jobs.hidden, false);
  // "Done today" starts open like every section; a fold the reader closed stays closed.
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
  // The governor and cloud sections are Machines under a chip (layout::MOVED's view).
  assert.deepEqual(r("#infra/governor"), ["infra", "machines", "machines"]);
  assert.equal(ctx.route("#infra/governor").query, "ms=governed");
  assert.equal(ctx.route("#infra/cloud").query, "ms=cloud");
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

test("a record's page inside an inner tab keeps its id: the route opens the inner tab, the URL keeps the page", () => {
  const r = (h) => { const x = ctx.route(h); return [x.tab, x.arg, x.page]; };
  assert.deepEqual(r("#infra/machines/razer-laptop"), ["infra", "machines", "machines/razer-laptop"]);
  assert.deepEqual(r("#infra/pools/unity"), ["infra", "machines", "pools/unity"], "a pool's page is on Machines");
  assert.deepEqual(r("#infra/ci/4412"), ["infra", "ci", "ci/4412"]);
  assert.deepEqual(r("#infra/jobs/agentctl-dream"), ["infra", "jobs", "jobs/agentctl-dream"]);
  assert.deepEqual(r("#infra/machines"), ["infra", "machines", undefined], "no id: the inner tab alone");
  assert.deepEqual(r("#infra/machines/a%2Fb"), ["infra", "machines", "machines/a/b"], "an id keeps its slash");
  assert.deepEqual(r("#infra/constructor/x"), ["infra", "", undefined], "an inherited name is not a page word: an unknown inner tab, as before");
  const urls = [];
  ctx.history = { replaceState: (_s, _t, u) => urls.push(u) };
  for (const h of ["#infra/machines/razer-laptop", "#infra/machines/a%2Fb"]) {
    const x = ctx.route(h);
    run(`st.tab = "infra"; st.views.infra = ""; st.arg = ${JSON.stringify(x.arg)}; st.page = ${JSON.stringify(x.page)}; showUrl()`);
    assert.equal(urls.at(-1), h, "the URL a page shows is the one that opened it");
  }
  run(`innerGo("infra", "ci")`);
  assert.equal(urls.at(-1), "#infra/ci", "another inner tab leaves the page");
  delete ctx.history;
});

test("the Cloud card's month is a link to Costs, Budget; AWS's stops and emails stay", () => {
  const g = run(`governorIndex({ governor: [
    { labels: { __name__: "ci_governor_budget_ok" }, value: 1 },
    { labels: { __name__: "ci_governor_budget_updated" }, value: 1700000000 },
    { labels: { __name__: "ci_governor_budget_usd", kind: "actual" }, value: 113 },
    { labels: { __name__: "ci_governor_budget_usd", kind: "limit" }, value: 600 },
    { labels: { __name__: "ci_governor_budget_alert", basis: "actual", usd: "450" }, value: 1 },
    { labels: { __name__: "ci_governor_budget_action_usd", type: "stop", status: "STANDBY" }, value: 550 },
  ] })`);
  const h = run(`budgetLines(${JSON.stringify(g)})`);
  assert.match(h, /Month: <a href="#costs\/budget">Costs, Budget<\/a>/);
  assert.doesNotMatch(h, /\$113|of \$600|forecast/, "the dollars are Costs, Budget's, not a second home");
  assert.match(h, /Emails at \$450/);
  assert.match(h, /at \$550 AWS stops it and blocks starts/);
  assert.doesNotMatch(h, /READ FAILED/);
  assert.match(run(`budgetLines(${JSON.stringify({ ...g, budget_ok: 0 })})`), /READ FAILED/);
});

// A machine page as GET /api/infra/machine sends it (hub_core::machine_page plus agent-web's
// tables), the few fields each test reads.
const machinePage = (o = {}) => ({
  host: "aws-burst-1", at: 1700000000, head: "aws-burst-1, cloud, stopped", errors: [],
  parts: [{ label: "Now", text: "no reading: the governor has it stopped", link: null, warn: true },
    { label: "Grafana", text: "its fleet board", link: "https://g.example/d/kb-fleet?var-host=aws-burst-1", warn: false }],
  machine: { power: { host: "aws-burst-1", state: "stopped" } }, cores: null, share: [], running: [], history: null,
  tables: { down: tbl([], ["from"]), recent: tbl([], ["job"]), alerts: tbl([], ["what"]) }, ...o,
});
// The page `page` opens (INFRA_PAGES), drawn from the read `d` and the error `err`.
const drawPage = (page, d, err) => {
  run(`st.tab = "infra"; st.page = ${JSON.stringify(page)}`);
  Object.assign(run("pgst"), { page, data: d, err: err || null });
  return run("infraPageHtml()");
};

test("a machine page for a name no machine has says so, from the server's 404", () => {
  const h = drawPage("machines/nope", null, "Could not read infra (HTTP 404): no machine named nope. Retry, or check the agent-web log.");
  assert.match(h, /<div class="panel down">[^<]*no machine named nope/);
  assert.match(h, /href="#infra\/machines">All machines<\/a>/);
});

test("a machine page with no reading says why, in amber, and holds the governor's buttons", () => {
  const h = drawPage("machines/aws-burst-1", machinePage());
  assert.match(h, /<span class="pgv capwarn">no reading: the governor has it stopped<\/span>/);
  assert.match(h, /href="https:\/\/g\.example\/d\/kb-fleet\?var-host=aws-burst-1" target="_blank"/);
  assert.match(h, /data-cloud="aws-burst-1:on" data-hours="2">On 2h</);
  assert.match(h, /No core reading/);
  assert.match(h, /Nothing firing names it\./);
});

test("the Machines table's power cell has no buttons: they are the machine page's", () => {
  const h = run(`powerCell({ power: { host: "aws-burst-1", state: "stopped", hours: 1, max: 8, rule: "r", reason: "", usd_per_hour: null } })`);
  assert.doesNotMatch(h, /data-cloud|7 days/);
});

test("a machine page draws its share, its 7 days and its recent jobs with their links", () => {
  const hours = [{ at: 1700000000, cpu: 0.5, pools: { unity: 6 }, seen: 1 }, { at: 1700003600, cpu: null, pools: {}, seen: 0 }];
  const recent = tbl([{ run_id: 7, repo: "o/r", job: "Tests", runner: "ws-1", conclusion: "failure", started: 1700000000, took: 600, url: "https://gh/j/7" }], ["started", "job", "conclusion", "took"]);
  recent.table.links = [{ started: "#infra/ci/7", job: "https://gh/j/7" }];
  const d = machinePage({ cores: 24, head: "workstation, local, up", machine: {},
    share: [{ what: "unity", cores: 6, link: "#infra/pools/unity" }, { what: "other", cores: 6, link: null }, { what: "idle", cores: 12, link: null }],
    history: { step: 120, readings: 1, hours, down: [], power: null },
    tables: { down: tbl([{ from: 1700003600, to: 1700007200, open: true, why: "no reading" }], ["from", "to", "took", "why"]), recent, alerts: tbl([], ["what"]) } });
  const h = drawPage("machines/workstation", d);
  assert.match(h, /<a href="#infra\/pools\/unity">unity<\/a> 6\.0, other 6\.0, idle 12\.0 <span class="muted">of 24 cores/);
  assert.doesNotMatch(h, /data-cloud/, "no power, no buttons");
  assert.match(h, /data-tip="[^"]*no reading"/, "an hour with no sample says so");
  assert.match(h, /<td class="warn">now<\/td>/, "an open stretch lasts now");
  assert.match(h, /<a href="#infra\/ci\/7">/);
  assert.match(h, /<td class="bad">failure<\/td>/);
});

test("a failed refresh keeps the page on screen and says so, and a governor answer shows on its own host only", () => {
  const h = drawPage("machines/aws-burst-1", machinePage(), "Could not read infra (HTTP 502)");
  assert.match(h, /refresh failed, showing the last read: Could not read infra \(HTTP 502\)/);
  assert.match(h, /data-cloud="aws-burst-1:on"/, "the page is still drawn");
  run(`Object.assign(cst, { host: "aws-burst-2", msg: "aws-burst-2: on sent" })`);
  assert.doesNotMatch(drawPage("machines/aws-burst-1", machinePage()), /aws-burst-2: on sent/);
  run(`cst.host = "aws-burst-1"`);
  assert.match(drawPage("machines/aws-burst-1", machinePage()), /aws-burst-2: on sent/);
  run(`Object.assign(cst, { host: "", msg: "" })`);
});

// A pool page as GET /api/infra/pool sends it (hub_core::pool_page plus agent-web's tables).
const poolPage = (o = {}) => ({
  pool: "unity", at: 1700000000, head: "unity, 1/3 busy, 2 waiting", errors: [],
  parts: [{ label: "Waiting", text: "2 jobs, the oldest 15m; 1 no online runner can take", link: null, warn: true },
    { label: "Grafana", text: "the CI runners board", link: "https://g.example/d/kb-ci-runners", warn: false }],
  history: null, tables: { machines: tbl([], ["machine"]), waiting: tbl([], ["job"]) }, ...o,
});
const drawPool = (name, d, err) => drawPage("pools/" + name, d, err);

test("a pool page for a name no pool has says so, from the server's 404", () => {
  const h = drawPool("nope", null, "Could not read infra (HTTP 404): no pool named nope. Retry, or check the agent-web log.");
  assert.match(h, /<div class="panel down">[^<]*no pool named nope/);
  assert.match(h, /href="#infra\/machines">All pools<\/a>/);
});

test("a pool page draws its parts, its machines and waiting jobs with their links, and its 7 days", () => {
  const machines = tbl([{ host: "workstation", where: "local", state: "up", pools: ["unity 4"], running: [] }], ["machine", "where", "state"]);
  machines.table.links = [{ machine: "#infra/machines/workstation" }];
  const waiting = tbl([{ job: "Tests", pool: "unity", n: 2, wait: 900, needs: ["unity"], can: [], stuck: true }], ["job", "n", "wait", "can"]);
  const hours = [{ at: 1700000000, busy: 1, slots: 3, waiting: 2 }, { at: 1700003600, busy: null, slots: null, waiting: null }];
  const h = drawPool("unity", poolPage({ tables: { machines, waiting }, history: { step: 120, readings: 30, hours } }));
  assert.match(h, /<span class="pgv capwarn">2 jobs, the oldest 15m; 1 no online runner can take<\/span>/);
  assert.match(h, /href="https:\/\/g\.example\/d\/kb-ci-runners" target="_blank"/);
  assert.match(h, /<a href="#infra\/machines\/workstation">workstation<\/a>/);
  assert.match(h, /<td class="bad">Tests<\/td>/, "a job no runner can take is red");
  assert.match(h, />nobody</);
  assert.match(h, /data-tip="[^"]*1\.0 busy of 3\.0 slots, 2 waiting at most"/);
  assert.match(h, /data-tip="[^"]*: no reading"/, "an hour with no sample says so");
  assert.match(h, /30 readings/);
});

test("a failed pool refresh keeps the page on screen and says so", () => {
  const h = drawPool("unity", poolPage(), "Could not read infra (HTTP 502)");
  assert.match(h, /refresh failed, showing the last read: Could not read infra \(HTTP 502\)/);
  assert.match(h, /No machine has a slot in it\./);
  assert.match(h, /Nothing waits for it\./);
});

test("each page reads its own API, a read that lands after another page opened is dropped, and a failed one keeps the last read", async () => {
  const fetch0 = ctx.fetch, asked = [];
  const answer = (body) => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => body });
  try {
    run(`st.tab = "infra"; st.page = "machines/a"; Object.assign(pgst, { page: "machines/a", data: null, err: null })`);
    ctx.fetch = async (path) => { asked.push(path); run(`st.page = "pools/b"; pgst.page = "pools/b"`); return answer(machinePage({ host: "a" })); };
    await run("refreshPage()");
    assert.equal(run("pgst.data"), null, "machine a's read does not land on pool b's page");
    ctx.fetch = async (path) => { asked.push(path); return answer(poolPage({ pool: "b" })); };
    await run("refreshPage()");
    assert.equal(run("pgst.data.pool"), "b");
    ctx.fetch = async () => ({ ok: false, status: 502, statusText: "Bad Gateway", text: async () => "" });
    await run("refreshPage()");
    assert.equal(run("pgst.data.pool"), "b", "the last read stays up");
    assert.match(run("pgst.err"), /HTTP 502/);
    assert.deepEqual(asked, ["/api/infra/machine?host=a", "/api/infra/pool?name=b"]);
  } finally {
    ctx.fetch = fetch0;
    run(`Object.assign(pgst, { page: "", data: null, err: null }); st.page = ""`);
  }
});

test("a pool has one colour in the share bar and the 7-day chart", () => {
  const hours = [{ at: 1700000000, cpu: 0.9, pools: { alpha: 2, unity: 6 }, seen: 1 }];
  const d = machinePage({ cores: 24, machine: {},
    share: [{ what: "unity", cores: 6, link: null }, { what: "alpha", cores: 2, link: null }, { what: "idle", cores: 16, link: null }],
    history: { step: 120, readings: 1, hours, down: [], power: null } });
  const colors = run(`poolColors(${JSON.stringify(d)})`);
  assert.deepEqual(Object.keys(colors), ["alpha", "unity"]);
  const h = drawPage("machines/workstation", d);
  const bar = h.match(/title="unity: 6\.0 cores"/) && h.match(/<i style="flex:6\.00;background:([^"]+)"/)[1];
  assert.equal(bar, colors.unity, "the share bar's unity is the chart's unity");
  assert.match(h, new RegExp(`<span class="chip sm" style="--c:${colors.unity.replace(/[()]/g, "\\$&")}">unity</span>`));
});
