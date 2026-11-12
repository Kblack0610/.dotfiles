// Unit tests for the Releases tab (.local/src/agent-web/static/releases.js), run by `node --test`
// from tests/unit/agent_web_queue.bats. The page's real scripts load into one vm context, as the
// browser loads them; only the DOM is a stub. What an app row says is hub_core::releases,
// tested in Rust; this checks that the page draws them and turns each click into the view it asks for.
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
const box = Object.assign(part(), { addEventListener: (ev, f) => { (on[ev] ||= []).push(f); } });
const fire = (ev, e) => (on[ev] || []).forEach((f) => f(e));
const parts = { "rel-head": part(), "rel-facets": part(), "rel-chips": part(), "rel-body": part(), "rel-tail": part(), "relrun-head": part(), "relrun-facets": part(), "relrun-chips": part(), "relrun-body": part() };
const doc = { body: el(), getElementById: (id) => (id === "releases" ? box : parts[id] || el()), addEventListener() {}, querySelector: el, querySelectorAll: () => [], createElement: el, activeElement: null, hidden: false };
const asked = [];
let body = {};
let cl = {};
let builds = {};
let detail = {};
const loc = { pathname: "/", hash: "" };
const ctx = vm.createContext({
  console,
  document: doc,
  window: { addEventListener() {} },
  URLSearchParams,
  setInterval: () => 0,
  clearInterval() {},
  location: loc,
  history: { url: "", replaceState(a, b, u) { this.url = u; } },
  fetch: async (url) => {
    asked.push(url);
    const text = url.startsWith("/api/builds/log");
    const json = url.startsWith("/api/builds/detail") ? detail : url.startsWith("/api/builds") ? builds : url.startsWith("/api/releases/changelog") ? cl : body;
    return { ok: true, status: 200, headers: { get: () => (text ? "text/plain" : "application/json") }, json: async () => json, text: async () => "FAIL: step 3 exited 1" };
  },
});
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "log.js", "table.js", "infra.js", "actions.js", "jobs.js", "ci.js", "schedules.js", "releases.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx);
const run = (src) => vm.runInContext(src, ctx);
const relst = run("relst");
const settled = () => new Promise((r) => setImmediate(r));

