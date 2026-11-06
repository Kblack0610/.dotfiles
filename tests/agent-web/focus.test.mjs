// Unit tests for the Daily tab (.local/src/agent-web/static/focus.js), run by `node --test` from
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
for (const f of ["ui.js", "md.js", "app.js", "outbox.js", "focus.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });

const lane = (name, markdown, open, done) => ({ name, markdown, items: [], open, done });
const day = {
  note: {
    target: "daily", profile: "personal", path: "/n/journal/daily/2026-11-05.md", rel: "journal/daily/2026-11-05",
    title: "2026-11-05", exists: true, date: "2026-11-05", prev: "2026-11-04", next: null, hash: "aa",
    markdown: "# 2026-11-05\n\n## Focus\n- [ ] fix the menu #p:demo\n",
    links: [{ target: "outbox", label: "outbox", exists: true }, { target: "status/inbox", label: "status/inbox", exists: true },
      { target: "journal/refs/2026-11-05/briefing", label: "journal/refs/2026-11-05/briefing", exists: true },
      { target: "lab/projects/index", label: "lab/projects/index", exists: true }, { target: "gone", label: "gone", exists: false }],
  },
  focus: {
    lanes: [lane("Urgent", "- [ ] fix the menu #p:demo #urgent\n- [/] wire the bar", 2, 0), lane("High", "", 0, 0), lane("Done", "- [x] water plants", 0, 1)],
    rollup: "### bnb\n- [ ] a bnb row", open: 2, done: 1,
  },
  sections: [{ title: "Morning", markdown: "See [[journal/refs/2026-11-05/briefing|the briefing]]." }],
};

const run = (code) => vm.runInContext(code, ctx);
const reply = (status, body) => async () => ({ ok: status < 300, status, statusText: "", headers: { get: () => "application/json" }, json: async () => body, text: async () => JSON.stringify(body) });
function draw(data, { raw = false, arg = "" } = {}) {
  ctx.input = { data, raw, arg };
  vm.runInContext(`st.tab = "daily"; st.arg = input.arg; fcs.data = input.data; fcs.err = null; fcs.raw = input.raw; fcs.open = {}; renderFocus();`, ctx);
  return box("d-note").innerHTML;
}

test("today's lanes are cards, open but Done, with counts, and the rollup and other sections fold away", () => {
  const h = draw(day);
  assert.match(h, /<div class="dtitle"><h2>2026-11-05<\/h2><span class="muted">2 open, 1 done<\/span><\/div>/);
  assert.match(h, /<details class="dlane urgent" data-k="lane:Urgent" open><summary class="dlh"><span class="dln">Urgent<\/span><span class="dlc">2<\/span><\/summary>/);
  assert.match(h, /<div class="dlane empty high"><div class="dlh"><span class="dln">High<\/span><span class="dlc">0<\/span><span class="muted">nothing here<\/span>/);
  assert.match(h, /<details class="dlane done" data-k="lane:Done"><summary class="dlh"><span class="dln">Done<\/span><span class="dlc">1<\/span>/);
  assert.match(h, /<li class="task done"><input type="checkbox" disabled checked> water plants/);
  assert.match(h, /<span class="ntag">#urgent<\/span>/);
  assert.match(h, /<details class="cfold" data-k="rollup"><summary><b>Rollup/);
  assert.match(h, /<details class="cfold" data-k="sec:Morning"><summary><b>Morning/);
  assert.match(h, /class="task doing"/, "a [/] line reads as doing");
});

test("a #p: tag opens its project, a wikilink opens its note, a missing one is marked", () => {
  const h = draw(day);
  assert.match(h, /<a href="#projects\/demo" class="ptag">#p:demo<\/a>/);
  assert.match(h, /<a href="#daily\/journal\/refs\/2026-11-05\/briefing" class="wl">the briefing<\/a>/);
  assert.match(h, /<a class="dlink missing" href="#daily\/gone" title="gone \(no such note\)">Gone<\/a>/);
});

test("a day leads with its links as buttons, the outbox first and once, each by a short name", () => {
  const h = draw(day);
  assert.ok(h.indexOf('class="dlinks"') < h.indexOf('class="dlane'), "links come before the lanes");
  assert.match(h, /<nav class="dlinks"><a class="dlink out" href="#daily\/outbox">Outbox<\/a><a class="dlink" href="#daily\/status\/inbox"[^>]*>Inbox<\/a><a class="dlink" href="#daily\/journal\/refs\/2026-11-05\/briefing"[^>]*>Briefing<\/a><a class="dlink" href="#daily\/lab\/projects\/index"[^>]*>Projects<\/a>/);
  assert.equal(h.match(/#daily\/outbox"/g).length, 1);
  run(`obx.view = { doc: { waiting: 3 } }`);
  assert.match(draw(day), /href="#daily\/outbox">Outbox <span class="dlc">3<\/span><\/a>/, "the waiting count once the outbox is read");
  run(`obx.view = null`);
});

test("day buttons link to the neighbour that exists; Back and Today show only away from today", () => {
  const h = draw(day);
  assert.match(h, /href="#daily\/daily%3A2026-11-04"[^>]*>&lt;</);
  assert.doesNotMatch(h, /Day after/, "no next day, no button");
  assert.doesNotMatch(h, /data-f="back"|>Today</);
  const away = draw(day, { arg: "daily:2026-11-04" });
  assert.match(away, /aria-label="Day before">&lt;<\/a><a class="btn sm" href="#daily">Today<\/a>/);
  assert.doesNotMatch(away, /data-f="back"/, "a day steps by day, not by Back");
  assert.match(draw({ ...day, note: { ...day.note, date: null } }, { arg: "status/inbox" }), /data-f="back">Back<\/button>/);
});

test("a note opened from a link is all sections, open, its untitled top drawn as is", () => {
  const h = draw({
    note: { ...day.note, target: "outbox", rel: "outbox", title: "Outbox", date: null, prev: null, markdown: "# Outbox\n", links: [] },
    focus: null,
    sections: [{ title: "", markdown: "One per line." }, { title: "Outbox", markdown: "- [ ] a line" }],
  }, { arg: "status/inbox" });
  assert.match(h, /<h2><span title="\/n\/journal\/daily\/2026-11-05.md">outbox<\/span><\/h2>/);
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
  assert.deepEqual(r("#daily/journal/refs/2026-11-05/briefing"), { name: "daily", tab: "daily", arg: "journal/refs/2026-11-05/briefing" });
  assert.deepEqual(r("#daily/daily%3A2026-11-04"), { name: "daily", tab: "daily", arg: "daily:2026-11-04" });
  assert.deepEqual(r("#focus/status/inbox"), { name: "focus", tab: "daily", arg: "status/inbox" }, "an old Focus link still opens its note");
  assert.deepEqual(r("#outbox"), { name: "outbox", tab: "daily", arg: "outbox" }, "the retired Outbox tab is Daily's outbox");
  assert.deepEqual(r("#projects/notes-cockpit"), { name: "projects", tab: "projects", arg: "notes-cockpit" });
  assert.deepEqual(r("#board"), { name: "board", tab: "projects", arg: "" });
  assert.deepEqual(r(""), { name: "", tab: "home", arg: "" }, "the landing tab is the first");
  assert.deepEqual(r("#nope"), { name: "nope", tab: "home", arg: "" });
});

test("Daily writes nothing to the outbox; #daily/outbox shows the outbox view in the note's place", () => {
  assert.doesNotMatch(draw(day), /Add to outbox|f-out/);
  const was = ctx.fetch;
  ctx.fetch = async (url) => reply(200, url.includes("outbox") ? { doc: { text: "", hash: "h", waiting: 0 }, handled: [], counts: "" } : day)();
  run(`st.tab = "daily"; st.arg = "outbox"; TABS.daily.show()`);
  assert.equal(box("d-note").hidden, true);
  assert.equal(box("outbox").hidden, false);
  assert.match(box("outbox").innerHTML, /<h2>Outbox<\/h2>.*href="#daily">Back to Daily<\/a><a class="btn sm" href="#daily\/status\/inbox">Inbox<\/a>/s);
  run(`st.arg = ""; TABS.daily.show()`);
  assert.equal(box("d-note").hidden, false);
  assert.equal(box("outbox").hidden, true);
  ctx.fetch = was;
  run(`obx.view = null`);
});

// Edit and Save: the page's side of `notes put --base` (the CLI's compare-and-swap is tested in
// notes-cli, the 200/409/502 mapping in agent-web's cli.rs).
const store = new Map();
ctx.localStorage = { getItem: (k) => (store.has(k) ? store.get(k) : null), setItem: (k, v) => store.set(k, String(v)), removeItem: (k) => store.delete(k) };
ctx.confirm = () => true;
const KEY = "focus-draft:" + day.note.path;

function editing(data = day) {
  store.clear();
  draw(data);
  run("startEdit()");
  return box("d-note").innerHTML;
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

test("the outbox note has no Edit: its editor is #daily/outbox", () => {
  const h = draw({ note: { ...day.note, target: "outbox", rel: "outbox", date: null, links: [] }, focus: null, sections: [] }, { arg: "outbox" });
  assert.doesNotMatch(h, /data-f="edit"/);
});

test("a re-read while editing leaves the textarea alone and warns that the note moved", async () => {
  const before = editing();
  run(`fcs.edit.text = "typed"`);
  ctx.fetch = reply(200, { ...day, note: { ...day.note, hash: "bb" } });
  await run("refreshFocus()");
  assert.equal(box("d-note").innerHTML, before, "the editor is not redrawn under the typing");
  assert.match(box("f-edit-st").textContent, /changed elsewhere since you opened it; Save will show both/);
});

test("a 409 writes nothing, shows the note as it is now beside yours, and Save mine over it takes its hash", async () => {
  editing();
  run(`fcs.edit.text = "mine"`);
  const now = { ...day, note: { ...day.note, hash: "cc", markdown: "from nvim <b>\n" } };
  ctx.fetch = reply(409, now);
  await run("saveEdit(fcs.edit.base)");
  const h = box("d-note").innerHTML;
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
  assert.match(box("d-note").innerHTML, /<span class="muted">Saved [^<]+<\/span>/);
});

test("a draft kept on the device comes back; one made on an older read opens on the changed view", () => {
  store.clear();
  store.set(KEY, JSON.stringify({ base: "aa", text: "half typed", at: 1 }));
  assert.match(draw(day), /data-f="edit">Edit \(draft\)<\/button>/);
  run("startEdit()");
  let h = box("d-note").innerHTML;
  assert.match(h, /<textarea id="f-edit"[^>]*>half typed<\/textarea>/);
  assert.doesNotMatch(h, /changed after you opened it/);
  run("fcs.edit = null");
  store.set(KEY, JSON.stringify({ base: "00", text: "from last night", at: 1 }));
  draw(day);
  run("startEdit()");
  h = box("d-note").innerHTML;
  assert.match(h, /This note changed after you opened it/);
  assert.match(h, /<textarea id="f-edit"[^>]*>from last night<\/textarea>/);
  run("discardEdit()");
  assert.equal(store.has(KEY), false);
  assert.equal(run("fcs.edit"), null);
});
