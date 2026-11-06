// Unit tests for the Fleet tab's runner rows (.local/src/agent-web/static/fleet.js), run by
// `node --test` from tests/unit/agent_web_queue.bats. The page's real scripts load into one vm
// context, as the browser loads them; only the DOM is a stub. The registry itself is
// hub_core::fleet, tested in Rust; this checks how a row opens and what it draws.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);

const el = () => new Proxy({}, {
  get: (t, k) => (k in t ? t[k] : k === "classList" ? { add() {}, remove() {}, toggle() {} } : k === "dataset" ? {} : k === "style" ? {} : () => el()),
  set: (t, k, v) => { t[k] = v; return true; },
});
let click = null;
const box = Object.assign(el(), { innerHTML: "", scrollTop: 0, querySelectorAll: () => [], addEventListener: (ev, f) => { if (ev === "click") click = f; } });
const doc = { getElementById: (id) => (id === "fleet" ? box : el()), addEventListener() {}, querySelector: el, querySelectorAll: () => [], createElement: el, body: el() };
const ctx = vm.createContext({
  console,
  document: doc,
  window: { addEventListener() {} },
  fetch: async () => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => ({}) }),
});
for (const f of ["ui.js", "md.js", "charts.js", "app.js", "log.js", "infra.js", "fleet.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });

const call = (id, o = {}) => ({ id, at: 1793942659, ms: 3222, ok: true, model: "claude-sonnet-5-5", cost: 0.0871, tokens: 30457, link: `https://lf/project/P/sessions/${id}`, ...o });
const worker = (name, registry) => ({
  name, lane: "observe", description: "", schedule: "", enabled: true, running_since: null, last: null,
  runs_24h: 0, failed_24h: 0, why: null, next: null, cost_24h: null,
  registry: {
    kind: "call", trigger: "called by its caller", role: "distill", role_desc: "reads and returns data",
    caps: "write no, task no, bash no, mcp none", model: "claude-sonnet-5-5", effect: "acts",
    prompt: "/home/k/.config/agent-ask/policy.md",
    calls: { n_24h: 14, errors_24h: 1, cost_24h: 0.12, tokens_24h: 864905, p95_ms: 7100, prompt_sha: "3fa1c2d", recent: [call("s1"), call("s2", { ok: false, link: "" })] },
    eval: null,
    ...registry,
  },
});
const judge = { agree: 0, disagree: 0, deferred: 0, false_defer: 0, pending: 0, unscored: 0, precision: null, kappa: null, prompt: "3fa1c2d", disagreements: [] };
const data = {
  at: 1793942659, errors: [], accounts: [], cost_24h: 1, judge,
  dispatch: { counts_24h: {}, counts_7d: {}, log_24h: {}, recent: [], partial: false },
  workers: [
    worker("ask-judge", {
      eval: {
        prompt_sha: "3fa1c2d", live: ["restates-rule"], total: {},
        rules: [
          { rule: "restates-rule", verdicts: 9, errors: 0, scored: 6, precision: 100, false_defer_pct: null, live: true, bar: { labels: 6, need: 30, met: false } },
          { rule: "taste", verdicts: 31, errors: 0, scored: 28, precision: null, false_defer_pct: 18, live: false, bar: { labels: 6, need: 30, met: false } },
        ],
      },
    }),
    worker("dream", { kind: "oneshot", trigger: "*-*-* 03:00:00", calls: { n_24h: 0, errors_24h: 0, cost_24h: null, tokens_24h: 0, p95_ms: null, prompt_sha: "", recent: [] } }),
  ],
};
const open = (name) => { vm.runInContext("fst", ctx).data = data; click({ target: { closest: (sel) => (sel === "tr.wr" ? { dataset: { key: name } } : null) } }); };

test("a runner row is closed until clicked, and a second click closes it", () => {
  vm.runInContext("st", ctx).tab = "fleet";
  vm.runInContext("fst", ctx).data = data;
  ctx.renderFleet();
  assert.doesNotMatch(box.innerHTML, /class="wdet"/);
  assert.match(box.innerHTML, /<tr class="wr" data-key="ask-judge">/);
  open("ask-judge");
  assert.match(box.innerHTML, /<tr class="wr sel" data-key="ask-judge">/);
  assert.equal((box.innerHTML.match(/class="wdet"/g) || []).length, 1);
  open("ask-judge");
  assert.doesNotMatch(box.innerHTML, /class="wdet"/);
});

test("an open judge shows its role, prompt, 24h calls with Langfuse links, and its rule table", () => {
  open("ask-judge");
  const h = box.innerHTML;
  assert.match(h, /<b>distill<\/b> <span class="muted" title="reads and returns data">write no, task no, bash no, mcp none<\/span>/);
  assert.match(h, /prompt <span title="\/home\/k\/.config\/agent-ask\/policy.md">policy.md<\/span> 3fa1c2d/);
  assert.match(h, /trigger called by its caller \| 24h: 14 calls, <span class="bad">1 errors<\/span>, \$0.12, 865k tokens, p95 7s/);
  assert.match(h, /<a href="https:\/\/lf\/project\/P\/sessions\/s1" target="_blank" rel="noopener">Langfuse<\/a>/);
  assert.match(h, /<td class="bad">error<\/td><td><span class="muted">s2<\/span>/, "a call with no session shows its id");
  assert.match(h, /<td>restates-rule<\/td><td class="n">9<\/td><td class="n">6<\/td><td class="n">100%<\/td><td class="n">-<\/td><td>yes<\/td>/);
  assert.match(h, /<td>taste<\/td>.*<td class="n">18%<\/td><td>no \(6\/30 to bar\)<\/td>/);
  open("ask-judge");
});

test("a runner with no calls and no judge table shows only its registry lines", () => {
  open("dream");
  const det = box.innerHTML.split('class="wdet"')[1];
  assert.match(det, /trigger \*-\*-\* 03:00:00 \| 24h: 0 calls, <span class="">0 errors<\/span>, -, 0 tokens, p95 -/);
  assert.doesNotMatch(det, /<th>rule<\/th>|<th>trace<\/th>/);
  open("dream");
});
