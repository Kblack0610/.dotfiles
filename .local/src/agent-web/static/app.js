"use strict";
// The open session, the tab switch and the live-update stream. Shared helpers are in ui.js; the
// answer cards are waiting.js, Home is home.js, and each board tab is its own static/*.js and
// registers in TABS. Sessions' table and header are sessions.js, its fleet-state facts and the
// last day are watch.js, the shepherd's pass, due lines and rundowns are shepherd.js. An open
// session starts on its page (sessions.js); its transcript is read only when asked for.
const KEYS = [["1","1"],["2","2"],["3","3"],["Enter","Enter"],["Esc","Escape"],["Up","Up"],["Down","Down"],["Tab","Tab"],["S-Tab","BTab"]];

const st = { agents: [], sel: null, view: "page", start: null, end: null, tab: "home", asks: [], views: {} };
// The board tabs (static/*.js) register here: { show(), onEvent(ev) }.
const TABS = {};
// Log's folded sections under the day (Actions, Changes, Rundowns, the judges' verdicts): the
// file that owns each one's data adds {show, onEvent} here and paints its own container.
const LOG_PARTS = [];

const refreshAgents = coalesce(async () => {
  st.agents = await api("/api/agents");
  const waiting = st.agents.filter((a) => a.status === "waiting").length;
  $("wait-badge").innerHTML = waiting ? `<span class="badge">${waiting}</span>` : "";
  renderBadge();
  renderOverview();
  if (st.tab === "home") renderHome();
  // A session coming or going changes which queue rows have an Open button.
  if (st.tab === "queue") renderQueueList();
  if (st.sel) {
    const a = st.agents.find((x) => x.target === st.sel.target);
    if (a) { st.sel = a; renderHead(); }
    else if (!st.sel.paneless) { $("d-dot").className = "dot"; $("d-name").textContent = st.sel.target + " (gone)"; }
  }
});

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

function renderHead() {
  $("v-seg").hidden = $("d-dot").hidden = false;
  $("d-dot").className = "dot " + st.sel.status;
  $("d-name").textContent = `${st.sel.name || st.sel.target}  ${st.sel.summary || ""}`;
  // A parked session has no claude to type into or screen to show: only its transcript.
  const noPane = !!(st.sel.parked || st.sel.paneless);
  $("compose").hidden = noPane;
  $("v-screen").disabled = noPane;
  renderActs();
}

function select(a) {
  if (!st.sel || st.sel.target !== a.target) st.act = { confirm: null, busy: st.act.busy, msg: "", err: false };
  st.sel = a; st.start = null; st.end = null;
  showView("page");
  $("main").classList.add("open");
  $("err").textContent = "";
  renderHead(); renderFacts();
  $("scroll").innerHTML = "";
  load();
}

// No session open: the page is the table (sessions.js) and the folds under it.
function overview() {
  st.sel = null; st.start = null; st.end = null;
  $("d-dot").hidden = $("v-seg").hidden = true;
  $("d-name").textContent = "Sessions";
  $("acts").hidden = true;
  $("compose").hidden = true;
  $("main").classList.remove("open");
  $("scroll").innerHTML = "";
  renderFacts(); renderOverview(); refreshSessions();
}

$("back").onclick = () => setTab("sessions", "");

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
  if (st.view === "page") return loadPage();
  if (st.view === "screen") return loadScreen();
  const a = st.sel, still = () => st.sel === a && st.view === "transcript";
  let page;
  try { page = await api(`/api/transcript?t=${encodeURIComponent(a.target)}`); }
  catch (e) { if (still()) $("scroll").innerHTML = `<div class="empty">${esc(e.message)}</div>`; return; }
  if (!still()) return;
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

function showView(v) {
  st.view = v;
  for (const n of ["page", "transcript", "screen"]) $("v-" + n).classList.toggle("on", v === n);
}
function setView(v) {
  showView(v);
  if (st.sel) { renderFacts(); load(); }
}
$("v-page").onclick = () => setView("page");
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

