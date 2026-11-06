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
function draw(data, { raw = false, arg = "", keepBrief = false } = {}) {
  ctx.input = { data, raw, arg, keepBrief };
  vm.runInContext(`st.tab = "daily"; st.arg = input.arg; fcs.data = input.data; fcs.err = null; fcs.raw = input.raw; fcs.open = {}; fcs.undo = null; if (!input.keepBrief) fcs.brief = null; renderFocus();`, ctx);
  return box("d-note").innerHTML;
}

test("today's lanes are cards, open but Done, with counts, and the rollup and other sections fold away", () => {
  const h = draw(day);
  assert.match(h, /<div class="dtitle"><h2>2026-11-05<\/h2><span class="muted">2 open, 1 done<\/span><\/div>/);
  assert.match(h, /<details class="dlane urgent" data-k="lane:Urgent" open><summary class="dlh"><span class="dln">Urgent<\/span><span class="dlc">2<\/span><\/summary>/);
  assert.match(h, /<div class="dlane empty high"><div class="dlh"><span class="dln">High<\/span><span class="dlc">0<\/span><span class="muted">nothing here<\/span>/);
  assert.match(h, /<details class="dlane done" data-k="lane:Done"><summary class="dlh"><span class="dln">Done<\/span><span class="dlc">1<\/span>/);
  assert.match(h, /<li class="task done"><input type="checkbox" disabled checked> water plants/);
  assert.doesNotMatch(h, /ntag">#urgent</, "the Urgent lane says urgent once, in its head");
  assert.match(h, /<details class="cfold" data-k="rollup"><summary><b>Rollup/);
  assert.match(h, /<details class="cfold" data-k="sec:Morning"><summary><b>Morning/);
  assert.match(h, /class="task doing"/, "a [/] line reads as doing");
});

test("a #p: tag opens its project, a wikilink opens its note, a missing one is marked", () => {
  const h = draw(day);
  assert.match(h, /<a href="#projects\/demo" class="ptag">#p:demo<\/a>/);
  assert.match(h, /<a href="#daily\/journal\/refs\/2026-11-05\/briefing" class="wl">the briefing<\/a>/);
  assert.match(box("d-nav").innerHTML, /<a class="dn missing" href="#daily\/gone" title="gone \(no such note\)">Gone<\/a>/);
});

test("Daily's one nav: the places, Daily first, each once, only the open one marked, then the note's parts", () => {
  const h = draw(day);
  assert.doesNotMatch(h, /dlinks|dlink/, "no chips row on the page");
  const nav = box("d-nav").innerHTML;
  assert.match(nav, /^<a class="dn" href="#daily" title="daily" aria-current="page">Daily<\/a><a class="dn" href="#daily\/outbox" title="outbox">Outbox<\/a><a class="dn" href="#daily\/status\/inbox" title="status\/inbox">Inbox<\/a><a class="dn" href="#daily\/journal\/refs\/2026-11-05\/briefing"[^>]*>Briefing<\/a><a class="dn" href="#daily\/lab\/projects\/index"[^>]*>Projects<\/a>/);
  assert.equal(nav.match(/#daily\/outbox"/g).length, 1, "the outbox once, though the note links it too");
  assert.equal(nav.match(/aria-current/g).length, 1);
  assert.match(nav, /<span class="dng">This note<\/span><button class="dn part" data-jump="lane:Urgent">Urgent <span class="dlc">2<\/span><\/button><button class="dn part" data-jump="lane:Done">Done <span class="dlc">1<\/span><\/button><button class="dn part" data-jump="rollup">Rollup<\/button><button class="dn part" data-jump="sec:Morning">Morning<\/button>$/);
  run(`obx.view = { doc: { waiting: 3 } }`);
  draw(day);
  assert.match(box("d-nav").innerHTML, /href="#daily\/outbox" title="outbox">Outbox <span class="dlc">3<\/span><\/a>/, "the waiting count once the outbox is read");
  run(`obx.view = null`);
  draw({ ...day, note: { ...day.note, date: null } }, { arg: "status/inbox" });
  assert.match(box("d-nav").innerHTML, /<a class="dn" href="#daily" title="daily">Daily<\/a>.*href="#daily\/status\/inbox" title="status\/inbox" aria-current="page">Inbox/, "on Inbox, Inbox is marked and Daily is the way back");
});

test("day buttons link to the neighbour that exists; the nav, not the head, is the way back", () => {
  const h = draw(day);
  assert.match(h, /href="#daily\/daily%3A2026-11-04"[^>]*>&lt;</);
  assert.doesNotMatch(h, /Day after/, "no next day, no button");
  assert.doesNotMatch(h, /data-f="back"|>Today</);
  assert.doesNotMatch(draw(day, { arg: "daily:2026-11-04" }), /data-f="back"|>Today</);
  assert.doesNotMatch(draw({ ...day, note: { ...day.note, date: null } }, { arg: "status/inbox" }), /data-f="back"/);
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
  assert.deepEqual(r("#daily/journal/refs/2026-11-05/briefing"), { name: "daily", tab: "daily", arg: "journal/refs/2026-11-05/briefing", query: "" });
  assert.deepEqual(r("#daily/daily%3A2026-11-04"), { name: "daily", tab: "daily", arg: "daily:2026-11-04", query: "" });
  assert.deepEqual(r("#focus/status/inbox"), { name: "focus", tab: "daily", arg: "status/inbox", query: "" }, "an old Focus link still opens its note");
  assert.deepEqual(r("#outbox"), { name: "outbox", tab: "daily", arg: "outbox", query: "" }, "the retired Outbox tab is Daily's outbox");
  assert.deepEqual(r("#projects/notes-cockpit"), { name: "projects", tab: "projects", arg: "notes-cockpit", query: "" });
  assert.deepEqual(r("#board"), { name: "board", tab: "projects", arg: "", query: "" });
  assert.deepEqual(r(""), { name: "", tab: "home", arg: "", query: "" }, "the landing tab is the first");
  assert.deepEqual(r("#fleet?lane=deliver&s=failed"), { name: "fleet", tab: "fleet", arg: "", query: "lane=deliver&s=failed" }, "after a ? is the tab's view state");
  assert.deepEqual(r("#nope"), { name: "nope", tab: "home", arg: "", query: "" });
});

test("Daily writes nothing to the outbox; #daily/outbox shows the outbox view in the note's place", () => {
  assert.doesNotMatch(draw(day), /Add to outbox|f-out/);
  const was = ctx.fetch;
  ctx.fetch = async (url) => reply(200, url.includes("outbox") ? { doc: { text: "", hash: "h", waiting: 0 }, handled: [], counts: "" } : day)();
  run(`st.tab = "daily"; st.arg = "outbox"; TABS.daily.show()`);
  assert.equal(box("d-note").hidden, true);
  assert.equal(box("outbox").hidden, false);
  assert.match(box("outbox").innerHTML, /<h2>Outbox<\/h2><\/div><\/div><textarea/, "the nav has Daily and Inbox; the head is the name alone");
  assert.match(box("outbox").innerHTML, /<button class="btn primary" id="o-send">Send<\/button>/);
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

// The inbox page: a handled row's box is live there and nowhere else, and a tick is one POST.
const inbox = {
  note: { ...day.note, target: "status/inbox", rel: "status/inbox", title: "Inbox", date: null, prev: null, markdown: "", links: [] },
  focus: null,
  sections: [{ title: "Handled today", markdown: "- [ ] 07:20 filed ar-1: words <!-- ack:2026-11-05T07:20:01-08:00 -->" }],
};

test("on the inbox page a handled row's box is live; the same line on another note is not", () => {
  assert.match(draw(inbox, { arg: "status/inbox" }), /<input type="checkbox" data-ack="2026-11-05T07:20:01-08:00">/);
  const other = { ...inbox, note: { ...inbox.note, target: "outbox", rel: "outbox" } };
  assert.doesNotMatch(draw(other, { arg: "outbox" }), /data-ack/);
});

test("a tick posts its key and state and draws the page it gets back; a refusal says why", async () => {
  draw(inbox, { arg: "status/inbox" });
  const after = { ...inbox, sections: [{ title: "Handled today", markdown: "- +1 reviewed\n  - [x] 07:20 filed ar-1: words <!-- ack:2026-11-05T07:20:01-08:00 -->" }] };
  let sent = null;
  ctx.fetch = async (url, opts) => { sent = { url, body: JSON.parse(opts.body) }; return reply(200, after)(); };
  const box1 = { dataset: { ack: "2026-11-05T07:20:01-08:00" }, checked: true, disabled: false };
  ctx.input = box1;
  await run("ackRow(input)");
  assert.deepEqual(sent, { url: "/api/inbox/ack", body: { key: "2026-11-05T07:20:01-08:00", ack: true } });
  assert.equal(box1.disabled, true, "locked until the redraw");
  assert.match(box("d-note").innerHTML, /\+1 reviewed<ul><li class="task done"><input type="checkbox" data-ack="2026-11-05T07:20:01-08:00" checked>/);
  ctx.fetch = reply(409, "no ingest event");
  await run("ackRow(input)");
  assert.match(box("d-note").innerHTML, /panel down">Could not send to inbox \(HTTP 409\)/);
});

// Row actions on a day note: each is the one line changed in the note as read, put over its hash.
const NOTE = "---\ndate: 2026-11-05\n---\n# 2026-11-05\n\n## Focus\n\n### Urgent\n- [ ] fix the menu #p:demo #urgent\n  - [ ] a child\n- [/] wire the bar\n\n### High\n\n### Done\n- [x] water plants\n\n## Morning\n- [ ] call back\n";
const live = {
  ...day,
  note: { ...day.note, markdown: NOTE },
  focus: { lanes: [lane("Urgent", "- [ ] fix the menu #p:demo #urgent\n  - [ ] a child\n- [/] wire the bar", 2, 0), lane("High", "", 0, 0), lane("Done", "- [x] water plants", 0, 1)], rollup: "", open: 2, done: 1 },
  sections: [{ title: "Morning", markdown: "- [ ] call back" }],
};
const lines = (t) => t.split("\n");
function putting(status = 200) {
  const sent = [];
  ctx.fetch = async (url, opts) => {
    const b = JSON.parse(opts.body);
    sent.push(b);
    return reply(status, { ...live, note: { ...live.note, hash: "h" + sent.length, markdown: status < 300 ? b.text : NOTE } })();
  };
  return sent;
}

test("on a day each task row carries its line in the note, a live box and a remove button; each lane but Done adds", () => {
  const h = draw(live);
  for (const n of [8, 9, 10, 15, 18]) assert.match(h, new RegExp(`<input type="checkbox" data-ln="${n}"`), `line ${n}`);
  assert.match(h, /<li class="task"><button class="trm" data-rm="8"[^>]*>-<\/button><input type="checkbox" data-ln="8"> fix the menu/);
  assert.match(h, /<form class="tadd" data-id="Urgent">/);
  assert.match(h, /<div class="dlane empty high">.*<form class="tadd" data-id="High">/s, "an empty lane still adds");
  assert.doesNotMatch(h, /data-id="Done"/);
  assert.doesNotMatch(draw({ ...live, note: { ...live.note, date: null } }, { arg: "status/inbox" }), /data-ln|data-rm|tadd/, "only a day note's rows are live");
});

test("a tick writes [x] on its line and an untick [ ]; nothing else in the note moves", async () => {
  draw(live);
  const sent = putting();
  ctx.input = { dataset: { ln: "8" }, checked: true };
  await run("tickRow(input)");
  assert.equal(sent[0].t, "daily");
  assert.equal(sent[0].base, "aa");
  const want = lines(NOTE); want[8] = "- [x] fix the menu #p:demo #urgent";
  assert.deepEqual(lines(sent[0].text), want);
  ctx.input = { dataset: { ln: "15" }, checked: false };
  await run("tickRow(input)");
  assert.equal(lines(sent[1].text)[15], "- [ ] water plants");
  assert.equal(sent[1].base, "h1", "the next write is over the hash the last one returned");
});

test("remove takes the row and its children, and Undo puts the note back over the new hash", async () => {
  draw(live);
  const sent = putting();
  await run("removeRow(8)");
  assert.deepEqual(lines(sent[0].text).slice(7, 10), ["### Urgent", "- [/] wire the bar", ""]);
  assert.match(box("d-note").innerHTML, /<span class="muted">Removed &quot;fix the menu&quot;<\/span><button class="btn sm" data-f="undo">Undo<\/button>/);
  await run("undoRemove()");
  assert.deepEqual(sent[1], { t: "daily", base: "h1", text: NOTE });
  assert.doesNotMatch(box("d-note").innerHTML, /data-f="undo"/);
});

test("+ adds an open task at the end of its lane, tagged as the lane unless it names a priority", async () => {
  draw(live);
  const sent = putting();
  assert.equal(await run(`addTask("High", "ring the bank")`), true);
  assert.deepEqual(lines(sent[0].text).slice(12, 15), ["### High", "- [ ] ring the bank #high", ""]);
  draw(live);
  await run(`addTask("Urgent", "ship it #low")`);
  assert.deepEqual(lines(sent[1].text).slice(10, 12), ["- [/] wire the bar", "- [ ] ship it #low"]);
});

test("a note changed since the read writes nothing and is shown as it is now; a moved row writes nothing", async () => {
  draw(live);
  const sent = putting(409);
  ctx.input = { dataset: { ln: "8" }, checked: true };
  assert.equal(await run("tickRow(input)"), false);
  assert.match(box("d-note").innerHTML, /panel down">The note changed somewhere else, so nothing was written/);
  draw(live);
  ctx.input = { dataset: { ln: "11" }, checked: true };
  sent.length = 0;
  ctx.fetch = reply(200, live);
  assert.equal(await run("tickRow(input)"), false);
  assert.equal(sent.length, 0);
  assert.match(box("d-note").innerHTML, /That row is not where the page drew it/);
});

test("the day's briefing is read with it and drawn as one open fold after the lanes, a part of the note in the nav", async () => {
  const brief = { note: { ...day.note, target: "journal/refs/2026-11-05/briefing", rel: "journal/refs/2026-11-05/briefing", date: null, links: [] }, focus: null,
    sections: [{ title: "", markdown: "As of 06:45: 2 things need you." }, { title: "Needs you", markdown: "- a red" }] };
  let asked = null;
  ctx.fetch = async (url) => { asked = url; return reply(200, brief)(); };
  ctx.input = day.note.links;
  await run("readBrief(input)");
  assert.equal(asked, "/api/focus?t=journal%2Frefs%2F2026-11-05%2Fbriefing", "the day's own briefing link");
  const h = draw(day, { keepBrief: true });
  assert.match(h, /<details class="cfold" data-k="brief" open><summary><b>Briefing<\/b> <a class="muted" href="#daily\/journal\/refs\/2026-11-05\/briefing">open<\/a><\/summary>.*<p>As of 06:45: 2 things need you\.<\/p><h3>Needs you<\/h3><ul><li>a red/s);
  assert.ok(h.indexOf('data-k="brief"') > h.indexOf('data-k="lane:Done"'), "after the lanes");
  const nav = box("d-nav").innerHTML;
  assert.match(nav, /data-jump="brief">Briefing</);
  assert.doesNotMatch(nav, /href="#daily\/journal\/refs\/2026-11-05\/briefing"/, "drawn on the page, so not a place too");
  ctx.input = day.note.links.filter((l) => !/briefing/.test(l.target));
  await run("readBrief(input)");
  assert.equal(run("fcs.brief"), null, "a day with no briefing draws none");
});
