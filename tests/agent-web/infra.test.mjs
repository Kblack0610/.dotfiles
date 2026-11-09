// Unit tests for Infra's Red fixes and Red now sections (.local/src/agent-web/static/infra.js), run by
// `node --test` from tests/unit/agent_web_queue.bats. The page's real scripts load into one vm
// context, as the browser loads them; only the DOM is a stub. The split, the order and the
// summary are hub_core::reds, tested in Rust; this checks how the section draws them.
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

const red = (slug, outcome, o = {}) => ({ slug, red: `watch ${slug}`, outcome, queued: new Date(Date.now() - 3 * 3600e3).toISOString(), pr: null, pr_url: null, ...o });
const reds = {
  open: [red("ar-3", "came back", { pr: "Kblack0610/.dotfiles#1170", pr_url: "https://github.com/Kblack0610/.dotfiles/pull/1170" }), red("ar-2", "queued", { pr: "986" })],
  settled: [red("ar-1", "fixed"), red("ar-4", "cancelled")],
  summary: "2 open: 1 came back, 1 queued | 1 fixed, 1 cancelled in 7d, fix p50 34m",
};

test("open rows draw with their outcome, red, slug, PR and age; settled fold to a count", () => {
  Object.assign(ist, { reds, redsErr: null, open: {} });
  const h = run("fixesSection()");
  assert.match(h, /<h2 class="sec" id="sec-fixes">Red fixes <span class="muted">2 open: 1 came back, 1 queued \| 1 fixed, 1 cancelled in 7d, fix p50 34m<\/span><\/h2>/);
  const [openPart, foldPart] = h.split('<details class="sec-d" data-k="fixes-settled">');
  assert.ok(openPart.indexOf("CAME BACK") < openPart.indexOf("QUEUED"), "the server's order is kept");
  assert.match(openPart, /<a href="https:\/\/github.com\/Kblack0610\/.dotfiles\/pull\/1170"[^>]*>PR Kblack0610\/.dotfiles#1170<\/a>/);
  assert.match(openPart, /<span class="by">PR 986<\/span>/, "a PR with no repo is text, not a link");
  assert.match(openPart, /<span class="by">ar-3<\/span>/);
  assert.match(openPart, /<span class="by">3h<\/span>/);
  assert.ok(foldPart, "the settled rows sit in a fold");
  assert.match(foldPart, /<summary class="muted fold">\+2 settled<\/summary>/);
  assert.ok(!openPart.includes("FIXED") && foldPart.includes("FIXED"));
});

test("a failed read says so in the section, never an empty list", () => {
  Object.assign(ist, { reds: null, redsErr: "Could not read reds (HTTP 502): reds: cannot read the queue" });
  const h = run("fixesSection()");
  assert.match(h, /Red fixes <span class="muted">read failed<\/span>/);
  assert.match(h, /<div class="panel down">Could not read reds \(HTTP 502\): reds: cannot read the queue<\/div>/);
  assert.ok(!h.includes("settled"));
});

test("nothing open and nothing settled is the summary alone", () => {
  Object.assign(ist, { reds: { open: [], settled: [], summary: "no red fix queued in the last 7 days" }, redsErr: null });
  assert.equal(run("fixesSection()"), `<h2 class="sec" id="sec-fixes">Red fixes <span class="muted">no red fix queued in the last 7 days</span></h2>`);
});

test("red now draws the server's down runners and never judges a runner itself", () => {
  const up = () => [{ labels: {}, value: 1 }];
  const off = (name) => ({ labels: { name, host: "aws-burst-1", state: "offline" } });
  const d = {
    instant: { red: [{ labels: { item: "watch a" } }], runners: [off("aws-burst-1-unity-pool-1")], exporter_up: up(), rate_left: [{ labels: {}, value: 5 }], api: up() },
    down: [{ labels: { name: "mini-1", host: "mac-mini", state: "missing" } }],
  };
  ctx.d = d;
  assert.deepEqual([...run("redItems(d)")], ["watch a", "runner mini-1 missing"], "aws-burst-1 is offline in the series but not in down");
});

test("the open red fixes cap at LOG_ROWS, then +N more", () => {
  const n = run("LOG_ROWS") + 2;
  Object.assign(ist, { reds: { open: Array.from({ length: n }, (_, i) => red(`ar-${i}`, "queued")), settled: [], summary: `${n} open` }, redsErr: null, open: {} });
  const h = run("fixesSection()");
  assert.equal(h.match(/QUEUED/g).length, n - 2);
  assert.match(h, /<div class="muted more">\+2 more<\/div>$/);
});

test("CI lists no runs: one line links to Releases, whose Builds section has them", () => {
  Object.assign(ist, { open: {} });
  const h = run("ciSection({}, {}, Date.now())");
  assert.ok(!h.includes("Recent runs"), "the runs are Releases'");
  assert.match(h, /<div class="cline">Runs: every CI run of 30 days is on <a href="#releases">Releases, Builds<\/a><\/div>$/);
});
