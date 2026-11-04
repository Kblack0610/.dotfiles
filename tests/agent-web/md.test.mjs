// Unit tests for agent-web's markdown renderer (.local/src/agent-web/static/md.js), run by
// `node --test` from tests/unit/agent_web_md.bats. The renderer's one hard promise is that
// text never becomes HTML, so most cases here are about escaping.
import { test } from "node:test";
import assert from "node:assert/strict";
import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const { md } = require("../../.local/src/agent-web/static/md.js");

test("raw HTML is escaped, never rendered", () => {
  assert.equal(md("<script>alert(1)</script>"), "<p>&lt;script&gt;alert(1)&lt;/script&gt;</p>");
  assert.equal(md('<img src=x onerror="a()">'), "<p>&lt;img src=x onerror=&quot;a()&quot;&gt;</p>");
});

test("only http(s) URLs become links, and their quotes stay escaped", () => {
  assert.equal(md("[x](javascript:alert(1))"), "<p>[x](javascript:alert(1))</p>");
  assert.equal(md('see "https://a.dev/p?q=1&r=2".'),
    '<p>see &quot;<a href="https://a.dev/p?q=1&amp;r=2" target="_blank" rel="noopener noreferrer">https://a.dev/p?q=1&amp;r=2</a>&quot;.</p>');
  assert.equal(md("[docs](https://a.dev/x)"), '<p><a href="https://a.dev/x" target="_blank" rel="noopener noreferrer">docs</a></p>');
});

test("a NUL in the text cannot forge a placeholder", () => {
  assert.equal(md("a\u00000\u0000b `c`"), "<p>a0b <code>c</code></p>");
});

test("code spans and fences keep their text literal", () => {
  assert.equal(md("run `a **b** <c>`"), "<p>run <code>a **b** &lt;c&gt;</code></p>");
  assert.equal(md("```sh\necho <x> **y**\n```"), '<pre class="md-code" data-lang="sh"><code>echo &lt;x&gt; **y**</code></pre>');
  assert.equal(md("```\nopen fence"), '<pre class="md-code"><code>open fence</code></pre>');
});

test("emphasis leaves snake_case and arithmetic alone", () => {
  assert.equal(md("**bold** and *it* and _it_ and ~~gone~~"), "<p><strong>bold</strong> and <em>it</em> and <em>it</em> and <del>gone</del></p>");
  assert.equal(md("snake_case_name and 2 * 3 * 4"), "<p>snake_case_name and 2 * 3 * 4</p>");
});

test("headings, rules and quotes", () => {
  assert.equal(md("## Plan\n---\n> said\n> more"), "<h2>Plan</h2><hr><blockquote><p>said<br>more</p></blockquote>");
});

test("paragraph lines keep their breaks; a blank line splits paragraphs", () => {
  assert.equal(md("a\nb\n\nc"), "<p>a<br>b</p><p>c</p>");
});

test("lists nest by indent, ordered lists keep their start, task boxes render", () => {
  assert.equal(md("- a\n  - b\n- c"), "<ul><li>a<ul><li>b</li></ul></li><li>c</li></ul>");
  assert.equal(md("3. x\n4. y"), '<ol start="3"><li>x</li><li>y</li></ol>');
  assert.equal(md("- [x] done\n- [ ] todo"), '<ul><li class="task"><input type="checkbox" disabled checked> done</li><li class="task"><input type="checkbox" disabled> todo</li></ul>');
  assert.equal(md("- a\n  wrapped"), "<ul><li>a\nwrapped</li></ul>");
});

test("a pipe table with alignment; an escaped pipe stays in its cell, as in GFM", () => {
  assert.equal(md("| a | b |\n|---|--:|\n| 1 | `x\\|y` |"),
    '<div class="md-table"><table><thead><tr><th>a</th><th style="text-align:right">b</th></tr></thead><tbody><tr><td>1</td><td style="text-align:right"><code>x|y</code></td></tr></tbody></table></div>');
});

test("empty and null input render nothing", () => {
  assert.equal(md(""), "");
  assert.equal(md(null), "");
});
