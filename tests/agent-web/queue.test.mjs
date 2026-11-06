// Unit tests for the Queue tab's pipeline line (.local/src/agent-web/static/queue.js), run by
// `node --test` from tests/unit/agent_web_queue.bats. The real scripts load into one vm context;
// only the DOM is a stub. The wording is hub_core::pipeline, tested in Rust; this checks what the
// page draws from /api/pipeline: the lines as sent, the graph link, and `pipeline -` when absent.
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
  fetch: async () => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => [] }),
});
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "log.js", "infra.js", "table.js", "jobs.js", "queue.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });

const draw = (data, err = null) => vm.runInContext(`qpl.data = ${JSON.stringify(data)}; qpl.err = ${JSON.stringify(err)}; qPipeline()`, ctx);

test("a bottleneck draws both lines and the graph link to Agents / Overview", () => {
  const html = draw({
    lines: ["pipeline  inbox 4  backlog 312  queued 3  running 5  waiting 2", "          ! bottleneck: waiting, age p90 9h (bound 4h)"],
    pipeline: { wip: [] }, error: null, grafana: "https://g.example",
  });
  assert.match(html, /pipeline {2}inbox 4 {2}backlog 312/);
  assert.match(html, /<span class="qwarn">! bottleneck: waiting, age p90 9h \(bound 4h\)<\/span>/);
  assert.match(html, /href="https:\/\/g\.example\/d\/kb-agents-overview"/);
});

test("negative control: absent gauges draw pipeline - , muted, with no counts", () => {
  const html = draw({ lines: ["pipeline -"], pipeline: null, error: null, grafana: null });
  assert.match(html, /class="qpipe muted">pipeline -</);
  assert.doesNotMatch(html, /inbox|href|qwarn/);
});

test("a failed read says why beside pipeline -, and no data yet says reading", () => {
  assert.match(draw({ lines: ["pipeline -"], pipeline: null, error: "no prom", grafana: null }), /pipeline -.*no prom/);
  assert.match(draw(null), /reading Prometheus/);
});

const done = (o) => ({ state: "done", status: "ok", project: "p", slug: "s", title: "T", finished: "2026-11-06T12:00:00Z", started: "2026-11-06T11:00:00Z", ...o });
const card = (i) => vm.runInContext(`qItem(${JSON.stringify(i)})`, ctx);

test("a done item with a merged PR shows the PR link, merged, and its dollars", () => {
  const html = card(done({ pr: "o/r#7", pr_label: "r#7", pr_url: "https://github.com/o/r/pull/7", pr_merged: true, cost: 6.1, cost_label: "$6.10" }));
  assert.match(html, /PR <a href="https:\/\/github\.com\/o\/r\/pull\/7"[^>]*>r#7<\/a> merged/);
  assert.match(html, /\$6\.10/);
  assert.doesNotMatch(html, /no PR, no proof/);
});

test("negative control: no PR and no report is flagged, and an unknown cost reads - , never $0", () => {
  const html = card(done({ unproven: true }));
  assert.match(html, /class="qbad"[^>]*>! no PR, no proof</);
  assert.match(html, /<span title="dollars[^>]*>-<\/span>/);
  assert.doesNotMatch(html, /\$0/);
});

test("a PR with no recorded merge says so, and a bare older PR number keeps its words", () => {
  assert.match(card(done({ pr: "o/r#7", pr_label: "r#7", pr_url: "u", pr_merged: false })), /merge not recorded/);
  assert.match(card(done({ pr: "1796", pr_label: "#1796", pr_url: null, pr_merged: false })), /PR #1796 merge not recorded/);
  assert.match(card({ state: "running", project: "p", slug: "s", pr: "812" }), /PR 812/);
});

test("Done days carry hub-core's day total in the heading, one per day", () => {
  const rows = [
    done({ slug: "a", day: "2026-11-06", day_label: "Today", day_total: "2 done, 1 failed, $9.12" }),
    done({ slug: "b", day: "2026-11-06", day_label: "Today", day_total: "2 done, 1 failed, $9.12", finished: "2026-11-06T11:00:00Z" }),
    done({ slug: "c", day: "2026-11-04", day_label: "Wed 4 Nov", day_total: "1 done, $4.00", finished: "2026-11-04T12:00:00Z" }),
  ];
  const html = vm.runInContext(`qDoneDays(${JSON.stringify(rows)})`, ctx);
  assert.equal((html.match(/<h3 class="qday">/g) || []).length, 2);
  assert.match(html, /<span class="muted">2 done, 1 failed, \$9\.12<\/span>/);
  assert.match(html, /<span class="muted">1 done, \$4\.00<\/span>/);
  assert.match(html, /Today <span[\s\S]*Wed 4 Nov <span/);
  // Undated rows sort together under one heading, never NaN-interleaved.
  const un = [done({ slug: "u1", finished: undefined }), done({ slug: "d", day: "2026-11-06", day_label: "Today" }), done({ slug: "u2", finished: undefined })];
  assert.equal((vm.runInContext(`qDoneDays(${JSON.stringify(un)})`, ctx).match(/Undated/g) || []).length, 1);
});