const col = (key) => ({ key, sort: null, next_sort: key, next_dir: "desc" });
const table = {
  q: "", state: "", sort: "", dir: "", total: 2, shown: 2,
  states: [{ name: "all", n: 2 }, { name: "attention", n: 1 }, { name: "ok", n: 1 }],
  columns: ["project", "stage", "live", "status", "channels", "released", "last_deploy"].map(col),
  facets: [],
};
const NOW = () => Math.round(Date.now() / 1e3);
const drift = {
  project: "binks", channel: "prod", id: "binks-prod", label: "prod binks-prod", where: "home-k3s", tag: "v2", status: "drift", status_text: "drift", status_level: "bad", watch_level: "bad", level: "bad",
  pinned: { value: "v2", source: "manifest" }, live: { value: "v1", source: "k8s", image: "reg/binks:v1", error: null },
  pinned_text: "v2", live_text: "v1", telemetry_text: "0/1", deps_text: "unity-core v0.5.0", deps: ["unity-core"],
  telemetry: [{ watch: "binks-probe", state: "TRIP", level: "bad", since: 1793942659 }], drift_since: 1793942659, probed_at: 1793942700,
  prev_text: "v0", last_deploy_text: "11-06 15:00 fail", deploy_level: "warn",
  deploys: { source: "o/r", error: null, prev: "v0", last: { version: "v2", state: "fail", at: 1793942659 }, history: [
    { version: "v2", state: "fail", at: 1793942659, url: "https://github.test/run/9" },
    { version: "v1", state: "ok", at: 1793942000, url: "javascript:alert(1)" },
  ] },
};
const unread = {
  ...drift, channel: "beta", id: "binks-steam-beta", label: "beta binks-steam-beta", where: "steam", status: "unknown", status_text: "not read", status_level: "warn", level: "warn",
  pinned: { value: null, source: "tag" }, live: { value: null, source: "steam", image: null, error: "steam GetAppBetas failed" },
  pinned_text: "-", live_text: "?", telemetry: [], drift_since: null, deploys: { source: "o/r", error: null, prev: null, last: null, history: [] },
};
const binks = {
  project: "binks", live_text: "v1 prod", status: "drift", status_text: "drift", level: "bad", channels_text: "1 drift, 1 not read", unread: 1,
  last_deploy_text: "11-06 15:00 fail", deploy_level: "warn", channels: [drift, unread], lead: 1, others_text: "beta 1 not read",
  stage: "alpha", stage_text: "alpha: no alpha target deployed", stage_level: "warn", coverage_text: "prev 1/1, deployed 1/2 (1 none declared)",
  builds: [
    { tag: "binks-v3", workflow: "Release builds", state_text: "in progress 12m", level: "ok", live: true, started_text: "11-11 16:20", ended_text: "-", url: "https://github.com/o/binks/actions/runs/30" },
    { tag: "binks-v2", workflow: "Steam (binks)", state_text: "cancelled", level: "ok", live: false, started_text: "11-05 10:00", ended_text: "11-05 10:01", url: "javascript:alert(1)" },
  ],
  line: "release", released_text: "v2 11-05", history: [
    { tag: "binks-v2", version: "2", at: 1793900000, at_text: "11-05", prev: "binks-v1", prev_text: "binks-v1", reached: [{ id: "binks-prod", channel: "prod", at: 1793942000, how: "deploy" }], reached_text: "binks-prod 11-06", prs: [12, 14], prs_text: "#12, #14", rows: ["agent-runtime:ar-7"], rows_text: "ar-7" },
    { tag: "binks-v1", version: "1", at: 1793000000, at_text: "10-26", prev: null, prev_text: "first tag", reached: [], reached_text: "not recorded", prs: [], prs_text: "none merged", rows: [], rows_text: "none merged" },
  ],
};
const data = (o = {}) => ({
  at: NOW() - 120, question: "What is building, and what is live where?", summary: "2 apps: 1 drift, 1 ok", stale_after: 3600, errors: [], table,
  gaps: "1 channel not read: steam GetAppBetas failed (1)", coverage: "coverage: prev 2/2, deployed 1/2", rows: [binks],
  blanks: ["none declared", "not recorded", "manual", "not read", "none merged"], ...o,
});

const target = (attrs, tr = null, ch = null) => ({
  dataset: attrs,
  closest: (sel) => (sel === "tr.jr" ? tr : sel === "tr.rc" ? ch : sel === "[data-ts]" && "ts" in attrs ? { dataset: attrs } : null),
});
const show = (d = data()) => {
  run("st.tab = 'releases'; st.page = ''; relCh = null");
  Object.assign(relst, { data: d, err: null, sel: null });
  Object.assign(run("relcl"), { project: null, data: null, err: null });
  run("relst.render()");
};
const APP = { dataset: { key: "binks" } };
const clickApp = () => fire("click", { type: "click", target: target({}, APP) });
// The app's page as the router opens it (`#releases/apps/<name>`): the read asks for the app,
// whose changelog is read once it lands.
const PAGE = { app: binks, app_links: { project: "#projects/binks" } };
const page = async (d = data(PAGE), name = "binks", log = changelog()) => {
  run(`st.tab = 'releases'; st.arg = 'apps'; st.page = 'apps/${name}'; relCh = null; relOpened = null`);
  Object.assign(run("relcl"), { project: null, data: null, err: null });
  // The server echoes the app it was asked for (releases::Shown::asked).
  [body, cl] = [{ asked: name, ...d }, log];
  asked.length = 0;
  await relst.refresh();
  await settled();
};
const clickChannel = (id) => fire("click", { type: "click", target: target({}, null, { dataset: { ch: `binks|${id}` } }) });

