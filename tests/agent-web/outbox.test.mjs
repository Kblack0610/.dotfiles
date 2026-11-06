// Unit tests for Daily's outbox view (.local/src/agent-web/static/outbox.js), run by `node --test` from
// tests/unit/agent_web_queue.bats. The page's real scripts load into one vm context; the DOM and
// fetch are stubs. The compare-and-swap itself is `notes outbox put --base` (notes-cli tests);
// this checks the page's half: the line merge, the held-back cursor line, and a 409 re-save.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);

const el = () => new Proxy({}, {
  get: (t, k) => (k in t ? t[k] : k === "classList" ? { add() {}, remove() {}, toggle() {} } : k === "dataset" ? {} : () => el()),
  set: (t, k, v) => { t[k] = v; return true; },
});
const boxes = {};
const area = { value: "", selectionStart: 0, addEventListener() {}, setSelectionRange(a) { this.selectionStart = a; } };
const box = (id) => (id === "o-doc" ? area : (boxes[id] ||= Object.assign(el(), { innerHTML: "", scrollTop: 0, hidden: false, textContent: "", querySelectorAll: () => [] })));
const doc = { getElementById: box, addEventListener() {}, createElement: el, body: el(), querySelector: el, querySelectorAll: () => [], activeElement: null };
const ctx = vm.createContext({
  console, document: doc, window: { addEventListener() {} }, location: { reload() {} },
  setTimeout: () => 0, clearTimeout() {},
  fetch: async () => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => [] }),
});
for (const f of ["ui.js", "md.js", "app.js", "outbox.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
const run = (code, input) => { ctx.input = input; return JSON.parse(vm.runInContext(`JSON.stringify(${code})`, ctx)); };

test("a line the sweep took leaves, a line typed since stays, a line an agent added arrives", () => {
  const m = run("mergeLines(input.base, input.theirs, input.mine)", {
    base: ["one", "two"],
    theirs: ["two", "agent line"],
    mine: ["one", "two", "three"],
  });
  assert.deepEqual(m.lines, ["two", "three", "agent line"]);
  assert.deepEqual(m.at, [-1, 0, 1], "one was taken; two and three moved up");
});

test("a line you deleted stays deleted, and a clean box simply becomes theirs", () => {
  assert.deepEqual(run("mergeLines(input.b, input.t, input.m).lines", { b: ["a", "b"], t: ["a", "b"], m: ["a"] }), ["a"]);
  assert.deepEqual(run("mergeLines(input.b, input.t, input.b).lines", { b: ["a", "b", "c"], t: ["c"] }), ["c"]);
  assert.deepEqual(run("mergeLines(input.b, input.t, input.m).lines", { b: ["x", "x"], t: ["x"], m: ["x", "x", "x"] }), ["x", "x"], "duplicates count one for one");
});

test("the line under the cursor is held back while new, sent once the cursor leaves it", () => {
  const typing = run("outgoing(input.t, input.t.length, ['one'])", { t: "one\nhalf a thou" });
  assert.deepEqual(typing, { text: "one", held: true });
  assert.deepEqual(run("outgoing(input.t, input.t.length, ['one'])", { t: "one\nhalf a thought\n" }), { text: "one\nhalf a thought\n", held: false }, "after Enter the cursor is on a blank line");
  assert.deepEqual(run("outgoing(input.t, 2, ['one'])", { t: "one\nnew" }), { text: "one\nnew", held: false }, "a line already saved is not held");
  assert.deepEqual(run("outgoing(input.t, -1, [])", { t: "a\nb" }), { text: "a\nb", held: false }, "an unfocused box sends all");
});

test("a 409 merges the sweep's doc and saves again against its hash; the typed line survives", async () => {
  const puts = [];
  const docs = {
    read: { doc: { path: "/n/outbox.md", hash: "aa", text: "one\ntwo", waiting: 2 }, handled: [], counts: "" },
    swept: { path: "/n/outbox.md", hash: "bb", text: "two", waiting: 1 },
  };
  ctx.fetch = async (path, opts) => {
    const ok = (status, body) => ({ ok: status < 300, status, headers: { get: () => "application/json" }, json: async () => body, text: async () => "" });
    if (!opts || !opts.method) return ok(200, docs.read);
    const b = JSON.parse(opts.body);
    puts.push(b);
    if (b.base === "aa") return ok(409, docs.swept);
    return ok(200, { path: "/n/outbox.md", hash: "cc", text: b.text, waiting: 2 });
  };
  vm.runInContext(`st.tab = "daily"; st.arg = "outbox"; OUTBOX.show();`, ctx);
  await new Promise((r) => setImmediate(r));
  assert.equal(area.value, "one\ntwo");
  area.value = "one\ntwo\nthree";
  await vm.runInContext(`sync()`, ctx);
  assert.deepEqual(puts, [{ base: "aa", text: "one\ntwo\nthree" }, { base: "bb", text: "two\nthree" }]);
  assert.equal(area.value, "two\nthree", "the swept line left the box; the typed one stayed");
  assert.match(box("o-said").innerHTML, /2 waiting\. saved \d\d:\d\d/);
});

test("Handled today says what was done to each line, newest first, and left lines stand out", () => {
  const h = run("handledHtml(input)", {
    counts: "1 filed, 1 left",
    handled: [
      { ts: "2026-11-05T13:40:00-08:00", action: "left", to: "", text: "maybe tidy <stuff>", why: "too vague" },
      { ts: "2026-11-05T14:01:00-08:00", action: "filed", to: "dodginballs", text: "fix(audio): gun shot late", id: "db-51" },
    ],
  });
  assert.match(h, /Handled today <span class="muted">1 filed, 1 left/);
  assert.match(h, /<li class="warn"><span class="muted">13:40<\/span> left: maybe tidy &lt;stuff&gt; <span class="muted">\(why: too vague\)/);
  assert.match(h, /14:01<\/span> filed db-51 in <a class="wl" href="#projects\/dodginballs">dodginballs<\/a>: fix\(audio\)/);
  assert.match(run("handledHtml(input)", { counts: "", handled: [] }), /Nothing handled yet today\./);
});
