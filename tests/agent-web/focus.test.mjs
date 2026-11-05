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
    title: "2026-11-05", exists: true, date: "2026-11-05", prev: "2026-11-04", next: null,
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
  assert.deepEqual(r(""), { name: "", tab: "home", arg: "" });
});

test("Add to outbox sends the typed line as one POST, says where it went, and an error stays", async () => {
  const sent = [];
  ctx.fetch = async (path, opts) => { sent.push([path, opts && opts.body]); return { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => ({ said: "outbox: - [ ] x" }) }; };
  assert.match(draw(day), /<h2 class="sec">Add to outbox<\/h2>.*id="f-out".*data-f="send">Send</s);
  vm.runInContext(`fcs.draft = "  ask about <b>it</b>  "; fcs.said = null;`, ctx);
  await vm.runInContext(`sendOutbox()`, ctx);
  assert.deepEqual(sent.find(([p]) => p === "/api/outbox"), ["/api/outbox", JSON.stringify({ text: "ask about <b>it</b>" })]);
  const h = box("focus").innerHTML;
  assert.match(h, /Sent "ask about &lt;b&gt;it&lt;\/b&gt;"\. The triager files it from the <a class="wl" href="#focus\/outbox">outbox<\/a>/);
  assert.match(h, /id="f-out" placeholder="[^"]*" value=""/, "the box is cleared after a send");
  ctx.fetch = async () => ({ ok: false, status: 502, statusText: "", text: async () => "notes: no outbox" });
  vm.runInContext(`fcs.draft = "again";`, ctx);
  await vm.runInContext(`sendOutbox()`, ctx);
  assert.match(box("focus").innerHTML, /<div class="err">Could not send to outbox \(HTTP 502\): notes: no outbox/);
  assert.match(box("focus").innerHTML, /value="again"/, "a failed send keeps the line");
});