test("the head asks the tab's question, counts the apps, names what it could not read and says the snapshot's age", () => {
  show();
  const h = box.innerHTML;
  assert.match(h, /What is building, and what is live where\?/);
  assert.match(h, /2 apps: 1 drift, 1 ok/);
  assert.match(h, /<div class="cline warn">1 channel not read: steam GetAppBetas failed \(1\)<\/div>/);
  assert.match(h, /<div class="cline muted">coverage: prev 2\/2, deployed 1\/2<\/div>/);
  assert.match(h, /refreshed .* \(2m ago\)/);
  assert.doesNotMatch(h, /class="warn">refreshed/);
});

test("a snapshot older than the collector's cadence is amber, and a full read draws no gap line", () => {
  show(data({ at: NOW() - 7200, gaps: "" }));
  assert.match(box.innerHTML, /class="warn">refreshed/);
  assert.doesNotMatch(box.innerHTML, /not read:/);
});

test("no snapshot names the error instead of drawing a stale table", () => {
  show(data({ at: 0, rows: [], gaps: "", summary: "not read", errors: ["release-state show: no snapshot yet"], table: { ...table, total: 0 } }));
  assert.match(box.innerHTML, /release-state show: no snapshot yet/);
  assert.match(box.innerHTML, /No apps\./);
});


test("an app is one row: its stage in its own column, what is deployed, its channels amber when one was not read, blanks dimmed", () => {
  show(data({ table: { ...table, links: [{ project: "#projects/binks" }] } }));
  const b = box.innerHTML;
  assert.match(b, /<tr class="jr" data-key="binks"><td><a href="#projects\/binks">binks<\/a><\/td><td class="warn" title="alpha: no alpha target deployed">alpha<\/td><td class="wrap">v1 prod<\/td><td class="bad">drift<\/td><td class="wrap warn">1 drift, 1 not read<\/td><td class="">v2 11-05<\/td><td class="warn">11-06 15:00 fail<\/td><\/tr>/);
  assert.match(b, /data-label="stage"><button class="thsort" data-tsort="stage"/, "the stage sorts and filters as a column");
  assert.match(b, /data-label="deployed"><button class="thsort" data-tsort="live"/, "a deploy is not the app being live");
  assert.match(b, /placeholder="search, or stage:alpha channel:prod status:drift"/);
  assert.equal(b.match(/<tr class="jr"/g).length, 1, "one row per app, not one per channel");
  assert.doesNotMatch(b, /binks-prod/, "channels wait for the app's page");
  show(data({ rows: [{ ...binks, stage: "", stage_level: "ok", released_text: "none declared", last_deploy_text: "not recorded", deploy_level: "" }] }));
  assert.match(box.innerHTML, /<td>binks<\/td><td class="muted" title="alpha: no alpha target deployed">-<\/td>/, "no stage, a dash; no link, plain text");
  assert.match(box.innerHTML, /<td class="muted">none declared<\/td><td class="muted">not recorded<\/td>/);
});

test("a click on an app goes to its page, keeping the view for the way back; its name goes to its Projects card", () => {
  show();
  run("st.views.releases = 's=attention'");
  loc.hash = "";
  clickApp();
  assert.equal(loc.hash, "#releases/apps/binks?s=attention");
  assert.doesNotMatch(box.innerHTML, /binks-prod/, "nothing opens inline");
  loc.hash = "";
  fire("click", { type: "click", target: { dataset: {}, closest: (sel) => (sel === "a" ? {} : sel === "tr.jr" ? APP : null) } });
  assert.equal(loc.hash, "", "the name's link is the browser's");
  run("st.views.releases = ''");
});

test("the router opens an app's page on the Apps inner tab", () => {
  const r = run("route('#releases/apps/binks?s=ok')");
  assert.deepEqual([r.tab, r.arg, r.page, r.query], ["releases", "apps", "apps/binks", "s=ok"]);
});

