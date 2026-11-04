"use strict";
// The Shepherd tab: every rundown and chat answer the shepherd kept (`fleet-shepherd log
// --rundown`, one file each in ~/.agent/shepherd/rundowns), beside a chat with the live
// shepherd session. The chat is that session's transcript, text only, and a box that types into
// its pane through /api/send, so an answer it gives here is also kept as a rundown. Above the
// rundowns, what Binks owes: each line the last `fleet-shepherd check` handed to a pass (its role,
// how long it has been due, and whether the last pass left it unhandled). The lines a pass
// skipped on purpose, with why, are the shepherd's skips in the Actions tab.

// Transcript events read for the chat. Tool calls are dropped, so a page of them holds few lines.
const SHEP_EVENTS = 300;
const shst = { data: null, err: null, chat: null, chatErr: null, open: new Set(), msg: "" };

const refreshShepherd = coalesce(async () => {
  try { shst.data = await api("/api/shepherd"); shst.err = null; } catch (e) { shst.err = e.message; }
  if (shst.data && shst.data.rundowns.length && !shst.open.size) shst.open.add(shst.data.rundowns[0].file);
  if (st.tab === "shepherd") { renderShepherd(); refreshShepChat(); }
});

const refreshShepChat = coalesce(async () => {
  const t = shst.data && shst.data.target;
  if (!t) { shst.chat = null; renderShepChat(); return; }
  try {
    const page = await api(`/api/transcript?t=${encodeURIComponent(t)}&limit=${SHEP_EVENTS}`);
    shst.chat = page.events.filter((e) => e.kind !== "tool_use" && e.kind !== "tool_result" && e.text.trim());
    shst.chatErr = null;
  } catch (e) { shst.chatErr = e.message; }
  if (st.tab === "shepherd") renderShepChat();
});

// A stamp as the reader's local time; the file keeps UTC.
function shepWhen(stamp) {
  const d = new Date(stamp.replace(" UTC", "Z").replace(" ", "T"));
  return isNaN(d) ? esc(stamp) : esc(d.toLocaleString([], { weekday: "short", month: "short", day: "numeric", hour: "2-digit", minute: "2-digit" }));
}

function rundownCard(r) {
  const open = shst.open.has(r.file) ? " open" : "";
  return `<details class="card rd"${open} data-file="${esc(r.file)}"><summary><b>${esc(r.title)}</b>` +
    ` <span class="muted">${shepWhen(r.stamp)}</span></summary><div class="rd-body md">${md(r.body)}</div></details>`;
}

// Minutes since an epoch in seconds, as "12m"; "-" when the ledger does not say.
const shepAge = (t) => (t ? dur((Date.now() / 1e3 - t) / 60) : "-");

function dueRow(d) {
  const flag = d.unhandled ? `<span class="pill ask">unhandled</span>` : "";
  return `<div class="card"><div class="pills">${flag}<span class="pill">${esc(d.role || "?")}</span>` +
    `<span class="pill">due ${shepAge(d.first_seen)}</span></div><div class="rd-body">${esc(d.line)}</div></div>`;
}

function dueHtml(l) {
  const pass = l.lease_at ? `last pass ${shepAge(l.lease_at)} ago (${esc(l.lease_holder)})` : "no pass yet";
  const owed = l.due.length ? l.due.map(dueRow).join("")
    : `<div class="empty">Nothing due: the last check found nothing to move.</div>`;
  const skips = `<div class="row-end"><button class="btn" data-skips>Skipped on purpose, in Actions</button></div>`;
  return `<h2 class="sec">Due <span class="muted">${l.due.length}, ${pass}</span></h2>${owed}${skips}`;
}

function renderShepherd() {
  const el = $("shepherd");
  if (!el.querySelector(".shep")) {
    el.innerHTML = `<div class="shep"><div class="shep-col"><div id="sh-due"></div><h2 class="sec">Rundowns <span class="muted" id="sh-count"></span></h2>` +
      `<div id="sh-list"></div></div><div class="shep-col shep-chat"><h2 class="sec">Chat <span class="muted" id="sh-who"></span></h2>` +
      `<div id="sh-chat" class="card"></div><div class="card"><textarea id="sh-text" placeholder="Ask the shepherd (Ctrl+Enter to send)"></textarea>` +
      `<div class="row-end"><span class="err" id="sh-err"></span><button class="btn primary" id="sh-send">Send</button></div></div></div></div>`;
  }
  const d = shst.data;
  const list = d ? d.rundowns : [];
  $("sh-due").innerHTML = d ? dueHtml(d.ledger) : "";
  $("sh-count").textContent = list.length ? `${list.length} newest` : "";
  $("sh-list").innerHTML = shst.err ? `<div class="card err">${esc(shst.err)}</div>`
    : !d ? `<div class="empty">Loading.</div>`
    : list.length ? list.map(rundownCard).join("")
    : `<div class="empty">No rundowns kept yet. The shepherd writes one with <code>fleet-shepherd log --rundown</code> each time it sums up the fleet or answers you here.</div>`;
  $("sh-who").textContent = d && d.target ? `${d.target} (${d.status})` : "";
  $("sh-text").disabled = $("sh-send").disabled = !(d && d.target);
  $("sh-err").textContent = shst.msg;
}

function renderShepChat() {
  const el = $("sh-chat");
  if (!el) return;
  const d = shst.data;
  if (!d || !d.target) { el.innerHTML = `<div class="empty">No shepherd armed. Its lease is set when fleet-shepherd starts a pass.</div>`; return; }
  if (shst.chatErr) { el.innerHTML = `<div class="err">${esc(shst.chatErr)}</div>`; return; }
  if (!shst.chat) { el.innerHTML = `<div class="empty">Loading.</div>`; return; }
  const stick = atBottom(el);
  el.innerHTML = shst.chat.length ? shst.chat.map(evHtml).join("") : `<div class="empty">Nothing said yet.</div>`;
  if (stick) toBottom(el);
}

async function shepSend() {
  const d = shst.data, text = $("sh-text").value;
  if (!d || !d.target || !text.trim()) return;
  $("sh-send").disabled = true;
  try { await post("/api/send", { t: d.target, text }); $("sh-text").value = ""; shst.msg = ""; }
  catch (e) { shst.msg = e.message; }
  $("sh-send").disabled = false;
  $("sh-err").textContent = shst.msg;
}

$("shepherd").addEventListener("click", (e) => {
  if (e.target.id === "sh-send") shepSend();
  else if (e.target.dataset.skips !== undefined) showActions("shepherd", "skip");
});
$("shepherd").addEventListener("keydown", (e) => {
  if (e.target.id === "sh-text" && e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); shepSend(); }
});
// Remember which rundowns are open, so a re-render after a new one keeps the reader's place.
$("shepherd").addEventListener("toggle", (e) => {
  const f = e.target.dataset && e.target.dataset.file;
  if (f) { if (e.target.open) shst.open.add(f); else shst.open.delete(f); }
}, true);

TABS.shepherd = {
  show() { renderShepherd(); refreshShepherd(); },
  onEvent(ev) {
    if (st.tab !== "shepherd") return; // show() reads it all fresh
    if (ev.kind === "shepherd" || ev.kind === "sessions" || ev.kind === "resync") refreshShepherd();
    else if (ev.kind === "transcript" && shst.data && ev.session === shst.data.session) refreshShepChat();
  },
};
