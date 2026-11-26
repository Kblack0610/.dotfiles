// Unit tests for the Reports tab (.local/src/agent-web/static/reports.js), run by `node --test`
// from tests/unit/agent_web_queue.bats. The page's real scripts load into one vm context, as the
// browser loads them; only the DOM is a stub. What goes in which section, and that a capture is
// never in the stream, is hub_core::reports, tested in Rust; this checks that the page draws the
// view it is sent, opens what a link names and marks an opened report read once.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);

const el = () => new Proxy({}, {
  get: (t, k) => (k in t ? t[k] : k === "classList" ? { add() {}, remove() {}, toggle() {} } : k === "dataset" ? {} : k === "style" ? {} : (() => el())),
  set: (t, k, v) => { t[k] = v; return true; },
});
const on = {};
const part = () => Object.assign(el(), { innerHTML: "", scrollTop: 0, querySelectorAll: () => [] });
const box = Object.assign(part(), { addEventListener: (ev, f) => { (on[ev] ||= []).push(f); } });
const fire = (ev, e) => (on[ev] || []).forEach((f) => f(e));
const badge = part();
const doc = { getElementById: (id) => (id === "reports" ? box : id === "reports-badge" ? badge : el()), addEventListener() {}, querySelector: el, querySelectorAll: () => [], createElement: el, body: el(), activeElement: null };

const row = (id, state, o = {}) => ({
  id, kind: "report", date: id.slice(0, 10), title: { role: "title", text: `Title ${id}` }, summary: { role: "sub", text: "the lead" }, from: "dotfiles",
  at: "2026-11-24T09:00:00-08:00", state, level: state === "needs you" ? "warn" : "", unread: state === "needs you" || state === "unread",
  target: `journal/refs/${id.slice(0, 10)}/${id.slice(11)}`, link: `#reports/${id}`, ...o,
});
const view = (unread = true) => ({
  today: "2026-11-24",
  tiles: [{ label: "unread", n: unread ? 2 : 1, level: "" }, { label: "needs you", n: 1, level: "warn" }, { label: "today", n: 2, level: "" }, { label: "digests", n: 1, level: "" }],
  sections: [
    { id: "needs", title: "Needs you", folded: false, rows: [row("2026-11-24-ups-switch", "needs you")] },
    { id: "stream", title: "Today", folded: false, rows: [row("2026-11-24-board-cleanup", unread ? "unread" : "read", { unread, from: "" })] },
    { id: "digests", title: "Digests", folded: true, rows: [row("2026-11-24-briefing", "digest", { kind: "digest", from: "" })] },
    { id: "captures", title: "Your notes", folded: true, rows: [] },
  ],
  moved: "1 unread moved to archive",
  archive: [{ date: "2026-11-20", count: "1 report, 1 unread", rows: [row("2026-11-20-old-thing", "unread")] }],
  older_days: 0, unread: unread ? 2 : 1,
});

const asked = [];
const loc = { pathname: "/", hash: "" };
// The fake server keeps the one stamp: after a mark-read, a read answers with it.
const srv = { read: false };
const answer = (url) => {
  if (url === "/api/reports/read") { srv.read = true; return view(false); }
  return url.startsWith("/api/focus") ? { note: {}, sections: [{ title: "", markdown: "Load fell 76% -> 41%" }] } : view(!srv.read);
};
const ctx = vm.createContext({
  console,
  document: doc,
  window: { addEventListener() {} },
  URLSearchParams,
  setInterval: () => 0,
  clearInterval() {},
  location: loc,
  history: { url: "", replaceState(a, b, u) { this.url = u; } },
  fetch: async (url, opts = {}) => {
    asked.push([opts.method || "GET", url, opts.body]);
    // Answered when asked, as a server would, not when the page reads the body.
    const body = answer(url);
    return { ok: true, status: 200, headers: { get: () => "application/json" }, json: async () => body, text: async () => "" };
  },
});
for (const f of ["../../web-kit/kb-ui.js", "ui.js", "md.js", "app.js", "reports.js"]) vm.runInContext(readFileSync(new URL(f, dir), "utf8"), ctx, { filename: f });
const run = (src) => vm.runInContext(src, ctx);
const rps = run("rps");
const open = async (arg) => {
  run(`st.tab = "reports"; st.arg = ${JSON.stringify(arg)}; TABS.reports.show()`);
  await run("refreshReports()");
  // The body read and the mark-read post each settle after the view.
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));
};
const reset = () => { srv.read = false; asked.length = 0; rps.sel = null; rps.body = {}; rps.marked.clear(); rps.open = {}; };