test("an app's page reads its app, heads it with the way back and its Projects card, and replaces the table", async () => {
  run("st.views.releases = 's=attention'");
  await page();
  assert.deepEqual(asked, ["/api/releases?s=attention&app=binks", "/api/releases/changelog?project=binks"]);
  const b = box.innerHTML;
  assert.match(b, /^<div class="seg fseg istrip" role="tablist">/, "the strip stays on top");
  assert.match(b, /<div class="bhead"><span>Releases \/ <b>binks<\/b> <span class="bad">drift<\/span><\/span><span><a class="btn sm" href="#releases\/apps\?s=attention">All apps<\/a> <a class="btn sm" href="#projects\/binks">Project page<\/a><\/span><\/div>/);
  assert.doesNotMatch(b, /rel-q|<tr class="jr"|relrun-head/, "no search bar, list or Release runs under a page");
  assert.match(b, /<div class="cline"><b>Stage<\/b> <span class="warn">alpha: no alpha target deployed<\/span><\/div>/);
  assert.match(b, /<b>Coverage<\/b> <span class="muted">prev 1\/1, deployed 1\/2 \(1 none declared\)<\/span>/);
  run("st.views.releases = ''");
});

test("an app the snapshot does not have says so, with its read errors, not a blank page", async () => {
  await page(data({ errors: ["release-state show: no snapshot yet"] }), "nope");
  const b = box.innerHTML;
  assert.match(b, /<div class="bhead"><span>Releases \/ nope<\/span><a class="btn sm" href="#releases\/apps">All apps<\/a><\/div>/);
  assert.match(b, /release-state show: no snapshot yet/);
  assert.match(b, /No such app: nope\./);
  assert.ok(!asked.some((u) => u.includes("changelog")), "no changelog read for an app that is not there");
});

test("a page whose read is still on its way says reading, never another app's page or no such app", async () => {
  await page();
  run("st.page = 'apps/other'; relst.render()");
  const b = box.innerHTML;
  assert.match(b, /Releases \/ other<\/span>.*reading\.\.\./s);
  assert.doesNotMatch(b, /No such app|binks-prod/, "neither a false 'no such app' nor binks' body under other's URL");
  run("st.page = 'apps/binks'; relst.render()");
});

test("reopening an app's page reads its changelog again, so a tag that landed meanwhile shows", async () => {
  await page();
  run("st.page = ''");
  [body] = [data()];
  await relst.refresh();
  await settled();
  run("st.page = 'apps/binks'");
  [body] = [{ asked: "binks", ...data(PAGE) }];
  asked.length = 0;
  await relst.refresh();
  await settled();
  assert.deepEqual(asked, ["/api/releases?app=binks", "/api/releases/changelog?project=binks"]);
});

test("an app's page lists its headline env's channels, the other envs in a fold that starts open", async () => {
  await page();
  const b = box.innerHTML;
  assert.match(b, /<th data-role="glance" data-named>deployed<\/th>/);
  assert.match(b, /<tr class="rc" data-ch="binks\|binks-prod"><td>prod<\/td><td class="wrap">binks-prod<\/td><td class="bad">v1<\/td><td>v2<\/td><td class="bad">drift<\/td><td class="wrap muted">home-k3s<\/td><\/tr>/);
  assert.match(b, /<details class="cfold" data-k="rel-env:binks" open><summary><b>1 other channel<\/b> <span class="muted">beta 1 not read<\/span><\/summary>/);
  assert.match(b, /<td class="warn">not read<\/td><td class="wrap muted"><span class="warn">steam GetAppBetas failed<\/span>/);
  assert.ok(b.indexOf("binks-prod") < b.indexOf("rel-env:binks"), "the headline env is above the fold");
});

