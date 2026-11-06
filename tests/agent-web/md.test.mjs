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
  assert.equal(md("- [x] done\n- [ ] todo"), '<ul><li class="task done"><input type="checkbox" disabled checked> done</li><li class="task"><input type="checkbox" disabled> todo</li></ul>');
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

test("notes mode links a wikilink to its note and a #p: tag to its project, in-app", () => {
  const n = { notes: true };
  assert.equal(md("see [[status/inbox|Inbox]] and [[outbox]]", n),
    '<p>see <a href="#daily/status/inbox" class="wl">Inbox</a> and <a href="#daily/outbox" class="wl">outbox</a></p>');
  assert.equal(md("- [ ] fix it #p:notes-cockpit #urgent", n),
    '<ul><li class="task"><input type="checkbox" disabled> fix it <a href="#projects/notes-cockpit" class="ptag">#p:notes-cockpit</a> <span class="ntag">#urgent</span></li></ul>');
  // A tag is a chip only in notes mode, never a heading's # or a #p: tag, and only from a letter.
  assert.equal(md("x #urgent #3 a#b", n), '<p>x <span class="ntag">#urgent</span> #3 a#b</p>');
  assert.equal(md("x #urgent"), "<p>x #urgent</p>");
  // A label or target cannot break out of the attribute or the text.
  assert.equal(md('[[a"b|<i>]]', n), '<p><a href="#daily/a%22b" class="wl">&lt;i&gt;</a></p>');
});

test("notes mode drops HTML comments and reads [/] as doing", () => {
  const h = md("- [/] wiring\n<!-- rollup:start -->\n- [x] done", { notes: true });
  assert.match(h, /<li class="task doing"><input type="checkbox" disabled> <span class="cchip running">doing<\/span> wiring<\/li>/);
  assert.doesNotMatch(h, /rollup:start/);
});

test("outside notes mode, and inside code, wikilinks and #p: stay text; web links still open a new tab", () => {
  assert.equal(md("[[outbox]] #p:x"), "<p>[[outbox]] #p:x</p>");
  assert.equal(md("`#p:x [[y]]`", { notes: true }), "<p><code>#p:x [[y]]</code></p>");
  assert.match(md("https://a.dev [[x]]", { notes: true }), /<a href="https:\/\/a\.dev" target="_blank" rel="noopener noreferrer">/);
  assert.equal(md("<!-- kept -->"), "<p>&lt;!-- kept --&gt;</p>");
});
