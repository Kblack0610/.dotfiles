"use strict";
// The open session, the tab switch and the live-update stream. Shared helpers are in ui.js; the
// answer cards are waiting.js, Home is home.js, and each board tab is its own static/*.js and
// registers in TABS. Sessions' table and header are sessions.js, its fleet-state facts and the
// last day are watch.js, the shepherd's pass, due lines and rundowns are shepherd.js. An open
// session starts on its conversation; its Details page (sessions.js) is read only when asked for.
const KEYS = [["1","1"],["2","2"],["3","3"],["Enter","Enter"],["Esc","Escape"],["Up","Up"],["Down","Down"],["Tab","Tab"],["S-Tab","BTab"]];

const st = { agents: [], sel: null, view: "transcript", start: null, end: null, tab: "home", asks: [], views: {} };
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
  sst.render();
  if (st.tab === "home") renderHome();
  // A session coming or going changes which queue rows have an Open button.
  if (st.tab === "queue") qst.render();
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
  if (st.tab === "queue") qst.render();
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
  renderPin();
}

// A waiting session's open question, pinned under its conversation and answered in place: the
// same card Home draws (waiting.js sessionCard), less its Open button.
function renderPin() {
  const el = $("ask-pin"), a = st.sel;
  const on = !!(a && a.question && st.view === "transcript");
  el.hidden = !on;
  if (!on) { el.innerHTML = ""; return; }
  const key = a.target + "|" + a.question.kind + "|" + a.question.text;
  if (el.dataset.key === key) return; // a refresh must not take a half-typed reply
  el.dataset.key = key;
  // The row kind hub-core's home::NeedKind::of_dialog gives the same dialog.
  el.innerHTML = sessionCard(a, { choice: "ask", tool: "perm", plan: "plan" }[a.question.kind] || "turn", true);
}
$("ask-pin").addEventListener("click", (e) => { const c = e.target.closest(".card"); if (c) answerCard(c, e); });
$("ask-pin").addEventListener("keydown", (e) => answerOnEnter(e));

function select(a) {
  if (!st.sel || st.sel.target !== a.target) st.act = { confirm: null, busy: st.act.busy, msg: "", err: false };
  st.sel = a; st.start = null; st.end = null;
  showView("transcript");
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
  renderPin();
  $("main").classList.remove("open");
  $("scroll").innerHTML = "";
  renderFacts(); sst.render(); renderSide(); refreshSessions();
}

$("back").onclick = () => setTab("sessions", "");

// The conversation: #scroll holds the older sentinel and #convo (convo.js draws into it).
async function load() {
  if (st.view === "page") return loadPage();
  if (st.view === "screen") return loadScreen();
  const a = st.sel, still = () => st.sel === a && st.view === "transcript";
  let page;
  try { page = await api(`/api/transcript?t=${encodeURIComponent(a.target)}`); }
  catch (e) { if (still()) $("scroll").innerHTML = `<div class="empty">${esc(e.message)}</div>`; return; }
  if (!still()) return;
  st.start = page.start; st.end = page.end;
  convoReset();
  $("scroll").innerHTML = olderHtml() + `<div id="convo">${convoHtml(page.events)}</div>`;
  // The newest step group is what the agent is doing now, so it starts open.
  const groups = $("convo").querySelectorAll("details.steps"), last = groups[groups.length - 1];
  if (last && last === $("convo").lastElementChild) last.open = true;
  watchOlder();
  toBottom($("scroll"));
  jumpShow(false);
}

// The top of the conversation: a sentinel that reads the page before when it scrolls into
// view, and is a button too, for a retry after a failed read.
const olderHtml = () => st.start > 0 ? '<button class="btn older" id="older">Older</button>' : "";

const olderSeen = typeof IntersectionObserver === "undefined" ? null
  : new IntersectionObserver((es) => { if (es.some((x) => x.isIntersecting)) loadOlder(); }, { root: $("scroll"), rootMargin: "600px 0px 0px 0px" });
function watchOlder() {
  if (!olderSeen) return;
  olderSeen.disconnect();
  const b = $("older");
  if (b) olderSeen.observe(b);
}

const loadOlder = coalesce(async () => {
  const a = st.sel, s = $("scroll"), btn = $("older");
  if (!a || !btn || st.view !== "transcript" || btn.disabled) return;
  let page;
  btn.disabled = true; btn.textContent = "Reading older";
  try { page = await api(`/api/transcript?t=${encodeURIComponent(a.target)}&before=${st.start}`); }
  catch (err) { btn.disabled = false; btn.textContent = `Older (${err.message}), tap to retry`; return; }
  if (st.sel !== a || st.view !== "transcript") return;
  const prevH = s.scrollHeight;
  st.start = page.start;
  $("convo").insertAdjacentHTML("afterbegin", convoHtml(page.events));
  if (st.start > 0) { btn.disabled = false; btn.textContent = "Older"; } else btn.remove();
  s.scrollTop += s.scrollHeight - prevH; // keep the reader where they were
  watchOlder();
});

