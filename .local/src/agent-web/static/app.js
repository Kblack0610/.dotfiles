"use strict";
// The Sessions tab, the tab switch and the live-update stream. Shared helpers are in ui.js; the
// answer cards are waiting.js, Home is home.js, and each board tab is its own static/*.js and
// registers in TABS.
const KEYS = [["1","1"],["2","2"],["3","3"],["Enter","Enter"],["Esc","Escape"],["Up","Up"],["Down","Down"],["Tab","Tab"],["S-Tab","BTab"]];

const st = { agents: [], sel: null, view: "transcript", start: null, end: null, tab: "home", asks: [] };
// The board tabs (static/*.js) register here: { show(), onEvent(ev) }.
const TABS = {};

const refreshAgents = coalesce(async () => {
  st.agents = await api("/api/agents");
  renderList();
  renderBadge();
  if (st.tab === "home") renderHome();
  // A session coming or going changes which queue rows have an Open button.
  if (st.tab === "queue") renderQueueList();
  if (st.sel) {
    const a = st.agents.find((x) => x.target === st.sel.target);
    if (a) { st.sel = a; renderHead(); } else { $("d-dot").className = "dot"; $("d-name").textContent = st.sel.target + " (gone)"; }
  }
});

function renderList() {
  const waiting = st.agents.filter((a) => a.status === "waiting").length;
  $("wait-badge").innerHTML = waiting ? `<span class="badge">${waiting}</span>` : "";
  if (!st.agents.length) { $("list").innerHTML = '<div class="empty">No agents running.</div>'; return; }
  const groups = new Map();
  for (const a of st.agents) { if (!groups.has(a.project)) groups.set(a.project, []); groups.get(a.project).push(a); }
  let html = "";
  for (const [proj, list] of groups) {
    html += `<div class="group">${esc(proj)}</div>`;
    for (const a of list) {
      const sel = st.sel && st.sel.target === a.target ? " sel" : "";
      html += `<div class="row${sel}" data-t="${esc(a.target)}"><span class="dot ${esc(a.status)}"></span><div style="min-width:0"><div class="t">${esc(a.target)}</div><div class="s">${esc(a.summary || "")}</div>${pills(a)}</div></div>`;
    }
  }
  $("list").innerHTML = html;
}

// What the row is beyond its status: the human's own session, parked, its account, plan, ask.
function pills(a) {
  const p = [];
  if (a.attached) p.push('<span class="pill here">you are here</span>');
  if (a.parked) p.push('<span class="pill parked">parked</span>');
  if (a.account) p.push(`<span class="pill" title="account">${esc(a.account)}</span>`);
  if (a.plan) p.push(`<span class="pill" title="plan">${esc(a.plan)}</span>`);
  if (a.phases) p.push(`<span class="pill phases" title="plan phases">${esc(phasesText(a))}</span>`);
  if (a.ask) p.push(`<span class="pill ask" title="pending ask">ask ${esc(a.ask)}</span>`);
  return p.length ? `<div class="pills">${p.join("")}</div>` : "";
}

// "3/6 phases, next: <name>", from fleet-sessions' read of the plan's ## Phases checklist.
function phasesText(a) {
  const p = a.phases;
  return p ? `${p.done}/${p.total} phases${p.next ? `, next: ${p.next}` : ""}` : "";
}

// Approve a session's open plan dialog (session action approve-plan) from a Waiting card or a
// Queue row: the first click arms an in-place confirm, the second sends it.
st.approving = null;
function approveButtons(a) {
  if (!a || !(a.actions || []).includes("approve-plan")) return "";
  const t = esc(a.target);
  return st.approving === a.target
    ? `<button class="btn sm primary" data-approve-go="${t}">Yes, approve the plan</button><button class="btn sm" data-approve-no>Cancel</button>`
    : `<button class="btn sm primary" data-approve="${t}">Approve plan</button>`;
}
function rerenderApprove() {
  if (st.tab === "home") renderHome();
  if (st.tab === "queue") renderQueueList();
}
document.addEventListener("click", async (e) => {
  const b = e.target.closest("[data-approve],[data-approve-go],[data-approve-no]");
  if (!b) return;
  e.stopPropagation();
  if (b.dataset.approve) { st.approving = b.dataset.approve; rerenderApprove(); return; }
  const t = b.dataset.approveGo;
  st.approving = null;
  if (!t) { rerenderApprove(); return; }
  const err = b.closest(".card") && b.closest(".card").querySelector(".err");
  try { await post(`/api/session/${encodeURIComponent(t)}/approve-plan`, {}); if (err) err.textContent = ""; }
  catch (x) { if (err) err.textContent = x.message; }
  refreshAgents();
}, true);

