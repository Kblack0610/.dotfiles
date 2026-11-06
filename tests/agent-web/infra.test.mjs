// Unit tests for Infra's Red fixes section (.local/src/agent-web/static/infra.js), run by
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
