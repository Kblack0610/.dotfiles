// web-kit's renderers (.local/src/web-kit/kb-ui.js) and their CSS (ui.css), run from
// tests/unit/agent_web_queue.bats: the markup every kblab site draws a record list, an error
// block, a fold and a clamped cell with, and the contract between that markup and ui.css.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const kitDir = new URL("../../.local/src/web-kit/", import.meta.url);
const read = (f) => readFileSync(new URL(f, kitDir), "utf8");
const ctx = vm.createContext({});
vm.runInContext(read("kb-ui.js") + ";this.kbUi = kbUi;", ctx, { filename: "kb-ui.js" });
const { esc, errPanel, fold, clamp2, clamp1, rec2, tblRec } = ctx.kbUi;

test("tblRec draws each record as a row, its cells as sent, a row's own class kept", () => {
  const h = tblRec([["<b>a</b>", "b & c"], { cells: ["x"], cls: "late" }], "tags");
  assert.equal(h, '<table class="rec tags"><tr><td><b>a</b></td><td>b & c</td></tr>' +
    '<tr class="late"><td>x</td></tr></table>');
  assert.equal(tblRec([]), '<table class="rec"></table>');
});

test("clamp2, clamp1 and rec2 escape the full text into the title and keep the cell's html", () => {
  assert.equal(clamp2("<i>t</i>", 'a "b"'), '<div class="c2" title="a &quot;b&quot;"><i>t</i></div>');
  assert.equal(clamp1("t", "x"), '<div class="c12" title="x">t</div>');
  assert.equal(rec2("name", "name", "", ""), '<div class="c1" title="name">name</div><div class="c1 muted" title="">&nbsp;</div>');
  assert.equal(rec2("n", "n", "where", "where <1>"), '<div class="c1" title="n">n</div><div class="c1 muted" title="where &lt;1&gt;">where</div>');
});

test("errPanel and fold escape their text and carry their options", () => {
  assert.equal(errPanel("a <b>"), '<div class="err">a &lt;b&gt;</div>');
  assert.equal(errPanel("x", { card: true, tag: "span", id: "m", cls: "msg" }), '<span class="msg card err" id="m">x</span>');
  assert.equal(fold("cfold", "Why", "<p>x</p>", { k: "a b", open: true }), '<details class="cfold" data-k="a b" open><summary>Why</summary><p>x</p></details>');
  assert.equal(esc("<&'\">"), "&lt;&amp;&#39;&quot;&gt;");
});

test("every class the renderers draw has a rule in ui.css", () => {
  const css = read("ui.css");
  const drawn = [tblRec([["a"]]), clamp2("a", "a"), clamp1("a", "a"), rec2("a", "a", "b", "b"), errPanel("e"), fold("cfold", "s", "i"), ctx.kbUi.secHead("x", "T", 1, "warn")].join("");
  const classes = new Set([...drawn.matchAll(/class="([^"]+)"/g)].flatMap((m) => m[1].split(" ")));
  for (const c of classes) assert.match(css, new RegExp(`\\.${c}\\b`), `no ui.css rule for .${c}`);
});

test("ui.css holds only the kit's tokens: no hard-coded colour or font", () => {
  const bad = read("ui.css").match(/#[0-9a-f]{3,8}\b|rgba?\(|font-family/gi);
  assert.equal(bad, null, "use tokens.css values (ui.md rule 1)");
});