test("a fold of other envs the reader closed stays closed across a repaint", async () => {
  await page();
  run("REL_OPEN['rel-env:binks'] = false; relst.render()");
  assert.match(box.innerHTML, /data-k="rel-env:binks"><summary>/);
  run("delete REL_OPEN['rel-env:binks']; relst.render()");
  assert.match(box.innerHTML, /data-k="rel-env:binks" open>/, "with no remembered state it is open");
});
test("the strip is the first element of the page, before the first read and after it", () => {
  Object.assign(relst, { data: null, err: null, sel: null });
  run("st.tab = 'releases'; st.arg = ''; relst.render()");
  assert.match(box.innerHTML, /^<div class="seg fseg istrip" role="tablist">.*Loading/, "loading");
  Object.assign(relst, { err: "fetch failed" });
  run("relst.render()");
  assert.match(box.innerHTML, /^<div class="seg fseg istrip" role="tablist">.*fetch failed/, "a failed read");
  relst.err = null;
  show();
  assert.match(box.innerHTML, /^<div id="rel-head"><div class="seg fseg istrip" role="tablist">/, "read");
});


test("clicking a channel opens its versions, every watch and its deps, and clicking again closes it", async () => {
  await page();
  clickChannel("binks-prod");
  const b = box.innerHTML;
  assert.match(b, /<b>Pinned<\/b> v2 <span class="muted">from manifest/);
  assert.match(b, /image reg\/binks:v1/);
  assert.match(b, /binks-probe <span class="bad">TRIP/);
  assert.match(b, /<b>Deps<\/b> unity-core v0.5.0/);
  assert.match(b, /<a href="https:\/\/github\.test\/run\/9"[^>]*>run<\/a>/);
  assert.doesNotMatch(b, /javascript:/, "only an https run is a link");
  assert.match(b, /<tr class="rcd"><td colspan="6">/);
  clickChannel("binks-prod");
  assert.doesNotMatch(box.innerHTML, /<b>Pinned/);
  assert.match(box.innerHTML, /binks-prod/, "the page stays open");
});

const changelog = (o = {}) => ({
  project: "binks", tag: "binks-v2", prev: "binks-v1", source: "merged PRs", range: "binks-v1..binks-v2",
  text: "- fix the **probe** (#7)", tags: ["binks-v3", "binks-v2", "binks-v1"], ...o,
});

