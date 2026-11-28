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
  URLSearchParams,
  setInterval: () => 0,
  clearInterval() {},
  // Infra's show reads /api/pipelines too (ci.js), whose table the page draws: an empty one.
  fetch: async (url) => ({ ok: true, status: 200, headers: { get: () => "application/json" },
    json: async () => (url.startsWith("/api/pipelines") ? { rows: [], red: 0, errors: [], table: { q: "", state: "", sort: "", dir: "", total: 0, shown: 0, states: [], columns: [], facets: [] } } : {}) }),
});
for (const f of ["../../web-kit/kb-ui.js", "ui.js", "md.js", "charts.js", "app.js", "table.js", "infra.js", "jobs.js", "ci.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
const run = (src) => vm.runInContext(src, ctx);
const ist = run("ist");

// One shared-table read (hub_core::table Summary) and its rows, as agent-web's /api/infra sends
// each of ist.data.tables.
const col = (key) => ({ key, sort: "", next_sort: key, next_dir: "desc" });
const tbl = (rows, keys) => ({ table: { q: "", state: "", sort: "", dir: "", total: rows.length, shown: rows.length, states: [{ name: "all", n: rows.length }], columns: keys.map(col), facets: [] }, rows });
const SLOT_KEYS = ["host", "slot", "state", "pool", "ran", "usual", "job", "ref"];
const QUEUED_KEYS = ["job", "pool", "ref", "n", "wait", "needs", "can"];
const LOCAL_KEYS = ["last", "repo", "branch", "platform", "result", "failed"];
const tables = (ci) => ({
  machines: tbl([], ["machine", "state"]), pools: tbl([], ["pool"]),
  runners: tbl(ci.rows, SLOT_KEYS), queued: tbl(ci.queue, QUEUED_KEYS), local: tbl(ci.local || [], LOCAL_KEYS),
});
// Runners' three sections as drawInfra stacks them.
const section = (c) => {
  ist.data = { ok: true, tables: tables(c) };
  return run(`runnersSection(${JSON.stringify(c)}) + waitingSection() + localSection(${JSON.stringify({ day: { read: false }, ...c })})`);
};

test("the Runners inner tab lists no runs and no finished table: they are Runs and Pipelines (ci.js)", () => {
  Object.assign(ist, { open: {} });
  const h = section({ hosts: 0, slots: 0, busy: 0, queued: 0, oldest: 0, rows: [], queue: [], red: [], local: [] });
  assert.ok(!h.includes("Recent runs"), "the runs are ci.js's");
  assert.doesNotMatch(h, /Finished 24h|Failed, last 24h/, "the finished table is Pipelines', the failed list Runs' red chip");
  assert.doesNotMatch(h, /releases\/builds/, "no link to the retired Releases Builds section");
  assert.match(h, /<h3 class="sec" id="sec-local">Local Unity [\s\S]*No local Unity gate failed in 24h\./);
});

test("Runners' head links the runs that failed in 24h to Runs' red chip, once the Runs read is in", () => {
  Object.assign(ist, { open: {} });
  const bld = run("bld");
  const was = bld.data;
  bld.data = { counts: { total: 9, running: 0, queued: 0, red: 2, recent_red: 2 } };
  const c = { hosts: 1, slots: 1, busy: 0, queued: 0, oldest: 0, rows: [], queue: [], red: [], local: [] };
  assert.match(section(c), /^<h2 class="sec warn" id="sec-ci">Runners <span class="n">0<\/span><\/h2><div class="cline warn"><a href="#infra\/runs\?bs=red" [^>]*>2 failed in 24h<\/a><\/div>/);
  bld.data = { counts: { total: 9, running: 0, queued: 0, red: 0, recent_red: 0 } };
  assert.match(section(c), /^<h2 class="sec" id="sec-ci">Runners <span class="n">0<\/span><\/h2><div data-tbl/, "none failed: a plain head and no line");
  bld.data = was;
});

test("a job kind's RUNNING and MACHINES read as hub_core's Pool cells, a machine with nothing online as 0", () => {
  const p = { running: 0, machines: [{ host: "deskslim-2", slots: 5, href: "#infra/machines/deskslim-2" }, { host: "aws-spot-1", slots: 0, href: "#infra/machines/aws-spot-1" }] };
  assert.match(run(`POOL_CELLS.running(${JSON.stringify(p)})`), />0</, "no job of its kind runs: 0, never the busy slots that carry its cap");
  assert.equal(run(`"free" in POOL_COLS`), false, "no FREE column");
  assert.equal(run(`Object.keys(POOL_COLS).filter((k) => k.startsWith("done")).join()`), "done_1h,done_5h,done", "1h and 5h beside the 24h column");
  assert.match(run(`POOL_CELLS.done_1h(${JSON.stringify({ done_1h: 0 })})`), />0</, "a quiet hour is 0");
  assert.match(run(`POOL_CELLS.done_5h(${JSON.stringify({})})`), />-</, "a window nobody reported is a dash");
  assert.equal(run(`"weight" in POOL_COLS`), false, "no WEIGHT column");
  const usual = (u) => run(`POOL_CELLS.usual(${JSON.stringify({ usual: u })})`);
  assert.match(usual(1260), />21m</, "how long one usually runs, as the runners' USUAL reads");
  assert.match(usual(null), />-</, "no median yet reads a dash");
  const seats = run(`poolSeats(${JSON.stringify(p)})`);
  assert.equal(seats, '<a class="tl" href="#infra/machines/deskslim-2">deskslim-2</a> 5, <a class="tl" href="#infra/machines/aws-spot-1">aws-spot-1</a> 0');
  assert.equal(run(`poolSeats({ machines: [] })`), "-");
});

test("the Local Unity table lists each failed gate by branch and platform, newest first", () => {
  Object.assign(ist, { open: {} });
  const local = [{ repo: "unity-core-playground", branch: "feat/yard", platform: "android", result: "failure", n: 3, last: 1762900000 }];
  const h = section({ hosts: 0, slots: 0, busy: 0, queued: 0, oldest: 0, rows: [], queue: [], red: [], local });
  assert.match(h, /<td class="muted">unity-core-playground<\/td><td class="wrap">feat\/yard<\/td><td>android<\/td><td class="bad">failure<\/td><td class="n">3<\/td>/);
});

const slot = (o) => ({ host: "razer", slot: "1", state: "busy", pool: "unity", job: "PlayMode", repo: "unity", pr: "412", branch: "feat", ran: 7000, usual: 600, late: true, note: "", ...o });
const queued = (o) => ({ job: "HD tests", pool: "unity", repo: "unity", pr: "", branch: "main", n: 1, wait: 900, needs: ["unity-full", "hd-library"], can: [], missing: ["hd-library"], stuck: true, ...o });
const ci = { hosts: 2, slots: 3, busy: 1, queued: 1, oldest: 900, local: [], rows: [slot({}), slot({ slot: "2", job: "Tests", late: false, ran: 60 }), slot({ host: "mini", late: false, ran: 30, usual: null })], queue: [queued({})], red: ["HD tests (unity) needs [unity-full, hd-library]: no online runner holds hd-library"], day: { runs: 12, pass: 0.75, failed_main: 1, failed_branch: 2, cancelled: 1, local: 4, local_pass: 0.5, read: true } };

test("CI runners: a job nobody can take is a red line naming the missing label, and a late run is marked", () => {
  Object.assign(ist, { open: {} });
  const h = section(ci);
  assert.match(h, /^<h2 class="sec bad" id="sec-ci">Runners <span class="n">3<\/span><\/h2>/, "a job nobody can take hues the head red");
  assert.match(h, /<div class="panel down">[\s\S]*HD tests \(unity\) needs \[unity-full, hd-library\]: no online runner holds hd-library/);
  assert.match(h, /<td class="n warn">1h 57m!<\/td>/);
  assert.ok(!/<td class="(bad|muted)">(off|idle)<\/td>/.test(h), "a runner with no job has no row");
  assert.match(h, /<td class="bad">HD tests<\/td>/, "a stuck queued job is red");
  assert.match(h, /<td class="wrap">nobody<\/td>/);
});

test("CI runners: a GitHub-hosted job waits on GitHub, not on nobody", () => {
  Object.assign(ist, { open: {} });
  const h = section({ ...ci, red: [], queue: [queued({ pool: "github-hosted", needs: ["ubuntu-24.04"], missing: [], stuck: false })] });
  assert.ok(!h.includes('class="panel down"'), "no red panel");
  assert.match(h, /<td class="wrap">GitHub<\/td>/);
  assert.ok(!h.includes(">nobody<"));
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
  const instant = { cc: [] };
  ist.data = { ok: true, at: Date.now() / 1e3, instant, kpis: [{ name: "WATCHES", value: "0 tripped", detail: "", sub: "", level: "ok", href: "#alerts/watches" }], down: [], ci: { ...ci }, tables: tables(ci) };
  run(`st.tab = "infra"; st.arg = "machines"; renderInfra()`);
  const main = els["infra-main"].innerHTML;
  const at = (s) => main.indexOf(s);
  assert.ok(main.startsWith('<div class="seg fseg istrip" role="tablist">'), main);
  for (const gone of ['id="sec-red"', 'id="sec-fixes"', 'id="sec-health"', 'data-itab="reds"']) assert.equal(at(gone), -1, `${gone} moved to Alerts`);
  // The count: the red CI line on Runners; none on Machines or Jobs.
  assert.match(main, /data-itab="runners" [^>]*>Runners <span class="pill warn">1<\/span>/);
  assert.match(main, /data-itab="runs" [^>]*>Runs<\/button><button [^>]*data-itab="pipelines" [^>]*>Pipelines<\/button><button [^>]*data-itab="tests" [^>]*>Tests<\/button><button [^>]*data-itab="jobs"/, "the strip's order");
  assert.match(main, /data-itab="machines" class="on" [^>]*>Machines<\/button>/);
  assert.match(main, /data-itab="jobs" [^>]*>Jobs<\/button>/);
  // The open inner tab shows; another one's sections are in the page, hidden.
  assert.match(main, /<div data-in="machines"><div class="tiles roomy">[\s\S]*<h2 class="sec" id="sec-machines">/);
  assert.match(main, /href="#alerts\/watches"/, "the watches tile opens Alerts' Watches");
  assert.match(main, /<div data-in="runners" hidden><h2 class="sec bad" id="sec-ci">Runners /);
  assert.match(main, /<div data-in="runners" hidden><h3 class="sec" id="sec-waiting">/);
  assert.match(main, /<div data-in="runners" hidden><h3 class="sec" id="sec-local">/);
  // The old Governor and Cloud sections are Machines now (layout::MOVED); Job kinds join Machines.
  for (const gone of ['id="sec-governor"', 'id="sec-cloud"']) assert.equal(at(gone), -1, `${gone} folded into Machines`);
  assert.match(main, /<div data-in="machines"><h2 class="sec" id="sec-pools">Job kinds <span class="n">0<\/span><\/h2>/);
  // Jobs is its own element (jobs.js paints it): it joins the Jobs group and hides here.
  assert.equal(els.jobs.dataset.in, "jobs");
  assert.equal(els.jobs.hidden, true);
  run(`st.arg = "jobs"; renderInfra()`);
  assert.equal(els.jobs.hidden, false);
  // "CI runs finished today" starts open like every section; a fold the reader closed stays closed.
  // Runs, Pipelines and Tests are ci.js's elements, each in its own group.
  for (const [id, inner] of [["ci-runs", "runs"], ["ci-pipelines", "pipelines"], ["ci-tests", "tests"]]) assert.equal(els[id].dataset.in, inner, id);
  run(`st.arg = "runners"; renderInfra()`);
  assert.match(els["infra-main"].innerHTML, /data-k="ci-more" open><summary><h3 class="sec">CI runs finished today<\/h3><\/summary>/, "the fold's summary is its head alone");
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
  // The retired CI inner tab is Runners, at its head; Runs, Pipelines and Tests are inner tabs.
  assert.deepEqual(r("#infra/ci"), ["infra", "runners", "ci"]);
  assert.deepEqual(r("#infra/runners"), ["infra", "runners", undefined]);
  assert.deepEqual(r("#infra/pipelines"), ["infra", "pipelines", undefined]);
  assert.deepEqual(r("#infra/local"), ["infra", "runners", "local"]);
  // The old Governor section is plain Machines, the old Cloud one Machines under its chip (layout::MOVED).
  assert.deepEqual(r("#infra/governor"), ["infra", "machines", "machines"]);
  assert.ok(!ctx.route("#infra/governor").query, "no governed chip is left to open");
  assert.equal(ctx.route("#infra/cloud").query, "ms=cloud");
  assert.deepEqual(r("#infra/jobs"), ["infra", "jobs", undefined]);
  // Red now, Red fixes (and the Reds inner tab) and health moved to Alerts (layout::MOVED), each
  // on the Alerts inner tab holding it; health opens with Firing.
  assert.deepEqual(r("#infra/reds"), ["alerts", "fixes", "fixes"]);
  assert.deepEqual(r("#infra/fixes"), ["alerts", "fixes", "fixes"]);
  assert.deepEqual(r("#infra/red"), ["alerts", "firing", "firing"]);
  assert.deepEqual(r("#infra/health"), ["alerts", "firing", "health"]);
  // The retired #ci, #machines and #jobs tabs (layout::section) land on their inner tab too.
  assert.deepEqual(r("#ci"), ["infra", "runners", "ci"]);
  assert.deepEqual(r("#machines"), ["infra", "machines", "machines"]);
  assert.deepEqual(r("#jobs"), ["infra", "jobs", "jobs"]);
});

test("a record's page inside an inner tab keeps its id: the route opens the inner tab, the URL keeps the page", () => {
  const r = (h) => { const x = ctx.route(h); return [x.tab, x.arg, x.page]; };
  assert.deepEqual(r("#infra/machines/razer-laptop"), ["infra", "machines", "machines/razer-laptop"]);
  assert.deepEqual(r("#infra/pools/unity"), ["infra", "machines", "pools/unity"], "a pool's page is on Machines");
  assert.deepEqual(r("#infra/runs/4412"), ["infra", "runs", "runs/4412"]);
  assert.deepEqual(r("#infra/ci/4412"), ["infra", "runs", "ci/4412"], "the retired run URL still opens the run, on Runs");
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
  run(`innerGo("infra", "runs")`);
  assert.equal(urls.at(-1), "#infra/runs", "another inner tab leaves the page");
  delete ctx.history;
});

// A machine page as GET /api/infra/machine sends it (hub_core::machine_page plus agent-web's
// tables), the few fields each test reads.
const machinePage = (o = {}) => ({
  host: "aws-burst-1", at: 1700000000, head: "aws-burst-1, cloud, no data", errors: [],
  parts: [{ label: "Now", text: "no reading: Prometheus has no node exporter series for it", link: null, warn: true },
    { label: "Grafana", text: "its fleet board", link: "https://g.example/d/kb-fleet?var-host=aws-burst-1", warn: false }],
  machine: {}, cores: null, running: [], history: null,
  live: null, tables: { slots: tbl([], ["slot"]), down: tbl([], ["from"]), recent: tbl([], ["job"]), alerts: tbl([], ["what"]), ...liveTables() }, ...o,
});
// The tables a machine page's live part rides in (hub_core::host_now), empty unless given.
const liveTables = (o = {}) => ({ devices: tbl([], ["device"]), pods: tbl([], ["pod"]), containers: tbl([], ["name"]), processes: tbl([], ["name"]), sessions: tbl([], ["project"]), ...o });
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

test("a machine page with no reading says why, in amber", () => {
  const h = drawPage("machines/aws-burst-1", machinePage());
  assert.match(h, /<span class="pgv capwarn">no reading: Prometheus has no node exporter series for it<\/span>/);
  assert.match(h, /href="https:\/\/g\.example\/d\/kb-fleet\?var-host=aws-burst-1" target="_blank"/);
  assert.match(h, /No runner and no core reading\./);
  assert.match(h, /Nothing firing names it\./);
});

test("a machine page draws its slots, its 7 days and its recent jobs with their links", () => {
  const hours = [{ at: 1700000000, cpu: 0.5, pools: { unity: 6 }, seen: 1 }, { at: 1700003600, cpu: null, pools: {}, seen: 0 }];
  const recent = tbl([{ run_id: 7, repo: "o/r", job: "Tests", runner: "ws-1", conclusion: "failure", started: 1700000000, took: 600, url: "https://gh/j/7" }], ["started", "job", "conclusion", "took"]);
  recent.table.links = [{ started: "#infra/ci/7", job: "https://gh/j/7" }];
  const G = 1024 ** 3;
  const slot = (o) => ({ takes: [], now: "", job: "", cores: null, cores_max: null, mem: null, mem_max: null, disk: null, disk_age: null, runner: true, ...o });
  const slots = tbl([
    slot({ slot: "ws-unity-1", takes: ["unity", "light"], now: "busy", job: "o/r / Tests", cores: 2.8, cores_max: 3, mem: 11.2 * G, mem_max: 14 * G, disk: 58 * G, disk_age: 600 }),
    slot({ slot: "ws-unity-2", now: "idle" }),
    slot({ slot: "idle", cores: 12, runner: false }),
  ], ["slot", "takes", "now", "job", "cores", "mem", "disk"]);
  const d = machinePage({ cores: 24, head: "workstation, local, up", machine: {},
    history: { step: 120, readings: 1, hours, down: [] },
    tables: { slots, down: tbl([{ id: "workstation@2023-11-14T23:13:20Z", from: 1700003600, to: 1700007200, cause: "unknown", why: "no sibling dropped" }], ["from", "to", "took", "cause", "why"]), recent, alerts: tbl([], ["what"]), ...liveTables() } });
  const h = drawPage("machines/workstation", d);
  assert.match(h, /Slots <span class="n">1 of 2 busy<\/span>/);
  assert.match(h, /<a class="tl" href="#infra\/pools\/unity">unity<\/a> <a class="tl" href="#infra\/pools\/light">light<\/a>/);
  assert.match(h, /<td class="n">2\.8\/3<\/td><td class="n">11\.2\/14G<\/td><td class="n" title="read 10m ago">58G<\/td>/);
  // The negative control: a slot with no series says no data, never 0.
  assert.match(h, /ws-unity-2<\/td>[\s\S]*?(<td class="n muted">no data<\/td>){3}/);
  assert.match(h, /<td class="muted">idle<\/td>[\s\S]*?<td class="n">12\.0<\/td><td class="n"><\/td>/);
  assert.match(h, /data-tip="[^"]*no data"/, "an hour with no sample says so");
  assert.match(h, /<td class="warn">unknown<\/td><td class="muted">no sibling dropped<\/td>/, "an unexplained downtime reads amber, with its evidence");
  assert.match(h, /<a class="tl" href="#infra\/ci\/7">/);
  assert.match(h, /<td class="bad">failure<\/td>/);
});

test("a machine page draws its sensors hot in amber, its pods, containers, processes, agent sessions, services and hourly temperature", () => {
  const devices = tbl([{ device: "cpu", chip: "k10temp", hottest: 96, temps: [["Tctl", 96], ["Tccd1", 91]], fans: [] },
    { device: "gpu", chip: "amdgpu", hottest: 52, temps: [["edge", 52]], fans: [["fan1", 616]] }], ["device", "hottest", "readings", "chip"]);
  const pods = tbl([{ namespace: "frigate", pod: "frigate-0", cpu: 0.7, mem: 2.5 * 2 ** 30 }], ["pod", "namespace", "cpu", "mem"]);
  const containers = tbl([{ name: "mailpit", image: "axllent/mailpit", cpu: 0.01, mem: 3e7, count: null }], ["name", "image", "cpu", "mem"]);
  const processes = tbl([{ name: "Unity", image: "", cpu: 3.5, mem: 8e9, count: 2 }], ["name", "cpu", "mem", "count"]);
  const sessions = tbl([{ project: "dotfiles", item: "ar-4859", cpu: 1.5, mem: 2e9, tests: "bats 1.20" }], ["project", "item", "cpu", "mem", "tests"]);
  const hours = [{ at: 1700000000, cpu: 0.5, pools: {}, seen: 1, temp: 97 }, { at: 1700003600, cpu: null, pools: {}, seen: 0, temp: null }];
  const d = machinePage({ machine: {}, history: { step: 120, readings: 1, hours, down: [] },
    live: { services: ["nfs-server", "tailscaled"], processes_total: 612, inventory: true, unread: {} },
    tables: { slots: tbl([], ["slot"]), down: tbl([], ["from"]), recent: tbl([], ["job"]), alerts: tbl([], ["what"]), ...liveTables({ devices, pods, containers, processes, sessions }) } });
  const h = drawPage("machines/workstation", d);
  assert.match(h, /No downtime record in the window\. One is written once a downtime ends\./);
  // The negative control: a records read that failed says not read and why, never the empty text.
  const unread = drawPage("machines/workstation", { ...d, history: { ...d.history, down_unread: "Loki answer 503" } });
  assert.match(unread, /Downtime<\/h3><div class="empty">not read: Loki answer 503<\/div>/);
  assert.doesNotMatch(unread, /No downtime record/);
  assert.match(h, /<h3 class="sec warn">Sensors <span class="n">2<\/span>/, "a sensor at 85C or more makes the heading amber");
  assert.match(h, /<td class="n warn">96C<\/td>/);
  assert.match(h, /Tctl 96C  Tccd1 91C/);
  assert.match(h, /edge 52C  fan1 616rpm/);
  assert.match(h, /frigate-0<\/td><td class="muted">frigate<\/td><td class="n">0\.70<\/td><td class="n">2\.5G<\/td>/);
  assert.match(h, /axllent\/mailpit/);
  assert.match(h, /Processes <span class="n">busiest 1 of 612<\/span>/);
  assert.match(h, /<td class="n">7\.5G<\/td><td class="n">2<\/td>/);
  assert.match(h, /Agent sessions <span class="n">1<\/span>/);
  assert.match(h, /ar-4859[\s\S]*bats 1\.20/);
  assert.match(h, /nfs-server   tailscaled/);
  assert.match(h, /data-tip="[^"]*hottest 97C"/);
  const off = drawPage("machines/workstation", { ...d, live: { ...d.live, inventory: false } });
  assert.match(off, /Not collected: no node_inventory\.prom/);
  assert.doesNotMatch(off, /Services/);
  assert.match(drawPage("machines/aws-burst-1", machinePage()), /Sensors[\s\S]*not read\./, "no live read says so");
  const failed = drawPage("machines/workstation", { ...d, live: { ...d.live, inventory: false, unread: { sensors: "prometheus down", pods: "prometheus down", inventory: "prometheus down" } } });
  assert.equal(failed.match(/not read: prometheus down/g).length, 3, "a failed part says not read, not none");
  assert.doesNotMatch(failed, /Not collected|No Kubernetes pod/);
});

test("a failed refresh keeps the page on screen and says so", () => {
  const h = drawPage("machines/aws-burst-1", machinePage(), "Could not read infra (HTTP 502)");
  assert.match(h, /refresh failed, showing the last read: Could not read infra \(HTTP 502\)/);
  assert.match(h, /Sensors/, "the page is still drawn");
});

// A pool page as GET /api/infra/pool sends it (hub_core::pool_page plus agent-web's tables).
const poolPage = (o = {}) => ({
  pool: "unity", at: 1700000000, head: "unity, 1 running, 2 waiting", errors: [],
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
  const machines = tbl([{ host: "workstation", state: "up", running: ["unity x4"], next: null }], ["machine", "state", "running"]);
  machines.table.links = [{ machine: "#infra/machines/workstation" }];
  const waiting = tbl([{ job: "Tests", pool: "unity", n: 2, wait: 900, needs: ["unity"], can: [], stuck: true }], ["job", "n", "wait", "can"]);
  const hours = [{ at: 1700000000, running: 1, waiting: 2 }, { at: 1700003600, running: null, waiting: null }];
  const h = drawPool("unity", poolPage({ tables: { machines, waiting }, history: { step: 120, readings: 30, hours } }));
  assert.match(h, /<span class="pgv capwarn">2 jobs, the oldest 15m; 1 no online runner can take<\/span>/);
  assert.match(h, /href="https:\/\/g\.example\/d\/kb-ci-runners" target="_blank"/);
  assert.match(h, /<a class="tl" href="#infra\/machines\/workstation">workstation<\/a>/);
  assert.match(h, /<td class="bad">Tests<\/td>/, "a job no runner can take is red");
  assert.match(h, />nobody</);
  assert.match(h, /data-tip="[^"]*1\.0 running, 2 waiting at most"/);
  assert.match(h, /data-tip="[^"]*: no data"/, "an hour with no sample says so");
  assert.match(h, /<h3 class="sec">7 days <span class="n">30 readings<\/span><\/h3>/);
  assert.match(h, /<h3 class="sec">Machines <span class="n">1<\/span><\/h3>/);
  assert.match(h, /<h3 class="sec">Waiting <span class="n">1<\/span><\/h3>/);
  assert.match(h, /<div class="bhead"><span>unity, 1 running, 2 waiting<\/span><a class="btn sm"/);
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

test("a pool has one colour in the 7-day chart, set by its history", () => {
  const hours = [{ at: 1700000000, cpu: 0.9, pools: { alpha: 2, unity: 6 }, seen: 1 }];
  const d = machinePage({ cores: 24, machine: {},
    history: { step: 120, readings: 1, hours, down: [] } });
  const colors = run(`poolColors(${JSON.stringify(d)})`);
  assert.deepEqual(Object.keys(colors), ["alpha", "unity"]);
  assert.notEqual(colors.alpha, colors.unity);
  const h = drawPage("machines/workstation", d);
  assert.match(h, new RegExp(`<span class="chip sm" style="--c:${colors.unity.replace(/[()]/g, "\\$&")}">unity</span>`));
});

// hub_core::ci::Glance as /api/infra sends it under ci.glance.
const glance = { busy: 5, queued: 23, oldest: 1260, done: 759, pass: 0.91,
  units: { total: 64, taken: 4.38, free: 59.62, real: 9.6, brief: "taken 4.4/64 units (7%)", head: "CI POOL  64 units (1 unit = 1 CI core)",
    line: "taken 4.4 of 64 (7%), free 59.6, real use 9.6 (15%)", columns: ["TAKEN BY", "PODS", "EACH", "UNITS", "SHARE"],
    rows: [["arc-org-light", "2", "1.69", "3.4", "5%"], ["other", "-", "-", "1.0", "2%"], ["free", "", "", "59.6", "93%"]] }, pending: [{ kind: "arc-org-light", n: 3, cpu: 1.69, mem: 1.3e9 }], alert: "ok", up: 12, expected: 12,
  head: "5 running, 23 queued (oldest 21m), taken 4.4/64 units (7%), 12/12 runners up, 759 done 24h, 91% passed",
  pending_line: "waiting for room: arc-org-light x3 (1.69 cpu 1.2G each)" };

// hub_core::infra::Kpi as /api/infra sends it under kpis: the tile's value, lines and hue are
// judged in Rust (Infra::kpis, tested there against the rollup's rows), so the page only draws.
const kpi = (name, value, sub, level, href) => ({ name, value, detail: "", sub, level, ...(href ? { href } : {}) });
const tiles = [kpi("NODES", "13/14", "k3s rollup OK", "ok"), kpi("HEARTBEATS", "22/22", "machines rollup WARN", "warn"),
  kpi("CI RUNNING", "5", "23 queued, 12/12 runners up; ci rollup RED", "red"), kpi("AGENT RUNNERS", "6 failed", "of 122; agents rollup NO DATA", "nodata"),
  kpi("WATCHES", "13 tripped", "of 133, 0 stale; watches rollup WARN", "warn", "#alerts/watches"), kpi("SESSIONS", "3/9", "working, 0 need you", null)];
test("the Infra tiles draw hub_core's kpis: its value, its lines and its level's hue", () => {
  const h = run(`kpis(${JSON.stringify(tiles)})`);
  const hue = (name) => h.match(new RegExp(`--c:var\\((--[a-z0-9-]+)\\)"><span class="tl">${name}`))?.[1];
  assert.equal(hue("NODES"), "--b-done");
  assert.equal(hue("HEARTBEATS"), "--b-stalled");
  assert.equal(hue("CI RUNNING"), "--b-needs");
  assert.equal(hue("AGENT RUNNERS"), "--c-other", "no data is its own hue, never green");
  assert.equal(hue("SESSIONS"), "--b-working", "a count with no verdict is not red or green");
  assert.match(h, /AGENT RUNNERS<\/span><span class="tv">6 failed<\/span><span class="ts1">of 122; agents rollup NO DATA/);
  assert.match(h, /CI RUNNING[\s\S]*?>5<[\s\S]*?23 queued, 12\/12 runners up; ci rollup RED/);
  assert.match(h, /<a class="tile" href="#alerts\/watches"[^>]*><span class="tl">WATCHES/, "the tile links where the server says");
  // SPEND (a link to Costs) is the page's own and sits before SESSIONS.
  assert.ok(h.indexOf(">SPEND<") > h.indexOf(">WATCHES<") && h.indexOf(">SPEND<") < h.indexOf(">SESSIONS<"));
});

// ar-5013: the pill is the heart's word and colour; warn domains, which never colour it, follow
// as a count naming them in its hover, so OK beside amber tiles says why.
test("the OVERALL pill keeps the heart's verdict and counts the warn domains beside it", () => {
  const pill = (cc) => run(`overallPill(${JSON.stringify(cc)})`);
  const ok = pill({ "cc:overall_status": { "": 0 }, "cc:domain_status": { ci: 1, k3s: 1, prod: 0, platform: 0 } });
  assert.match(ok, /--c:var\(--b-done\)"[^>]*>OVERALL OK<\/span>/, "a warn never colours the heart");
  assert.match(ok, /<span class="chip sm" style="--c:var\(--b-stalled\)" title="at warn: ci, k3s; Alerts&#39; health chips say why">2 warn<\/span>/);
  // negative control: no warn domain, no count; a red heart stays red with its warns beside it
  assert.doesNotMatch(pill({ "cc:overall_status": { "": 0 }, "cc:domain_status": { ci: 0 } }), /warn<\/span>/);
  const red = pill({ "cc:overall_status": { "": 2 }, "cc:domain_status": { platform: 2, ci: 1 } });
  assert.match(red, /--c:var\(--b-needs\)"[^>]*>OVERALL RED<\/span>.*title="at warn: ci;[^"]*">1 warn</);
  assert.match(pill({}), /OVERALL NO DATA/i);
});

test("the Runners head and the waiting line are hub_core's glance words, drawn as sent", () => {
  Object.assign(ist, { open: {} });
  const s = section({ rows: [], queue: [], red: [], local: [], glance });
  assert.match(s, /<div class="cline">5 running, 23 queued \(oldest 21m\), taken 4\.4\/64 units \(7%\), 12\/12 runners up, 759 done 24h, 91% passed<\/div>/);
  // The CI POOL block under the head: Rust's head and line beside a bar of the share taken, then
  // TAKEN BY with its cells as sent, a free row last.
  assert.match(s, /<b>CI POOL  64 units \(1 unit = 1 CI core\)<\/b>[\s\S]*?<span style="width:6\.8%;[^"]*"><\/span><\/span> taken 4\.4 of 64 \(7%\), free 59\.6, real use 9\.6 \(15%\)/);
  assert.match(s, /<th data-role="lead" data-label="TAKEN BY">TAKEN BY<\/th><th class="n" data-label="PODS">PODS<\/th>[\s\S]*?<th class="n" data-role="glance" data-named data-label="SHARE">SHARE/);
  assert.match(s, /<tr><td>arc-org-light<\/td><td class="n">2<\/td><td class="n">1\.69<\/td><td class="n">3\.4<\/td><td class="n">5%<\/td><\/tr><tr><td>other<\/td>/);
  assert.match(s, /<td>free<\/td><td class="n"><\/td><td class="n"><\/td><td class="n">59\.6<\/td><td class="n">93%<\/td>/);
  // No CI node read draws no pool.
  const bare = section({ rows: [], queue: [], red: [], local: [], glance: { ...glance, units: null, head: "5 running, 23 queued (oldest 21m), -/- runners up, 759 done 24h" } });
  assert.match(bare, /5 running, 23 queued \(oldest 21m\), -\/- runners up, 759 done/);
  assert.doesNotMatch(bare, /CI POOL/);
  // Pods no CI node has room for: one line under the machines, as Rust says it; none when none wait.
  assert.equal(run(`pendingLine(${JSON.stringify(glance)})`), '<div class="cline warn">waiting for room: arc-org-light x3 (1.69 cpu 1.2G each)</div>');
  assert.equal(run(`pendingLine(${JSON.stringify({ ...glance, pending_line: null })})`), "");
});

// hub_core::workload::Space as /api/infra sends it under space.
const space = {
  head: "cores 54 of 236 busy, mem 310 of 640G, 17 of 19 machines read", no_split_note: "no split: mac-mini (no node inventory there)",
  done: 759, done_link: "#infra", columns: ["class", "cores used", "reserved", "room", "mem used", "reserved", "machines"],
  classes: [
    { cells: ["ci", "31.2", "48", "16.8", "120G", "200G", "9"], note: "" },
    { cells: ["agents", "9.1", "-", "-", "40G", "-", "6"], note: "run units 6.4 of 16" },
    { cells: ["other", "no data", "-", "-", "no data", "-", "0"], note: "" },
  ],
};

test("Space leads Machines with the cluster's split by class, laid out as hub_core words it", () => {
  const h = run(`spaceSection(${JSON.stringify(space)})`);
  assert.match(h, /^<h3 class="sec">Space<\/h3>/);
  assert.match(h, /cores 54 of 236 busy, mem 310 of 640G, 17 of 19 machines read <span class="muted">done <\/span><a class="tl" href="#infra">24h 759<\/a>/);
  assert.match(h, /<th data-role="lead" data-label="class">class<\/th><th class="n" data-role="" data-label="cores used">cores used<\/th>/);
  assert.match(h, /<td>agents<\/td><td class="n">9\.1<\/td><td class="n">-<\/td>[\s\S]*<td class="muted wrap">run units 6\.4 of 16<\/td>/);
  // The negative control: an unread class says no data, never 0.
  assert.match(h, /<td>other<\/td><td class="n">no data<\/td>/);
  assert.match(h, /no split: mac-mini \(no node inventory there\)<\/div>$/);
});

test("Space says no data before the first read and when no class series exists, never an empty table", () => {
  assert.match(run("spaceSection(null)"), /Space <span class="n">no data<\/span>[\s\S]*<div class="empty">no data<\/div>/);
  const bare = run(`spaceSection(${JSON.stringify({ ...space, classes: [], head: "cores no data, mem no data, 0 of 0 machines read", done: 0 })})`);
  assert.match(bare, /cores no data, mem no data, 0 of 0 machines read<\/div><div class="empty">no data<\/div>/);
  assert.doesNotMatch(bare, /<table/);
  assert.doesNotMatch(bare, /24h/, "no jobs done, no badge");
});

test("a machine's BOOKED cell hover leads with its split by class, then each runner", () => {
  const m = { split: ["ci 6.0 of 24 cores", "apps 1.0 cores"], runner_cores: [["ws-unity-1", 2.5]], runner_mem: [] };
  const t = run(`cpuTitle(${JSON.stringify(m)})`);
  assert.equal(t.split("\n")[0], "ci 6.0 of 24 cores");
  assert.match(t, /\n\nws-unity-1: 2\.5 cores/);
  assert.equal(run(`cpuTitle(${JSON.stringify({ ...m, split: [] })})`), run(`runnerTitle(${JSON.stringify({ ...m, split: [] })})`));
});

test("a class row on the slots table shows its memory in gigabytes", () => {
  const cell = run(`SLOTUSE_CELLS.mem(${JSON.stringify({ runner: false, mem: 4 * 2 ** 30 })})`);
  assert.match(cell, /4\.0G/);
  assert.doesNotMatch(run(`SLOTUSE_CELLS.mem(${JSON.stringify({ runner: false, mem: null })})`), /G</);
});

test("a machine's BOOKED, RUNNING and NEXT read as hub_core's Machine cells, no CI node as a dash", () => {
  const booked = { cpu: 4.38, cpu_alloc: 32, mem: 2.7e9, mem_alloc: 98768805888 };
  const m = { split: [], runner_cores: [], runner_mem: [], off: 0, level: { booked: "ok" }, booked, running: ["[arc-org-light] x2", "[unity] platform"], next: { job: "Checks", repo: "web", n: 1, wait: 300 } };
  const cell = run(`MACH_CELLS.booked(${JSON.stringify(m)})`);
  assert.match(cell, /class="meter"/);
  assert.match(cell, /4\.4\/32 2\.5G\/92G/);
  assert.doesNotMatch(cell, /warn/);
  assert.match(run(`MACH_CELLS.booked(${JSON.stringify({ ...m, level: { booked: "warn" } })})`), /class="n warn"/, "the hue is Rust's level for the cell");
  const lost = run(`MACH_CELLS.booked(${JSON.stringify({ ...m, booked: { cpu: 1.69, cpu_alloc: 0, mem: 1.3e9, mem_alloc: 0 } })})`).replace(/<[^>]*>/g, "");
  assert.match(lost, /1\.7 1\.2G/, "a node with no allocatable read books bare, as Booked::cell");
  assert.doesNotMatch(lost, /\/0/);
  assert.equal(run("cores1(0.15)"), "0.2", "halves round up, as Rust and jq round them");
  assert.match(run(`MACH_CELLS.running(${JSON.stringify(m)})`), /\[arc-org-light\] x2, \[unity\] platform/);
  assert.match(run(`MACH_CELLS.next(${JSON.stringify(m)})`), />Checks \(web\) 5m</);
  const bare = { ...m, booked: null, running: [], next: null };
  assert.equal(run(`MACH_CELLS.booked(${JSON.stringify(bare)})`).replace(/<[^>]*>/g, ""), "-");
  assert.match(run(`MACH_CELLS.running(${JSON.stringify(bare)})`), />-</);
  assert.match(run(`MACH_CELLS.next(${JSON.stringify(bare)})`), />-</);
  assert.equal(run(`"busy" in MACH_COLS || "doing" in MACH_COLS`), false);
});

// hub_core::machines::Levels as a Machine row sends it under level, a pool's pass_level: the page
// holds no threshold, it only turns a level into a class.
test("a machine's cells and a pool's PASS take their hue from the served level", () => {
  const m = { host: "w", core_busy: [], cpu: 0.5, mem: 0.5, load: 1, cores: 8, temp: 60, disk: 0.05, where: "cloud", split: [], runner_cores: [], runner_mem: [],
    level: { cpu: "ok", mem: "warn", load: "warn", temp: "warn", disk: "bad", booked: "ok" } };
  const cell = (k, row = m) => run(`MACH_CELLS.${k}(${JSON.stringify(row)})`);
  assert.match(cell("mem"), /var\(--b-stalled\)/, "mem past its line is amber");
  assert.match(cell("load"), /class="n warn"/);
  assert.match(cell("temp"), /class="n warn"/);
  assert.match(cell("disk"), /class="n bad"/);
  // negative control: the same readings at ok level draw no hue, whatever the numbers say
  const ok = { ...m, level: { cpu: "ok", mem: "ok", load: "ok", temp: "ok", disk: "ok", booked: "ok" } };
  assert.doesNotMatch(cell("load", ok) + cell("temp", ok) + cell("disk", ok), /warn|bad/);
  assert.match(cell("disk", { ...ok, disk: null, level: { ...ok.level, disk: "neutral" } }), /class="n muted"/);
  const pool = (l) => run(`POOL_CELLS.pass(${JSON.stringify({ pass: 0.5, pass_level: l })})`);
  assert.match(pool("bad"), /class="n bad"/);
  assert.match(pool("warn"), /class="n warn"/);
  assert.doesNotMatch(pool("ok"), /bad|warn/);
});