// Session actions (hub-core session_actions on the server). A button only arms a confirm
// here in the page; the confirm's own button sends it. Parked rows offer only unpark.
const DANGER = ["stop", "cancel"];
// The button for each session action (hub-core session_actions.rs names); an unknown one shows its name.
const ACT_LABEL = { interrupt: "Interrupt", park: "Park session", unpark: "Unpark session", move: "Move to account",
  stop: "Stop session", cancel: "Cancel task", "approve-plan": "Approve plan" };
const actLabel = (n) => ACT_LABEL[n] || n;
st.act = { confirm: null, busy: false, msg: "", err: false };
st.opts = { describe: {}, accounts: [] };
api("/api/session-options").then((o) => { st.opts = o; if (st.sel) renderActs(); }).catch((e) => console.warn(e));

function renderActs() {
  const a = st.sel, box = $("acts");
  if (!a) { box.hidden = true; return; }
  box.hidden = false;
  const c = st.act.confirm && st.act.confirm.target === a.target ? st.act.confirm : null;
  let html = "";
  if (c) {
    const others = st.opts.accounts.filter((n) => n !== a.account);
    const pick = c.action === "move"
      ? `<select id="act-acct">${others.map((n) => `<option>${esc(n)}</option>`).join("")}</select>` : "";
    const danger = DANGER.includes(c.action) ? " danger" : "";
    html += `<span class="q">${esc(actLabel(c.action))}? This will ${esc(st.opts.describe[c.action] || "")}.${a.attached ? " You are attached to it." : ""} (${esc(a.target)})</span>${pick}`
      + (c.action === "approve-plan" && a.question && a.question.kind === "plan"
        ? `<div class="planpeek md">${md(a.question.text.split("\n").filter((l) => l.trim()).slice(0, 6).join("\n"))}</div>` : "")
      + `<button class="btn primary${danger}" data-go ${st.act.busy || (c.action === "move" && !others.length) ? "disabled" : ""}>Yes, ${esc(actLabel(c.action).toLowerCase())}</button>`
      + `<button class="btn" data-no ${st.act.busy ? "disabled" : ""}>Cancel</button>`;
  } else {
    html += (a.actions || []).map((n) => `<button class="btn${DANGER.includes(n) ? " danger" : ""}" data-act="${esc(n)}" ${st.act.busy ? "disabled" : ""}>${esc(actLabel(n))}</button>`).join("");
  }
  if (st.act.msg) html += `<div class="msg${st.act.err ? " err" : ""}">${esc(st.act.msg)}</div>`;
  box.innerHTML = html;
}

$("acts").addEventListener("click", async (e) => {
  const a = st.sel;
  if (!a || st.act.busy) return;
  const b = e.target.closest("button");
  if (!b) return;
  if (b.dataset.act) { st.act.confirm = { action: b.dataset.act, target: a.target }; st.act.msg = ""; renderActs(); return; }
  if (b.dataset.no !== undefined) { st.act.confirm = null; renderActs(); return; }
  if (b.dataset.go === undefined || !st.act.confirm) return;
  const { action, target } = st.act.confirm;
  const account = action === "move" && $("act-acct") ? $("act-acct").value : "";
  st.act = { confirm: null, busy: true, msg: `${actLabel(action)}: running... (${target})`, err: false };
  renderActs();
  try {
    const r = await post(`/api/session/${encodeURIComponent(target)}/${encodeURIComponent(action)}`, { account });
    st.act.msg = `${actLabel(action)}: done (${target})${r && r.output ? "\n" + r.output : ""}`;
  } catch (err) {
    st.act.msg = `${actLabel(action)} failed (${target}). ${err.message}`; st.act.err = true;
  }
  st.act.busy = false;
  refreshAgents();
  renderActs();
});

$("list").addEventListener("click", (e) => {
  const row = e.target.closest(".row");
  if (!row) return;
  const a = st.agents.find((x) => x.target === row.dataset.t);
  if (a) select(a);
});