test("Today draws the tiles, Needs you hued, the stream, and Digests folded; Archive is its own group", async () => {
  reset();
  await open("");
  const html = box.innerHTML;
  assert.match(html, /UNREAD/);
  assert.match(html, /<h2 class="sec warn" id="sec-needs">Needs you/);
  assert.match(html, /data-href="#reports\/2026-11-24-ups-switch"/, "a row's link is the server's");
  assert.match(html, /<details class="sec-d" data-k="sec:digests" id="sec-digests">/, "Digests starts shut");
  assert.ok(!/Your notes/.test(html), "an empty folded section is not drawn");
  assert.match(html, /<div data-in="archive" hidden>/, "Archive waits behind its strip button");
  assert.match(html, /1 unread moved to archive/);
  assert.match(html, /<td class="muted rfrom" title="dotfiles">dotfiles<\/td>/, "From is the filer, whole on hover");
  assert.ok(!/>report<\/td>/.test(html), "a report with no filer has a blank From, never its kind");
  assert.match(html, /<td class="muted rfrom" title="digest">digest<\/td>/, "a digest has no filer, so its kind says what it is");
  assert.match(html, /id="sec-day-2026-11-20" data-rec>/, "an Archive day is a record, so the outline skips it");
  assert.equal(badge.innerHTML, `<span class="badge">2</span>`);
  assert.ok(!asked.some(([m]) => m === "POST"), "nothing is marked read before it is opened");
});

test("opening an unread report reads its body and marks it read once, and the badge follows", async () => {
  reset();
  await open("2026-11-24-board-cleanup");
  assert.ok(asked.some(([, u]) => u === "/api/focus?t=journal%2Frefs%2F2026-11-24%2Fboard-cleanup"));
  const posts = asked.filter(([m]) => m === "POST");
  assert.deepEqual(posts.map(([, u, b]) => [u, JSON.parse(b)]), [["/api/reports/read", { id: "2026-11-24-board-cleanup" }]]);
  assert.match(box.innerHTML, /<tr class="wr sel"[^>]*id="sec-r-2026-11-24-board-cleanup"/);
  assert.match(box.innerHTML, /Load fell 76% -&gt; 41%|Load fell 76% -> 41%/);
  assert.equal(badge.innerHTML, `<span class="badge">1</span>`);
  // A re-read never posts again or pulls the reader back.
  asked.length = 0;
  await run("refreshReports()");
  assert.ok(!asked.some(([m]) => m === "POST"));
});

test("a re-read sent before a mark-read never lands over its answer", async () => {
  reset();
  await open("");
  let release;
  const held = new Promise((r) => { release = r; });
  const real = ctx.fetch;
  ctx.fetch = async (url, opts = {}) => {
    if (url === "/api/reports") { await held; ctx.fetch = real; }
    return real(url, opts);
  };
  const stale = run("refreshReports()");
  // The read is held, so the open goes through show() alone (refreshReports would wait on it).
  run(`st.tab = "reports"; st.arg = "2026-11-24-board-cleanup"; TABS.reports.show()`);
  await new Promise((r) => setImmediate(r));
  await new Promise((r) => setImmediate(r));
  assert.equal(badge.innerHTML, `<span class="badge">1</span>`);
  release();
  await stale;
  assert.equal(rps.data.unread, 1, "the older read is dropped");
});

test("a read report opens without a post", async () => {
  reset();
  await open("2026-11-24-ups-switch");
  assert.equal(asked.filter(([m]) => m === "POST").length, 1, "needs you is unread: marked");
  reset();
  run("rps.data.sections[0].rows[0].unread = false");
  run(`st.tab = "reports"; st.arg = "2026-11-24-ups-switch"; TABS.reports.show()`);
  assert.equal(asked.filter(([m]) => m === "POST").length, 0);
});

test("a past day opens its fold on Archive; today's date is Today's top", async () => {
  reset();
  await open("2026-11-20");
  assert.equal(run("st.arg"), "archive");
  assert.equal(rps.open["day:2026-11-20"], true);
  assert.match(box.innerHTML, /<details class="sec-d" data-k="day:2026-11-20" id="sec-day-2026-11-20" open>/);
  reset();
  await open("2026-11-24");
  assert.equal(run("st.arg"), "today");
  assert.equal(rps.sel, null);
});

test("a report that left Today opens on Archive, inside its day", async () => {
  reset();
  await open("2026-11-20-old-thing");
  assert.equal(run("st.arg"), "archive");
  assert.equal(rps.open["day:2026-11-20"], true);
  assert.equal(rps.sel, "2026-11-20-old-thing");
});

test("a click opens a row through its link; a click on the open row shuts it", async () => {
  reset();
  await open("");
  const tr = (cls, href) => ({ classList: { contains: (c) => cls.includes(c) }, dataset: { href } });
  const target = (t) => ({ target: { closest: (sel) => (sel === "tr.wr" ? t : null) } });
  fire("click", target(tr(["wr"], "#reports/2026-11-24-ups-switch")));
  assert.equal(loc.hash, "#reports/2026-11-24-ups-switch");
  rps.sel = "2026-11-24-ups-switch";
  fire("click", target(tr(["wr", "sel"], "#reports/2026-11-24-ups-switch")));
  assert.equal(rps.sel, null);
});