test("an app's page reads its newest changelog and draws it under a tag picker", async () => {
  await page();
  const b = box.innerHTML;
  assert.match(b, /<b>Changelog<\/b> <select class="rel-tag"[^>]*data-project="binks">/);
  assert.match(b, /<option>binks-v3<\/option><option selected>binks-v2<\/option><option>binks-v1<\/option>/);
  assert.match(b, /binks-v1\.\.binks-v2, from merged PRs/);
  assert.match(b, /fix the <strong>probe<\/strong> \(#7\)/);
  asked.length = 0;
  await relst.refresh();
  await settled();
  assert.deepEqual(asked, ["/api/releases?app=binks"], "a re-read keeps the changelog picked");
});

test("an app's page lists its releases newest first with when, the one before and where each reached", async () => {
  await page();
  const b = box.innerHTML;
  assert.match(b, /<details class="cfold" data-k="rel-hist:binks" open><summary><b>Releases<\/b> <span class="muted">2 release tags<\/span><\/summary>/);
  assert.match(b, /<th class="n" data-role="glance" data-named>released<\/th>/, "a date header aligns with its cells");
  assert.match(b, /<tr class="rh sel" data-project="binks" data-tag="binks-v2"><td>binks-v2<\/td><td class="n">11-05<\/td><td class="muted">binks-v1<\/td><td class="wrap">binks-prod 11-06<\/td><td class="wrap">#12, #14<\/td><td class="wrap">ar-7<\/td><\/tr>/, "a release lists its PRs and their board rows");
  assert.match(b, /<tr class="rh" data-project="binks" data-tag="binks-v1"><td>binks-v1<\/td><td class="n">10-26<\/td><td class="muted">first tag<\/td><td class="wrap muted">not recorded<\/td><td class="wrap muted">none merged<\/td><td class="wrap muted">none merged<\/td><\/tr>/);
  assert.ok(b.indexOf("rel-hist:binks") < b.indexOf("<b>Changelog</b>"), "the history sits above the changelog");
  asked.length = 0;
  const rh = { dataset: { project: "binks", tag: "binks-v1" } };
  fire("click", { type: "click", target: { dataset: {}, closest: (sel) => (sel === "tr.rh" ? rh : null) } });
  await settled();
  assert.deepEqual(asked, ["/api/releases/changelog?project=binks&tag=binks-v1"]);
  assert.match(box.innerHTML, /Releases \/ <b>binks<\/b>/, "the page stays open");
});

test("an app's page lists its build runs newest first, below its releases, and counts the one in progress", async () => {
  await page();
  const b = box.innerHTML;
  assert.match(b, /<details class="cfold" data-k="rel-builds:binks" open><summary><b>Builds<\/b> <span class="muted">2 runs, 1 in progress<\/span><\/summary>/);
  assert.match(b, /<th class="n" data-role="glance">started<\/th><th class="n">finished<\/th>/, "date headers align with their cells");
  assert.match(b, /<tr><td>binks-v3<\/td><td>Release builds<\/td><td class="">in progress 12m<\/td><td class="n">11-11 16:20<\/td><td class="n muted">-<\/td><td><a href="https:\/\/github.com\/o\/binks\/actions\/runs\/30" target="_blank" rel="noopener">run<\/a><\/td><\/tr>/);
  assert.match(b, /<tr><td>binks-v2<\/td><td>Steam \(binks\)<\/td><td class="">cancelled<\/td><td class="n">11-05 10:00<\/td><td class="n">11-05 10:01<\/td><td><\/td><\/tr>/, "a link that is not https is dropped");
  assert.ok(b.indexOf("rel-hist:binks") < b.indexOf("rel-builds:binks") && b.indexOf("rel-builds:binks") < b.indexOf("<b>Changelog</b>"));
});

test("an app no build run joined says so where its builds would be", async () => {
  await page(data({ app: { ...binks, builds: [] } }));
  assert.match(box.innerHTML, /<b>Builds<\/b> <span class="muted">no build run joined to a tag in the last 30 days<\/span>/);
});

test("an app with no tags read says so where its history would be", async () => {
  await page(data({ app: { ...binks, history: [], line: "none" } }));
  assert.match(box.innerHTML, /<b>Releases<\/b> <span class="muted">no tags read<\/span>/);
});

test("opening a channel inside the page does not read the changelog again", async () => {
  await page();
  asked.length = 0;
  clickChannel("binks-prod");
  await settled();
  assert.equal(asked.length, 0);
});

test("picking another tag reads that tag, and a tag with nothing in it says so", async () => {
  await page();
  asked.length = 0;
  cl = changelog({ tag: "binks-v1", prev: null, range: "binks-v1", text: "" });
  const select = { dataset: { project: "binks" }, value: "binks-v1" };
  fire("change", { type: "change", target: { closest: (sel) => (sel === "select.rel-tag" ? select : null) } });
  await settled();
  assert.deepEqual(asked, ["/api/releases/changelog?project=binks&tag=binks-v1"]);
  assert.match(box.innerHTML, /No merged PRs in binks-v1\./);
  asked.length = 0;
  fire("change", { type: "change", target: { closest: () => null } });
  await settled();
  assert.equal(asked.length, 0);
});

test("a changelog the collector refused is said on the page, not left reading", async () => {
  run("st.tab = 'releases'; st.arg = 'apps'; st.page = 'apps/binks'; relCh = null");
  Object.assign(run("relcl"), { project: null, data: null, err: null });
  Object.assign(relst, { data: { asked: "binks", ...data(PAGE) }, err: null });
  const real = ctx.fetch;
  ctx.fetch = async () => ({ ok: false, status: 400, statusText: "Bad Request", text: async () => "release-state: binks has no release tags", headers: { get: () => "text/plain" } });
  run("loadChangelog('binks')");
  await settled();
  ctx.fetch = real;
  assert.match(box.innerHTML, /class="warn">Could not read releases \(HTTP 400\): release-state: binks has no release tags/);
});

test("a pick the collector refuses keeps the tag picker, so another tag can be tried", async () => {
  await page();
  const real = ctx.fetch;
  ctx.fetch = async () => ({ ok: false, status: 502, statusText: "Bad Gateway", text: async () => "release-state: gone", headers: { get: () => "text/plain" } });
  const select = { dataset: { project: "binks" }, value: "binks-v1" };
  fire("change", { type: "change", target: { closest: (sel) => (sel === "select.rel-tag" ? select : null) } });
  await settled();
  ctx.fetch = real;
  assert.match(box.innerHTML, /class="warn">Could not read releases \(HTTP 502\): release-state: gone/);
  assert.match(box.innerHTML, /<select class="rel-tag"[^>]*>.*<option>binks-v1<\/option>/);
  assert.doesNotMatch(box.innerHTML, /fix the/);
});

test("leaving the page for the table draws the list again", async () => {
  await page();
  run("st.page = ''; relst.render()");
  assert.match(box.innerHTML, /<tr class="jr" data-key="binks">/);
  assert.doesNotMatch(box.innerHTML, /All apps/);
});

const bcol = (key) => ({ key, sort: null, next_sort: key, next_dir: "desc" });
const shipped = {
  forge: "github.com", repo: "o/binks", id: 77, attempt: 1, workflow: "Deploy", title: "deploy v2", branch: "v2", event: "push", sha: "abc", status: "completed",
  conclusion: "success", prs: [], url: "https://github.com/o/binks/actions/runs/77", owner: "", state: "green", level: "ok", started: NOW() - 300, took: 125, release: { project: "binks", tag: "v2" },
};
const bdata = (o = {}) => ({
  at: NOW() - 60, summary: "1 run in 30 days: 0 running, 0 queued, 0 red", stale_after: 1800, rows: [shipped], more: 0, errors: [], times: [], quarantine: [],
  table: { q: "", state: "", sort: "", dir: "", total: 1, shown: 1, states: [{ name: "all", n: 1 }], columns: ["started", "state", "repo", "workflow", "branch", "took", "owner", "release", "forge", "event", "title"].map(bcol), facets: [] },
  ...o,
});
const showRuns = (d = bdata()) => { show(); Object.assign(run("relRuns"), { data: d, err: null, sel: null, log: null, detail: null }); run("relst.render()"); };

test("Release runs lists the runs tied to a release with the tag each ran on, and links every run on Infra", () => {
  showRuns();
  const b = box.innerHTML;
  assert.match(b, /<div data-tbl="b"><div id="relrun-head"><h2 class="sec" id="sec-runs">Release runs <span class="muted">1 run in 30 days/);
  assert.match(b, /<a href="#infra\/runs">Infra, CI<\/a>/);
  assert.match(b, /<td class="muted">v2<\/td><\/tr>/);
  assert.ok(b.indexOf("sec-runs") > b.indexOf(`data-key="binks"`), "after the apps");
  showRuns(bdata({ rows: [], table: { ...bdata().table, total: 0, shown: 0 } }));
  assert.match(box.innerHTML, /No run tied to a release in 30 days\./);
});

test("a builds event re-reads Release runs (scope=release, its own view keys) and the apps, whose build runs it changes, only while the tab is open", async () => {
  builds = bdata();
  body = data();
  run("st.tab = 'releases'; st.views.releases = 'q=project%3Abinks&bq=repo%3Ao%2Fbinks'");
  asked.length = 0;
  run("TABS.releases").onEvent({ kind: "builds" });
  await settled();
  assert.deepEqual(asked, ["/api/releases?q=project%3Abinks", "/api/builds?bq=repo%3Ao%2Fbinks&scope=release"]);
  run("st.tab = 'home'; st.views.releases = ''");
  asked.length = 0;
  run("TABS.releases").onEvent({ kind: "builds" });
  await settled();
  assert.equal(asked.length, 0);
});

test("opening a release run reads its jobs and log inside the Releases page", async () => {
  showRuns();
  detail = { key: {}, title: "#77 Deploy green", header: "end to end 2m", coverage: "full", coverage_text: "full", attempts: [1], jobs: [], rates_error: null };
  asked.length = 0;
  fire("click", { type: "click", target: { dataset: {}, closest: (sel) => (sel === "tr.br" ? { dataset: { bkey: "github.com|o/binks|77|1" } } : null) } });
  await settled();
  assert.deepEqual(asked, ["/api/builds/detail?forge=github.com&repo=o%2Fbinks&run_id=77&attempt=1", "/api/builds/log?forge=github.com&repo=o%2Fbinks&run_id=77&attempt=1"]);
  assert.match(box.innerHTML, /<b>Release<\/b> binks v2/);
  assert.match(box.innerHTML, /<b>#77 Deploy green<\/b>/);
  run("relRuns.sel = null; relRuns.log = null; relRuns.detail = null");
});

test("a new snapshot re-reads only while the tab is open", async () => {
  body = data();
  run("st.tab = 'releases'");
  asked.length = 0;
  run("TABS.releases").onEvent({ kind: "releases" });
  await settled();
  assert.equal(asked.filter((u) => u.startsWith("/api/releases")).length, 1);
  run("st.tab = 'home'");
  asked.length = 0;
  run("TABS.releases").onEvent({ kind: "releases" });
  await settled();
  assert.equal(asked.length, 0);
  run("TABS.releases").onEvent({ kind: "costs" });
  await settled();
  assert.equal(asked.length, 0);
});

test("showing the tab reads the view in the URL, which a Projects badge links to", async () => {
  body = data();
  run("st.tab = 'releases'; st.views.releases = 'q=project%3Abinks'");
  asked.length = 0;
  run("TABS.releases").show();
  await settled();
  assert.equal(asked[0], "/api/releases?q=project%3Abinks");
  run("st.views.releases = ''");
});


// Inner tabs: Apps (the table and an opened app) and Release runs, over hub_core::layout's groups.
const shownIn = (h, id) => !new RegExp(`data-in="${id}" hidden`).test(h) && new RegExp(`data-in="${id}"`).test(h);
const relOn = (arg) => { run(`st.arg = ${JSON.stringify(arg)}; st.section = null`); showRuns(); return box.innerHTML; };

test("Releases opens on Apps, and a URL naming Release runs opens it with Apps hidden", () => {
  // An empty arg is the first inner tab (Apps); a section id is the inner tab holding it.
  for (const [hash, arg] of [["#releases", ""], ["#releases/runs", "runs"], ["#releases/detail", "apps"], ["#releases/table", "apps"], ["#releases?q=project:binks", ""]]) {
    assert.equal(ctx.route(hash).arg, arg, hash);
  }
  // Builds and Tests moved to Infra's CI (layout::MOVED).
  for (const hash of ["#releases/builds", "#releases/tests"]) assert.equal(ctx.route(hash).tab, "infra", hash);
  const apps = relOn("");
  assert.ok(shownIn(apps, "apps") && !shownIn(apps, "runs"));
  assert.match(apps, /data-itab="apps" class="on" aria-selected="true"/);
  assert.doesNotMatch(apps, /data-itab="builds"|data-itab="tests"/);
  const r = relOn("runs");
  assert.ok(shownIn(r, "runs") && !shownIn(r, "apps"));
  run("st.arg = ''");
});

test("a count shows beside an inner tab needing a look: a bad app, a release run needing a look", () => {
  const h = relOn("");
  assert.doesNotMatch(h, />Apps <span class="pill/);
  assert.doesNotMatch(h, />Release runs <span class="pill/, "a run without look set counts nothing");
  Object.assign(relst.data, { look: true });
  Object.assign(run("relRuns").data, { look: true });
  run("relst.render()");
  assert.match(box.innerHTML, />Apps <span class="pill warn">1<\/span>/);
  assert.match(box.innerHTML, />Release runs <span class="pill warn">1<\/span>/);
  run("st.arg = ''");
});