function renderHead() {
  $("d-dot").className = "dot " + st.sel.status;
  $("d-name").textContent = `${st.sel.target}  ${st.sel.summary || ""}`;
  // A parked session has no claude to type into or screen to show: only its transcript.
  $("compose").hidden = !!st.sel.parked;
  $("v-screen").disabled = !!st.sel.parked;
  renderActs();
}

function select(a) {
  if (!st.sel || st.sel.target !== a.target) st.act = { confirm: null, busy: st.act.busy, msg: "", err: false };
  st.sel = a; st.start = null; st.end = null;
  if (a.parked && st.view === "screen") {
    st.view = "transcript";
    $("v-transcript").classList.add("on");
    $("v-screen").classList.remove("on");
  }
  $("main").classList.add("open");
  $("err").textContent = "";
  renderHead(); renderList();
  $("scroll").innerHTML = "";
  load();
}

$("back").onclick = () => { $("main").classList.remove("open"); };

function evHtml(e) {
  const ts = e.ts ? `<div class="ts">${esc(e.ts.replace("T", " ").slice(0, 19))}</div>` : "";
  if (e.kind === "tool_use") return `<div class="ev tool"><b>${esc(e.name || "tool")}</b> ${esc(e.text)}</div>`;
  if (e.kind === "tool_result") {
    const first = e.text.split("\n")[0].slice(0, 120);
    return `<div class="ev"><details><summary>result: ${esc(first)}</summary><pre>${esc(e.text)}</pre></details></div>`;
  }
  // What the human typed is shown as typed; what an agent wrote is markdown.
  return e.role === "user" ? `<div class="ev user">${ts}${esc(e.text)}</div>` : `<div class="ev md">${ts}${md(e.text)}</div>`;
}

async function load() {
  if (st.view === "screen") return loadScreen();
  const a = st.sel;
  let page;
  try { page = await api(`/api/transcript?t=${encodeURIComponent(a.target)}`); }
  catch (e) { $("scroll").innerHTML = `<div class="empty">${esc(e.message)}</div>`; return; }
  if (st.sel !== a) return;
  st.start = page.start; st.end = page.end;
  $("scroll").innerHTML = olderBtn() + page.events.map(evHtml).join("");
  toBottom($("scroll"));
}

const olderBtn = () => st.start > 0 ? '<button class="btn older" id="older">Load older</button>' : "";

$("scroll").addEventListener("click", async (e) => {
  if (e.target.id !== "older") return;
  const a = st.sel, s = $("scroll"), btn = e.target;
  let page;
  btn.disabled = true;
  try { page = await api(`/api/transcript?t=${encodeURIComponent(a.target)}&before=${st.start}`); }
  catch (err) { btn.disabled = false; btn.textContent = `Load older (${err.message})`; return; }
  if (st.sel !== a) return;
  const prevH = s.scrollHeight;
  btn.remove();
  st.start = page.start;
  s.insertAdjacentHTML("afterbegin", olderBtn() + page.events.map(evHtml).join(""));
  s.scrollTop += s.scrollHeight - prevH; // keep the reader where they were
});

const loadNewer = coalesce(async () => {
  const a = st.sel;
  if (!a || st.view !== "transcript" || st.end === null) return;
  const stick = atBottom($("scroll"));
  const page = await api(`/api/transcript?t=${encodeURIComponent(a.target)}&after=${st.end}`);
  if (st.sel !== a) return;
  if (page.start !== st.end) { load(); return; } // fell too far behind: server sent the newest page
  st.end = page.end;
  if (page.events.length) {
    $("scroll").insertAdjacentHTML("beforeend", page.events.map(evHtml).join(""));
    if (stick) toBottom($("scroll"));
  }
});

const loadScreen = coalesce(async () => {
  const a = st.sel;
  if (!a || st.view !== "screen") return;
  const text = await api(`/api/screen?t=${encodeURIComponent(a.target)}`);
  if (st.sel !== a) return;
  $("scroll").innerHTML = `<pre id="screen">${esc(String(text).replace(/\s+$/, ""))}</pre>`;
  toBottom($("scroll"));
});

