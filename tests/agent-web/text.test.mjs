// The source sweep behind ui.md's "UI text is a hub_core::display role, no free sentence list":
// agent-web's scripts (.local/src/agent-web/static) hold none of the three hand-built shapes the
// shared renderers (web-kit kb-ui.js, which ui.js takes) replace: a record list (<ul>, <li>: `tblRec`), an error block
// (class="err": `errPanel`) and a fold (<details>: `fold`, `cfold`, `pfold`). The migration is
// done, so the allowance is zero (the sweep reads the literal markup, so a node built with
// createElement is for review to catch): a new tab that builds one fails here. Two files are exempt by
// kind, ui.js because readPanel draws its own down panel, and md.js because it turns the human's own
// markdown into HTML, where a list is the content and not a record. Run by `node --test` from
// tests/unit/agent_web_queue.bats. The Rust side is hub-core's display.rs (`prose_fields_never_grow`),
// the live side `comms-lint report` on the `ui` channel.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);

const EXEMPT = new Set(["ui.js", "md.js"]);
const SHAPES = {
  list: [/<(?:ul|li)[\s>]/g, "tblRec"],
  err: [/class=["'][^"']*\berr\b/g, "errPanel"],
  fold: [/<details[\s>]/g, "fold"],
};

/** The sweep's complaints: every hand-built shape in a script that is not exempt. */
export const verdict = (files) => {
  const bad = [];
  for (const [name, src] of Object.entries(files)) {
    if (EXEMPT.has(name)) continue;
    for (const [shape, [re, use]] of Object.entries(SHAPES)) {
      const n = (src.match(re) || []).length;
      if (n) bad.push(`${name}: ${n} hand-built ${shape}: draw it with ${use} (web-kit kb-ui.js)`);
    }
  }
  return bad;
};

// Every .js, .mjs and .html under static/, keyed by its path relative to it.
const scripts = (rel = "") => readdirSync(new URL(rel, dir), { withFileTypes: true }).flatMap((e) => {
  const p = join(rel, e.name);
  if (e.isDirectory()) return scripts(p + "/");
  return /\.(?:js|mjs|html)$/.test(e.name) ? [p] : [];
});
const files = () => Object.fromEntries(
  scripts().sort().map((f) => [f, readFileSync(new URL(f, dir), "utf8")]),
);

test("agent-web's scripts hold no hand-built list, error block or fold", () => {
  assert.deepEqual(verdict(files()), []);
});

test("negative control: a list, an error block and a fold added to a script are refused", () => {
  const real = files();
  const edited = { ...real, "queue.js": real["queue.js"] + '\nconst x = `<ul><li>${a}</li></ul><div class="err">${e}</div><details><summary>s</summary></details>`;\n' };
  const bad = verdict(edited);
  assert.equal(bad.length, 3, bad.join("\n"));
  assert.ok(bad.every((b) => b.startsWith("queue.js")));
});

test("negative control: the renderers' own file holds the markup and sits outside the sweep", () => {
  const kit = readFileSync(new URL("../../web-kit/kb-ui.js", dir), "utf8");
  assert.match(kit, /<details/);
  assert.ok(verdict({ "kb-ui.js": kit }).length, "swept, it would be refused: it must stay outside static/");
  assert.ok(!Object.keys(files()).includes("kb-ui.js"));
});

// The shared renderers themselves: what the migrated tabs now draw through.
const ui = () => {
  const ctx = vm.createContext({ console, document: {}, st: { tab: "home" }, conn: {}, location: {} });
  for (const f of ["../../web-kit/kb-ui.js", "ui.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
  return (code, input) => { ctx.input = input; return vm.runInContext(code, ctx); };
};

test("errPanel escapes its text and carries its card, tag, id and class", () => {
  const run = ui();
  assert.equal(run('errPanel("a <b>")'), '<div class="err">a &lt;b&gt;</div>');
  assert.equal(run('errPanel("", { id: "q-msg" })'), '<div class="err" id="q-msg"></div>');
  assert.equal(run('errPanel("x", { card: true })'), '<div class="card err">x</div>');
  assert.equal(run('errPanel("x", { tag: "span", cls: "msg" })'), '<span class="msg err">x</span>');
});

test("readPanel is the down panel for an error and the wait word otherwise", () => {
  const run = ui();
  assert.equal(run('readPanel("boom <1>", "Loading...")'), '<div class="panel down">boom &lt;1&gt;</div>');
  assert.equal(run('readPanel(null, "Loading...")'), '<div class="empty">Loading...</div>');
});

test("fold draws its class, key, id, state and summary attributes in one order", () => {
  const run = ui();
  assert.equal(run('fold("csec", "S", "<p>i</p>", { k: "a", id: "sec-a", open: true, sum: \' class="dlh"\', attrs: \' data-x="1"\' })'),
    '<details class="csec" data-k="a" id="sec-a" data-x="1" open><summary class="dlh">S</summary><p>i</p></details>');
  assert.equal(run('fold("", "S", "i")'), "<details><summary>S</summary>i</details>");
  assert.equal(run('cfold("k", "S", "i", { k: true })'), '<details class="cfold" data-k="k" open><summary>S</summary>i</details>');
});

test("tblRec draws each record as a row of cells, a row's own class kept, cells as sent", () => {
  const run = ui();
  assert.equal(run('tblRec([["<b>a</b>", "x"], { cells: ["c"], cls: "warn" }], "o-steps")'),
    '<table class="rec o-steps"><tr><td><b>a</b></td><td>x</td></tr><tr class="warn"><td>c</td></tr></table>');
});