$("scroll").addEventListener("click", (e) => {
  if (!st.sel || st.view !== "transcript") return;
  if (e.target.id === "older") { loadOlder(); return; }
  const step = e.target.closest("[data-step]");
  if (step) convoStep(step);
});

// "Jump to latest": shown while the reader is above the bottom and something new arrived.
// It floats just above the bottom of the conversation, whatever the pin and composer take.
function jumpShow(on) {
  const j = $("jump");
  j.hidden = !on;
  if (on) j.style.bottom = `${$("detail").getBoundingClientRect().bottom - $("scroll").getBoundingClientRect().bottom + 12}px`;
}
$("jump").onclick = () => { toBottom($("scroll")); jumpShow(false); };
$("scroll").addEventListener("scroll", () => { if (!$("jump").hidden && atBottom($("scroll"))) jumpShow(false); }, { passive: true });

const loadNewer = coalesce(async () => {
  const a = st.sel;
  if (!a || st.view !== "transcript" || st.end === null || !$("convo")) return;
  const stick = atBottom($("scroll"));
  const page = await api(`/api/transcript?t=${encodeURIComponent(a.target)}&after=${st.end}`);
  if (st.sel !== a) return;
  if (page.start !== st.end) { load(); return; } // fell too far behind: server sent the newest page
  st.end = page.end;
  if (page.events.length) {
    convoAppend($("convo"), page.events);
    if (stick) toBottom($("scroll")); else jumpShow(true);
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
  jumpShow(false);
  for (const n of ["page", "transcript", "screen"]) $("v-" + n).classList.toggle("on", v === n);
}
function setView(v) {
  showView(v);
  if (st.sel) { renderFacts(); renderPin(); load(); }
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
const TAB_NAMES = ["home", "daily", "queue", "projects", "board", "sessions", "infra", "log", "fleet", "schedules", "costs", "releases"];
const RETIRED_TABS = { "waiting": "home", "asks": "home", "watch": "sessions", "shepherd": "sessions", "jobs": "infra", "ci": "infra", "machines": "infra", "today": "log", "history": "log", "actions": "log", "outbox": "daily", "focus": "daily", "numbers": "home" };
// layout::MOVED: a section that left its tab (`#fleet/tokens`) opens on its new tab at that section.
// And the web's old URL for every project's rows, which the TUI still opens with `a` on Projects.
const MOVED = { "fleet/accounts": ["costs", "burn"], "fleet/tokens": ["costs", "tokens"], "fleet/langfuse": ["costs", "langfuse"], "projects/all": ["board", ""] };
const tabOf = (name) => (TAB_NAMES.includes(name) ? name : RETIRED_TABS[name] || TAB_NAMES[0]);
// The open tab's section anchors. Ids repeat across boards (Queue and Costs both have
// sec-table) and a hidden board keeps its HTML, so a lookup stays on the board that shows.
const tabAnchors = () => [...($(st.tab)?.querySelectorAll('[id^="sec-"]') || [])];
// A retired name that is now a section of its tab (`#jobs` is Infra's Jobs section) scrolls
// there once that section has drawn (hub_core::layout::section). Each board calls this after
// it paints; the first paint that has the section clears it.
function seekSection() {
  const e = st.section && tabAnchors().find((x) => x.id === "sec-" + st.section);
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
  const moved = MOVED[name + "/" + arg.toLowerCase()];
  if (moved) return { name, tab: moved[0], arg: "", query, section: moved[1] };
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
  if (ev.kind === "sessions" || ev.kind === "resync") {
    refreshAgents();
    if (st.view === "screen") loadScreen();
    // NEEDS YOU reads who is waiting live, so a dialog opened or answered changes it now.
    if (st.tab === "home") refreshHome();
  }
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
  if (r.section) st.section = r.section;
  if (r.tab !== st.tab || r.arg !== st.arg || r.query !== (st.views[r.tab] ?? "")) setTab(r.tab, r.arg, r.query);
});

// Every script has run by now (they sit at the end of <body>), so every tab is registered.
document.addEventListener("DOMContentLoaded", () => {
  const r = route(location.hash);
  if (RETIRED_TABS[r.name]) st.section = r.name;
  if (r.section) st.section = r.section;
  setTab(r.tab, r.arg, r.query);
  connect();
});
