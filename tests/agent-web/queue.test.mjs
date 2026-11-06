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
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "log.js", "infra.js", "jobs.js", "queue.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });

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