function setView(v) {
  st.view = v;
  $("v-transcript").classList.toggle("on", v === "transcript");
  $("v-screen").classList.toggle("on", v === "screen");
  if (st.sel) load();
}
$("v-transcript").onclick = () => setView("transcript");
$("v-screen").onclick = () => setView("screen");

$("keys").innerHTML = KEYS.map(([label, key]) => `<button data-k="${key}">${label}</button>`).join("");
$("keys").addEventListener("click", async (e) => {
  const k = e.target.dataset && e.target.dataset.k;
  if (!k || !st.sel) return;
  try { await post("/api/send", { t: st.sel.target, key: k }); $("err").textContent = ""; if (st.view === "screen") loadScreen(); }
  catch (err) { $("err").textContent = err.message; }
});

async function sendText() {
  const text = $("text").value;
  if (!text.trim() || !st.sel) return;
  $("send").disabled = true;
  try { await post("/api/send", { t: st.sel.target, text }); $("text").value = ""; $("err").textContent = ""; }
  catch (err) { $("err").textContent = err.message; }
  $("send").disabled = false;
}
$("send").onclick = sendText;
$("text").addEventListener("keydown", (e) => { if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) { e.preventDefault(); sendText(); } });

// hub_core::layout's landed tabs lead, in its order, then the older tabs until their phase
// lands (docs/dashboards.md "Hub layout"); agent-web's tab_names_lead_with_the_landed_layout
// test fails when this drifts. RETIRED_TABS is layout::RETIRED: an old `#name` still lands.
const TAB_NAMES = ["home", "queue", "projects", "sessions", "shepherd", "actions", "watch", "log", "infra", "jobs", "fleet"];
const RETIRED_TABS = { "waiting": "home", "asks": "home", "board": "projects" };
const tabOf = (name) => (TAB_NAMES.includes(name) ? name : RETIRED_TABS[name] || "home");
function setTab(t) {
  st.tab = t;
  for (const n of TAB_NAMES) {
    $("tab-" + n).classList.toggle("on", t === n);
    if (n !== "sessions") $(n).hidden = t !== n;
  }
  $("list").hidden = t !== "sessions";
  $("detail").hidden = t !== "sessions";
  if (TABS[t]) TABS[t].show();
  try { history.replaceState(null, "", t === "home" ? location.pathname : "#" + t); } catch (e) { /* not fatal */ }
}
for (const n of TAB_NAMES) $("tab-" + n).onclick = () => setTab(n);

function showLive(ev) {
  // The server could not watch some paths (the user's inotify limit, usually); it retries.
  const off = ev.off || [];
  $("conn").classList.toggle("off", off.length > 0);
  $("conn").title = off.length ? "live updates off for " + off.join(", ") : "live updates";
  $("live-off").hidden = off.length === 0;
  $("live-off").title = off.join("\n");
}

function dispatch(ev) {
  if (ev.kind === "sessions" || ev.kind === "resync") { refreshAgents(); if (st.view === "screen") loadScreen(); }
  if (ev.kind === "asks" || ev.kind === "resync") refreshAsks();
  if ((ev.kind === "transcript" && st.sel && ev.session === st.sel.session) || ev.kind === "resync") {
    if (st.view === "screen") loadScreen(); else loadNewer();
  }
  for (const t of Object.values(TABS)) t.onEvent(ev);
}

// A page in a background browser tab reads nothing: events (and poll ticks, ui.js) that arrive
// while it is hidden only mark it behind, and coming back into view replays them as one resync.
// A dashboard left open all day then costs the server nothing until someone looks at it.
let behind = false;
document.addEventListener("visibilitychange", () => {
  if (document.hidden || !behind) return;
  behind = false;
  dispatch({ kind: "resync" });
});

function connect() {
  const es = new EventSource("/api/events");
  es.onopen = () => { $("conn").classList.add("live"); refreshAgents(); refreshAsks(); if (st.sel) load(); };
  es.onerror = () => { $("conn").classList.remove("live"); }; // EventSource reconnects by itself
  es.onmessage = (m) => {
    const ev = JSON.parse(m.data);
    if (ev.kind === "live") { showLive(ev); return; }
    if (document.hidden) { behind = true; return; }
    dispatch(ev);
  };
}

// Every script has run by now (they sit at the end of <body>), so every tab is registered.
document.addEventListener("DOMContentLoaded", () => {
  setTab(tabOf(location.hash.slice(1)));
  connect();
});
