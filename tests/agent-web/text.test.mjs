// The source sweep behind ui.md's "UI text is a hub_core::display role, no free sentence list":
// agent-web's scripts (.local/src/agent-web/static) may not grow the three hand-built shapes the
// shared renderers replace: a record list (<ul>, <li>), an error block (class="err") and a fold
// (<details>). Each file's count may only fall: text.baseline.json holds today's, a file above
// its line fails, and so does one below it (lower the line), so the migration is measured and
// cannot slide back. Run by `node --test` from tests/unit/agent_web_queue.bats. The Rust side is
// hub-core's display.rs (`prose_fields_never_grow`), the live side `comms-lint report` on the
// `ui` channel.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);
const baseline = JSON.parse(readFileSync(new URL("./text.baseline.json", import.meta.url), "utf8"));

const SHAPES = {
  list: /<(?:ul|li)[\s>]/g,
  err: /class="[^"]*\berr\b/g,
  fold: /<details[\s>]/g,
};

export const sweep = (files) => {
  const out = {};
  for (const [name, src] of Object.entries(files)) {
    for (const [shape, re] of Object.entries(SHAPES)) {
      const n = (src.match(re) || []).length;
      if (n) (out[shape] ||= {})[name] = n;
    }
  }
  return out;
};

/** The sweep's complaints against a baseline: a count above its line, or below it. */
export const verdict = (found, base) => {
  const bad = [];
  for (const shape of Object.keys(SHAPES)) {
    const names = new Set([...Object.keys(found[shape] || {}), ...Object.keys(base[shape] || {})]);
    for (const f of [...names].sort()) {
      const n = (found[shape] || {})[f] || 0;
      const was = (base[shape] || {})[f] || 0;
      if (n > was) bad.push(`${f}: ${n} hand-built ${shape}, baseline ${was}: draw it with the shared renderer`);
      else if (n < was) bad.push(`${f}: ${n} ${shape} now, baseline ${was}: lower text.baseline.json to ${n}`);
    }
  }
  return bad;
};

const files = () => Object.fromEntries(
  readdirSync(dir).filter((f) => f.endsWith(".js")).sort().map((f) => [f, readFileSync(new URL(f, dir), "utf8")]),
);

test("agent-web's scripts hold no more hand-built lists, error blocks and folds than the baseline", () => {
  const found = sweep(files());
  const total = (s) => Object.values(found[s] || {}).reduce((a, b) => a + b, 0);
  console.log(`hand-built shapes: ${total("list")} list, ${total("err")} err, ${total("fold")} fold`);
  assert.deepEqual(verdict(found, baseline), []);
});

test("negative control: a list, an error block and a fold added to a script are refused", () => {
  const real = files();
  const edited = { ...real, "queue.js": real["queue.js"] + '\nconst x = `<ul><li>${a}</li></ul><div class="err">${e}</div><details><summary>s</summary></details>`;\n' };
  const bad = verdict(sweep(edited), baseline);
  assert.equal(bad.length, 3, bad.join("\n"));
  assert.ok(bad.some((b) => b.startsWith("queue.js") && b.includes("list")));
  assert.ok(bad.some((b) => b.includes("err")) && bad.some((b) => b.includes("fold")));
});

test("negative control: a script that migrated off its line is told to lower the baseline", () => {
  const found = sweep(files());
  const bad = verdict(found, { ...baseline, fold: { ...baseline.fold, "costs.js": 9 } });
  assert.deepEqual(bad.map((b) => b.split(":")[0]), ["costs.js"]);
  assert.match(bad[0], /lower text\.baseline\.json/);
});
