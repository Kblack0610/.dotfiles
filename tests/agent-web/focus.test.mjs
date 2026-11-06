// Unit tests for the Focus tab (.local/src/agent-web/static/focus.js), run by `node --test` from
// tests/unit/agent_web_queue.bats. The page's real scripts load into one vm context; only the
// DOM is a stub. The lane split is hub_core::focus and the link resolver `notes show`, both
// tested in Rust; this checks how their answer is drawn and where its links go.
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
const box = (id) => (boxes[id] ||= Object.assign(el(), { innerHTML: "", scrollTop: 0, hidden: false, textContent: "", querySelectorAll: () => [] }));
const doc = { getElementById: box, addEventListener() {}, createElement: el, body: el(), querySelector: el, querySelectorAll: () => [] };
const ctx = vm.createContext({
  console,
  document: doc,
  window: { addEventListener() {} },
  fetch: async () => ({ ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => [] }),
});
for (const f of ["ui.js", "md.js", "app.js", "focus.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });

const lane = (name, markdown, open, done) => ({ name, markdown, items: [], open, done });
const day = {
  note: {
    target: "daily", profile: "personal", path: "/n/journal/daily/2026-11-05.md", rel: "journal/daily/2026-11-05",
    title: "2026-11-05", exists: true, date: "2026-11-05", prev: "2026-11-04", next: null, hash: "aa",
    markdown: "# 2026-11-05\n\n## Focus\n- [ ] fix the menu #p:demo\n",
    links: [{ target: "outbox", label: "outbox", exists: true }, { target: "gone", label: "gone", exists: false }],
  },
  focus: {
    lanes: [lane("Urgent", "- [ ] fix the menu #p:demo #urgent\n- [/] wire the bar", 2, 0), lane("High", "", 0, 0), lane("Done", "- [x] water plants", 0, 1)],
    rollup: "### bnb\n- [ ] a bnb row", open: 2, done: 1,
  },
  sections: [{ title: "Morning", markdown: "See [[journal/refs/2026-11-05/briefing|the briefing]]." }],
};

function draw(data, { raw = false, arg = "" } = {}) {
  ctx.input = { data, raw, arg };
  vm.runInContext(`st.tab = "focus"; st.arg = input.arg; fcs.data = input.data; fcs.err = null; fcs.raw = input.raw; fcs.open = {}; renderFocus();`, ctx);
  return box("focus").innerHTML;
}

test("today's lanes are open but Done, with counts, and the rollup and other sections fold away", () => {
  const h = draw(day);
  assert.match(h, /FOCUS 2026-11-05 <span class="muted">2 open, 1 done<\/span>/);
  assert.match(h, /<details class="cfold" data-k="lane:Urgent" open><summary><b>Urgent<\/b> <span class="muted">\(2\)<\/span>/);
  assert.match(h, /data-k="lane:High" open>.*nothing here/s);
  assert.match(h, /<details class="cfold" data-k="lane:Done"><summary><b>Done<\/b> <span class="muted">\(1\)/);
  assert.match(h, /<details class="cfold" data-k="rollup"><summary><b>Rollup/);
  assert.match(h, /<details class="cfold" data-k="sec:Morning"><summary><b>Morning/);
  assert.match(h, /class="task doing"/, "a [/] line reads as doing");
});

test("a #p: tag opens its project, a wikilink opens its note, a missing one is marked", () => {
  const h = draw(day);
  assert.match(h, /<a href="#projects\/demo" class="ptag">#p:demo<\/a>/);
  assert.match(h, /<a href="#focus\/journal\/refs\/2026-11-05\/briefing" class="wl">the briefing<\/a>/);
  assert.match(h, /<a class="wl" href="#focus\/outbox"[^>]*>outbox<\/a>/);
  assert.match(h, /<a class="wl missing" href="#focus\/gone" title="gone \(no such note\)">gone<\/a>/);
});

test("day buttons link to the neighbour that exists; Back and Today show only away from today", () => {
  const h = draw(day);
  assert.match(h, /href="#focus\/daily%3A2026-11-04"[^>]*>&lt; day</);
  assert.doesNotMatch(h, /day &gt;/, "no next day, no button");
  assert.doesNotMatch(h, /data-f="back"/);
  const away = draw(day, { arg: "daily:2026-11-04" });
  assert.match(away, /data-f="back">Back<\/button><a class="btn sm" href="#focus">Today<\/a>/);
});

test("a note opened from a link is all sections, open, its untitled top drawn as is", () => {
  const h = draw({
    note: { ...day.note, target: "outbox", rel: "outbox", title: "Outbox", date: null, prev: null, markdown: "# Outbox\n", links: [] },
    focus: null,
    sections: [{ title: "", markdown: "One per line." }, { title: "Outbox", markdown: "- [ ] a line" }],
  }, { arg: "outbox" });
  assert.match(h, /FOCUS <span title="\/n\/journal\/daily\/2026-11-05.md">outbox<\/span><\/span>/);
  assert.doesNotMatch(h, /open, .* done/, "no Focus, no counts");
  assert.match(h, /<div class="md"><p>One per line\.<\/p><\/div><details class="cfold" data-k="sec:Outbox" open>/);
});

test("Raw is the note's markdown, escaped, with Copy; a missing day says so and is no error", () => {
  const raw = draw({ ...day, note: { ...day.note, markdown: "<b>x</b> [[outbox]]" } }, { raw: true });
  assert.match(raw, /data-f="copy">Copy<\/button>/);
  assert.match(raw, /<pre class="raw">&lt;b&gt;x&lt;\/b&gt; \[\[outbox\]\]<\/pre>/);
  assert.doesNotMatch(raw, /class="wl"/, "raw does not render links");
  const none = draw({ note: { ...day.note, exists: false, markdown: "", links: [] }, focus: null, sections: [] });
  assert.match(none, /No note for 2026-11-05 yet\./);
  assert.doesNotMatch(none, /panel down/);
});

test("a hash routes to its tab and the note it opens, decoded", () => {
  const r = (h) => JSON.parse(vm.runInContext(`JSON.stringify(route(${JSON.stringify(h)}))`, ctx));
  assert.deepEqual(r("#focus/journal/refs/2026-11-05/briefing"), { name: "focus", tab: "focus", arg: "journal/refs/2026-11-05/briefing" });
  assert.deepEqual(r("#focus/daily%3A2026-11-04"), { name: "focus", tab: "focus", arg: "daily:2026-11-04" });
  assert.deepEqual(r("#projects/notes-cockpit"), { name: "projects", tab: "projects", arg: "notes-cockpit" });
  assert.deepEqual(r("#board"), { name: "board", tab: "projects", arg: "" });
  assert.deepEqual(r(""), { name: "", tab: "outbox", arg: "" }, "the landing tab is the first");
  assert.deepEqual(r("#nope"), { name: "nope", tab: "outbox", arg: "" });
});

test("the Focus tab writes nothing to the outbox; its head links to the Outbox tab", () => {
  const h = draw(day);
  assert.doesNotMatch(h, /Add to outbox|f-out/);
  assert.match(h, /<a class="btn sm" href="#outbox">Outbox<\/a>/);
});

// Edit and Save: the page's side of `notes put --base` (the CLI's compare-and-swap is tested in
// notes-cli, the 200/409/502 mapping in agent-web's cli.rs).
const store = new Map();
ctx.localStorage = { getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, String(v)), removeItem: (k) => store.delete(k) };
ctx.confirm = () => true;
const reply = (status, body) => async () => ({ ok: status < 300, status, statusText: "", headers: { get: () => "application/json" }, json: async () => body, text: async () => JSON.stringify(body) });
const run = (code) => vm.runInContext(code, ctx);
const KEY = "focus-draft:" + day.note.path;

function editing(data = day) {
  store.clear();
  draw(data);
  run("startEdit()");
  return box("focus").innerHTML;
}

test("Edit opens the note's markdown in a textarea with Save; the reading view has none", () => {
  assert.doesNotMatch(draw(day), /<textarea/, "no editor until Edit");
  assert.match(draw(day), /data-f="edit">Edit<\/button>/);
  const h = editing();
  assert.match(h, /<textarea id="f-edit"[^>]*># 2026-11-05\n\n## Focus\n- \[ \] fix the menu #p:demo\n<\/textarea>/);
  assert.match(h, /data-f="save">Save<\/button>/);
  assert.match(h, /data-f="cancel">Cancel<\/button>/);
  assert.doesNotMatch(h, /data-f="raw"/, "no Rendered/Raw while editing");
  assert.doesNotMatch(h, /data-f="edit"/);
});

test("the outbox has no Edit: its editor is the Outbox tab", () => {
  const h = draw({ note: { ...day.note, target: "outbox", rel: "outbox", date: null, links: [] }, focus: null, sections: [] }, { arg: "outbox" });
  assert.doesNotMatch(h, /data-f="edit"/);
});

test("a re-read while editing leaves the textarea alone and warns that the note moved", async () => {
  const before = editing();
  run(`fcs.edit.text = "typed"`);
  ctx.fetch = reply(200, { ...day, note: { ...day.note, hash: "bb" } });
  await run("refreshFocus()");
  assert.equal(box("focus").innerHTML, before, "the editor is not redrawn under the typing");
  assert.match(box("f-edit-st").textContent, /changed elsewhere since you opened it; Save will show both/);
});

test("a 409 writes nothing, shows the note as it is now beside yours, and Save mine over it takes its hash", async () => {
  editing();
  run(`fcs.edit.text = "mine"`);
  const now = { ...day, note: { ...day.note, hash: "cc", markdown: "from nvim <b>\n" } };
  ctx.fetch = reply(409, now);
  await run("saveEdit(fcs.edit.base)");
  const h = box("focus").innerHTML;
  assert.match(h, /This note changed after you opened it\. Nothing was written\./);
  assert.match(h, /<pre class="raw">from nvim &lt;b&gt;\n<\/pre>/);
  assert.match(h, /data-f="over"[^>]*>Save mine over it<\/button>/);
  assert.match(h, /data-f="copymine">Copy mine<\/button><button class="btn sm" data-f="discard">Discard mine<\/button>/);
  assert.doesNotMatch(h, /data-f="save"/, "a plain Save would go stale again");
  assert.match(h, /<textarea id="f-edit"[^>]*>mine<\/textarea>/, "your text is still there");
  let sent = null;
  ctx.fetch = async (url, opts) => { sent = JSON.parse(opts.body); return reply(200, now)(); };
  await run("saveEdit(fcs.edit.stale.hash)");
  assert.deepEqual(sent, { t: "daily", base: "cc", text: "mine" });
  assert.equal(run("fcs.edit"), null);
  assert.equal(store.has(KEY), false, "a saved edit leaves no draft");
  assert.match(box("focus").innerHTML, /<span class="muted">Saved [^<]+<\/span>/);
});

test("a draft kept on the device comes back; one made on an older read opens on the changed view", () => {
  store.clear();
  store.set(KEY, JSON.stringify({ base: "aa", text: "half typed", at: 1 }));
  assert.match(draw(day), /data-f="edit">Edit \(draft\)<\/button>/);
  run("startEdit()");
  let h = box("focus").innerHTML;
  assert.match(h, /<textarea id="f-edit"[^>]*>half typed<\/textarea>/);
  assert.doesNotMatch(h, /changed after you opened it/);
  run("fcs.edit = null");
  store.set(KEY, JSON.stringify({ base: "00", text: "from last night", at: 1 }));
  draw(day);
  run("startEdit()");
  h = box("focus").innerHTML;
  assert.match(h, /This note changed after you opened it/);
  assert.match(h, /<textarea id="f-edit"[^>]*>from last night<\/textarea>/);
  run("discardEdit()");
  assert.equal(store.has(KEY), false);
  assert.equal(run("fcs.edit"), null);
});