// hub_core::layout's tabs, in its order (docs/dashboards.md "Hub layout"); agent-web's
// tab_names_are_the_layout test fails when this drifts. RETIRED_TABS is layout::RETIRED: an old `#name` still lands.
const TAB_NAMES = ["home", "daily", "queue", "projects", "sessions", "infra", "log", "fleet"];
const RETIRED_TABS = { "waiting": "home", "asks": "home", "board": "projects", "watch": "sessions", "shepherd": "sessions", "jobs": "infra", "ci": "infra", "machines": "infra", "today": "log", "history": "log", "actions": "log", "outbox": "daily", "focus": "daily" };
const tabOf = (name) => (TAB_NAMES.includes(name) ? name : RETIRED_TABS[name] || TAB_NAMES[0]);
// A retired name that is now a section of its tab (`#jobs` is Infra's Jobs section) scrolls
// there once that section has drawn (hub_core::layout::section). Each board calls this after
// it paints; the first paint that has the section clears it.
function seekSection() {
  const e = st.section && $("sec-" + st.section);
  if (!e) return;
  st.section = null;
  if (e.tagName === "DETAILS") e.open = true;
  if (e.scrollIntoView) e.scrollIntoView({ block: "start" });
}
// A URL fragment is `#tab` or `#tab/arg`: the arg is the note a Daily link opens
// (`#daily/status/inbox`) or the project a `#p:` link opens (`#projects/notes-cockpit`).
// The retired `#outbox` is Daily's outbox (`#daily/outbox`); `#focus/<note>` is `#daily/<note>`.
// After a `?` is the tab's own view state, so a view can be linked (`#fleet?lane=deliver&s=failed`).
function route(hash) {
  const [h, query = ""] = String(hash || "").replace(/^#/, "").split(/\?(.*)/s);
  const at = h.indexOf("/");
  const name = at < 0 ? h : h.slice(0, at);
  let arg = at < 0 ? "" : h.slice(at + 1);
  try { arg = decodeURIComponent(arg); } catch (e) { /* keep it as typed */ }
  if (name === "outbox" && !arg) arg = "outbox";
  return { name, tab: tabOf(name), arg, query };
}
// Show tab t; arg is what it opens (blank for its front), query its view state, which a tab
// button leaves as it was. A tab button replaces the URL, so tab hopping makes no history; an
// in-app link (`href="#daily/status/inbox"`) pushes one, so Back returns.
function setTab(t, arg, query) {
  st.tab = t;
  st.arg = arg || "";
  st.views[t] = query ?? st.views[t] ?? "";
  for (const n of TAB_NAMES) {
    $("tab-" + n).classList.toggle("on", t === n);
    if (n !== "sessions") $(n).hidden = t !== n;
  }
  $("cur-tab").textContent = $("tab-" + t).firstChild.textContent;
  menuOpen(false);
  $("detail").hidden = t !== "sessions";
  if (TABS[t]) TABS[t].show();
  showUrl();
}
function showUrl() {
  const t = st.tab, q = st.views[t];
  const frag = (st.arg ? "#" + t + "/" + st.arg.split("/").map(encodeURIComponent).join("/") : "#" + t) + (q ? "?" + q : "");
  try { history.replaceState(null, "", t === TAB_NAMES[0] && !st.arg && !q ? location.pathname : frag); } catch (e) { /* not fatal */ }
}
// The open tab's view state changed: the URL follows it without a history entry.
function setQuery(q) {
  st.views[st.tab] = q;
  showUrl();
}
for (const n of TAB_NAMES) $("tab-" + n).onclick = () => setTab(n);

// Under 760px the tabs fold behind the menu button (app.css); a pick, Escape or a tap outside
// closes it. The button carries the Needs you count, so a closed menu still says something waits.
function menuOpen(on) {
  $("top").classList.toggle("open", on);
  $("menu").setAttribute("aria-expanded", on ? "true" : "false");
}
$("menu").onclick = (e) => { e.stopPropagation(); menuOpen(!$("top").classList.contains("open")); };
document.addEventListener("click", (e) => { if (!e.target.closest || !e.target.closest("#top")) menuOpen(false); });
document.addEventListener("keydown", (e) => { if (e.key === "Escape") menuOpen(false); });

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

// Back and Forward, and every in-app link, change the fragment; show what it names.
window.addEventListener("hashchange", () => {
  const r = route(location.hash);
  if (r.tab !== st.tab || r.arg !== st.arg || r.query !== (st.views[r.tab] ?? "")) setTab(r.tab, r.arg, r.query);
});

// Every script has run by now (they sit at the end of <body>), so every tab is registered.
document.addEventListener("DOMContentLoaded", () => {
  const r = route(location.hash);
  if (RETIRED_TABS[r.name]) st.section = r.name;
  setTab(r.tab, r.arg, r.query);
  connect();
});
