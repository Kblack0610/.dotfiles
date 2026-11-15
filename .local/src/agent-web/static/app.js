"use strict";
// The open session, the tab switch and the live-update stream. Shared helpers are in ui.js; the
// answer cards are waiting.js, Home is home.js, and each board tab is its own static/*.js and
// registers in TABS. Sessions' table and header are sessions.js, its fleet-state facts and the
// last day are watch.js, the shepherd's pass, due lines and rundowns are shepherd.js. An open
// session starts on its conversation; its Details page (sessions.js) is read only when asked for.
const KEYS = [["1","1"],["2","2"],["3","3"],["Enter","Enter"],["Esc","Escape"],["Up","Up"],["Down","Down"],["Tab","Tab"],["S-Tab","BTab"]];

const st = { agents: [], sel: null, view: "transcript", start: null, end: null, tab: "home", page: "", asks: [], parked: [], views: {} };
// The board tabs (static/*.js) register here: { show(), onEvent(ev) }, and `inner(id)` for a tab whose
// inner tabs read their own data (innerGo).
const TABS = {};
// Log's sections past the day (Work, Actions, Changes, Rundowns, the judges' verdicts, Ranked): the
// file that owns each one's data adds {sec, show, onEvent} here and paints its own container.
const LOG_PARTS = [];
// Whether Log shows the inner tab holding section `sec`: a Log part reads only then (dashboards
// rule 10), and an event for a hidden one marks it stale for when its inner tab opens.
const logShows = (sec) => st.tab === "log" && innerShown("log", homeOf("log", sec));

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
  const t = esc(a.target), err = st.approveErr[a.target] ? `<span class="err">${esc(st.approveErr[a.target])}</span>` : "";
  // A sent approval draws busy on every surface (Home, the pinned card, a Queue item) until the
  // session list says the dialog is gone, so a slow approve never reads as a dead click.
  if (askst.sending[`ses:${a.target}`]) return `<button class="btn sm primary" disabled><span class="spin"></span>Approving...</button>`;
  return err + (st.approving === a.target
    ? `<button class="btn sm primary" data-approve-go="${t}">Yes, approve the plan</button><button class="btn sm" data-approve-no>Cancel</button>`
    : `<button class="btn sm primary" data-approve="${t}">Approve plan</button>`);
}
function rerenderApprove() {
  sst.render();
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
  const key = `ses:${t}`;
  if (askst.sending[key]) return;
  delete st.approveErr[t];
  askst.sending[key] = "the plan approval";
  rerenderApprove();
  try { await post(`/api/session/${encodeURIComponent(t)}/approve-plan`, {}); await refreshAgents(); }
  catch (x) { st.approveErr[t] = x.message; }
  delete askst.sending[key];
  rerenderApprove();
}, true);

// Session actions (hub-core session_actions on the server). A button only arms a confirm
// here in the page; the confirm's own button sends it. Parked rows offer only unpark.
const DANGER = ["stop", "cancel"];
// The button for each session action (hub-core session_actions.rs names); an unknown one shows its name.
const ACT_LABEL = { interrupt: "Interrupt", park: "Park session", unpark: "Unpark session", move: "Move to account",
  stop: "Stop session", cancel: "Cancel task", "approve-plan": "Approve plan" };
const actLabel = (n) => ACT_LABEL[n] || n;
st.act = { confirm: null, busy: false, msg: "", err: false };
// Why the last Approve plan failed, by session target, shown beside its button.
st.approveErr = {};
st.opts = { describe: {}, accounts: [] };
api("/api/session-options").then((o) => { st.opts = o; if (st.sel) renderActs(); }).catch((e) => console.warn(e));

// A fold opened on a phone stays open across redraws. Only then: a wide screen has them all open.
document.addEventListener("toggle", (e) => { if (e.target.matches?.("details.pfold") && isPhone()) PFOLD[e.target.dataset.pf] = e.target.open; }, true);
if (typeof matchMedia === "function") matchMedia(PHONE_WIDTH).addEventListener("change", pfoldFit);

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
    const btns = (a.actions || []).map((n) => `<button class="btn${DANGER.includes(n) ? " danger" : ""}" data-act="${esc(n)}" ${st.act.busy ? "disabled" : ""}>${esc(actLabel(n))}</button>`).join("");
    if (btns) html += pfold("acts", "Actions", `<div class="actrow">${btns}</div>`);
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
  el.innerHTML = sessionCard(a, dialogKind(a.question), true);
}
$("ask-pin").addEventListener("click", (e) => { const c = e.target.closest(".card"); if (c) answerCard(c, e); });
$("ask-pin").addEventListener("keydown", (e) => answerOnEnter(e));

function select(a) {
  if (!st.sel || st.sel.target !== a.target) st.act = { confirm: null, busy: st.act.busy, msg: "", err: false };
  if (st.sel) markSeen(st.sel.session);
  st.sel = a; st.start = null; st.end = null;
  markSeen(a.session);
  showView("transcript");
  $("main").classList.add("open");
  $("err").textContent = "";
  renderHead(); renderFacts();
  $("scroll").innerHTML = "";
  load();
}

// No session open: the page is the inner tabs' strip and one group each, the table (sessions.js)
// and the folds under it, the runners (fleet.js) and the shepherd (shepherd.js); TABS.sessions
// reads only the one shown. It draws only the empty boards: its one caller, TABS.sessions.show,
// then calls inner(), whose render of the shown inner tab fills its board.
function overview() {
  if (st.sel) markSeen(st.sel.session);
  st.sel = null; st.start = null; st.end = null;
  $("d-dot").hidden = $("v-seg").hidden = true;
  $("d-name").textContent = "Sessions";
  $("acts").hidden = true;
  $("compose").hidden = true;
  renderPin();
  $("main").classList.remove("open");
  $("scroll").innerHTML = `<div id="sessions">${innerStrip("sessions")}` +
    innerWrap("sessions", "sessions", `<div id="ov-sessions"></div>`) +
    innerWrap("sessions", "fleet", `<div id="sec-fleet" data-tbl="${RUNNERS_PRE}"><div id="ov-runners"></div></div>`) +
    innerWrap("sessions", "shepherd", `<div id="sec-shepherd"><div id="ov-shepherd"></div></div>`) + `</div>`;
  renderFacts(); renderSide();
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
const TAB_NAMES = ["home", "daily", "log", "queue", "sessions", "projects", "releases", "alerts", "infra", "schedules", "costs"];
const RETIRED_TABS = { "waiting": "home", "asks": "home", "watch": "sessions", "shepherd": "sessions", "fleet": "sessions", "jobs": "infra", "ci": "infra", "machines": "infra", "today": "log", "history": "log", "actions": "log", "outbox": "daily", "focus": "daily", "numbers": "home", "board": "projects" };
// layout::MOVED: a section that left its tab (`#fleet/tokens`) opens on its new tab at that section,
// and a third field is the view it opens with (`#infra/cloud` is Machines under its cloud chip).
const MOVED = { "fleet/accounts": ["costs", "burn"], "fleet/tokens": ["costs", "tokens"], "fleet/langfuse": ["costs", "langfuse"], "fleet/workers": ["sessions", "fleet"],
  "infra/health": ["alerts", "health"], "infra/red": ["alerts", "firing"], "infra/fixes": ["alerts", "fixes"], "infra/reds": ["alerts", "fixes"],
  "infra/governor": ["infra", "machines", "ms=governed"], "infra/cloud": ["infra", "machines", "ms=cloud"],
  "releases/builds": ["infra", "runs"], "releases/tests": ["infra", "tests"] };
// hub_core::layout's inner tabs: a strip of sub-views inside one tab, each a group of its sections.
// assets.rs `inner_tabs_are_the_layout` fails when this line drifts.
const INNER_TABS = {"log":{"tabs":[["work","Work",["work"]],["day","Day",["day","history"]],["actions","Actions",["actions"]],["changes","Changes",["changes"]],["rundowns","Rundowns",["rundowns"]],["judges","Judges",["verdicts"]],["ranked","Ranked",["ranked","forecast"]]]},"sessions":{"tabs":[["sessions","Sessions",["sessions","detail"]],["runners","Runners",["fleet"]],["shepherd","Shepherd",["shepherd"]]]},"projects":{"tabs":[["list","Projects",["cards"]],["all","All rows",["board"]],["deliverables","Deliverables",["deliverables"]],["ladder","Ladder",["stages","requirements"]]]},"releases":{"tabs":[["apps","Apps",["table","detail"]],["runs","Release runs",["runs"]]]},"alerts":{"tabs":[["firing","Firing",["health","firing"]],["fixes","Fixes",["fixes"]],["watches","Watches",["watches"]],["history","History",["history"]]]},"infra":{"tabs":[["machines","Machines",["machines","pools"]],["runners","Runners",["ci","waiting","local"]],["runs","Runs",["runs"]],["pipelines","Pipelines",["pipelines"]],["tests","Tests",["tests","quarantine"]],["jobs","Jobs",["jobs"]]]},"costs":{"tabs":[["spend","Spend",["totals","fleet","spend","table","sessions"]],["limits","Limits",["burn","consumers"]],["models","Models",["tokens","langfuse","sections"]],["budget","Budget",["budget"]]]}};
// hub_core::layout::PROJECT_PAGE: an opened project's inner tabs (`#projects/<profile>/<name>/<id>`),
// Overview first. assets.rs `project_page_is_the_layout` fails when this line drifts.
const PROJECT_PAGE = [["overview","Overview",["p-needs","p-flight","p-systems"]],["rows","Rows",["p-rows"]],["build","Build",["p-build"]],["stage","Stage",["p-stage"]],["activity","Activity",["p-shipped","p-timeline","p-note"]]];
// hub_core::links::PAGES and RETIRED_PAGES: a record's page inside an inner tab, by its
// `#tab/<word>/<id>` word (`ci` is a run page's old word), and the inner tab it opens on.
// assets.rs `entity_pages_are_the_links` fails when this line drifts.
const ENTITY_PAGES = {"sessions":{"runners":"runners","sessions":"sessions"},"infra":{"machines":"machines","pools":"machines","runs":"runs","jobs":"jobs","ci":"runs"},"releases":{"apps":"apps"}};
// hub_core::links::RETIRED_TAB_PAGES: a retired tab whose `#tab/<id>` was a record's page, as
// [tab, word] of that page now and the key prefix its table's view took there, so `#fleet/<runner>`
// is `#sessions/runners/<runner>` and `#fleet?s=failed` is `#sessions/runners?rs=failed`.
// assets.rs `retired_tab_pages_are_the_links` fails when this line drifts.
const RETIRED_TAB_PAGES = {"fleet":["sessions","runners","r"]};
// A runner's page (hub_core::links Kind::Runner), for a page that holds a runner's name and no
// server link: Schedules' agentctl rows and Log's judge headers.
const runnerHref = (name) => "#sessions/runners/" + encodeURIComponent(name);
// Open a session's page (hub_core::links Kind::Session, `#sessions/sessions/<id>`) from any tab.
function openSessionId(id) {
  setTab("sessions", "sessions", undefined, "sessions/" + id);
}
// The id of the `word` page the URL has open on `tab` (`#infra/machines/<host>` -> the host), or "".
const pageId = (tab, word) => (st.tab === tab && st.page.startsWith(word + "/") ? st.page.slice(word.length + 1) : "");
// The inner tab a name opens: an inner id, or a section id (an old `#costs/burn` link) for the one
// holding it; a missing or unknown name opens the first. Null when the tab has none.
function innerOf(tab, name) {
  const g = INNER_TABS[tab];
  if (!g) return null;
  const n = String(name || "").trim().toLowerCase();
  return homeOf(tab, n) || g.tabs.find((t) => t[0] === n) || g.tabs[0];
}
// The inner tab holding a section id, if any; the one lookup every caller shares.
const homeOf = (tab, section) => (INNER_TABS[tab] ? INNER_TABS[tab].tabs.find((t) => t[2].includes(section)) : undefined);
// The inner tab each tab last showed, so a tab button brings it back as it was.
const lastInner = {};
// A tab whose arg also names a record (`#projects/<profile>/<name>`) keeps an arg that is not
// one of its inner tabs: the record's page is under its first inner tab (projects.js).
const RECORD_ARGS = ["projects"];
// A record page an older link named with no word (`#sessions/<id>`, before a session's page sat
// under `sessions/` so an id named like an inner tab still opens): any other arg is its id.
const BARE_PAGES = { sessions: "sessions" };
// A route's inner tab: `#costs/models` keeps its arg; a section (an old link, or a moved one) becomes
// its inner tab's arg with the section left to scroll to; anything else is the first inner tab.
function innerRoute(r) {
  const g = INNER_TABS[r.tab];
  if (!g) return r;
  // A record's page (`#infra/machines/<host>`) opens its inner tab and keeps `word/id` as `page`.
  const at = (r.arg || "").indexOf("/");
  const word = at < 0 ? "" : r.arg.slice(0, at).toLowerCase();
  const pages = Object.hasOwn(ENTITY_PAGES, r.tab) ? ENTITY_PAGES[r.tab] : {};
  const inner = Object.hasOwn(pages, word) ? pages[word] : undefined;
  if (inner && r.arg.slice(at + 1)) return { ...r, arg: inner, page: word + "/" + r.arg.slice(at + 1) };
  const want = (r.section || r.arg || "").toLowerCase();
  const hit = homeOf(r.tab, want);
  if (hit) return { ...r, arg: hit[0], section: r.section || (hit[0] === want ? undefined : want) };
  if (g.tabs.some((t) => t[0] === want)) return { ...r, arg: want };
  const bare = Object.hasOwn(BARE_PAGES, r.tab) && r.arg ? BARE_PAGES[r.tab] : "";
  if (bare) return { ...r, arg: pages[bare], page: bare + "/" + r.arg };
  return { ...r, arg: RECORD_ARGS.includes(r.tab) ? r.arg : "" };
}
const tabOf = (name) => (TAB_NAMES.includes(name) ? name : RETIRED_TABS[name] || TAB_NAMES[0]);
// The open tab's section anchors. Ids repeat across boards (Queue and Costs both have
// sec-table) and a hidden board keeps its HTML, so a lookup stays on the board that shows.
const tabAnchors = () => [...($(st.tab)?.querySelectorAll('[id^="sec-"]') || [])];
// A retired name that is now a section of its tab (`#jobs` is Infra's Jobs section) scrolls
// there once that section has drawn (hub_core::layout::section). Each board calls this after
// it paints; the first paint that has the section clears it. A section that paints later above
// it (Infra CI's runs above Tests, each from its own read) pushes it down, so until the reader
// touches the page, a paint that moved the anchor puts it back on top. Any input ends that
// hold: a reader who opened a fold or scrolled is never pulled back.
let seekHeld = null;
for (const ev of ["pointerdown", "wheel", "keydown", "touchstart"]) document.addEventListener(ev, () => { seekHeld = null; }, { capture: true, passive: true });
const anchorAt = (e) => e.getBoundingClientRect?.().top;
function seekTo(board, e) {
  seekHeld = null;
  if (!e.scrollIntoView) return;
  e.scrollIntoView({ block: "start" });
  if (board) seekHeld = { board, id: e.id, top: board.scrollTop, at: anchorAt(e) };
}
function seekSection() {
  // A section on another inner tab switches to it first, so the anchor is on screen.
  const home = st.section && homeOf(st.tab, st.section);
  if (home && home[0] !== innerOf(st.tab, st.arg)[0]) innerGo(st.tab, home[0]);
  const board = $(st.tab);
  const e = st.section && tabAnchors().find((x) => x.id === "sec-" + st.section);
  if (!e) {
    // A section still to paint is the new target: the old hold ends.
    const h = !st.section && seekHeld;
    const a = h && h.board === board && board.scrollTop === h.top && tabAnchors().find((x) => x.id === h.id);
    if (!a) seekHeld = null;
    else if (Math.abs(anchorAt(a) - h.at) > 1) seekTo(board, a);
    return;
  }
  st.section = null;
  // A section in a hidden pane of a record's page (a project's Stage) shows that pane first.
  const pin = e.closest?.("[data-pin][hidden]");
  if (pin && TABS[st.tab] && TABS[st.tab].pin) TABS[st.tab].pin(pin.dataset.pin);
  // A section inside a fold (Log's history in Day detail) opens the fold it sits in.
  const fold = e.tagName === "DETAILS" ? e : e.closest?.("details");
  if (fold) fold.open = true;
  seekTo(board, e);
}
// A URL fragment is `#tab` or `#tab/arg`: the arg is the note a Daily link opens
// (`#daily/status/inbox`) or the project a `#p:` link opens (`#projects/notes-cockpit`).
// The retired `#outbox` is Daily's outbox (`#daily/outbox`); `#focus/<note>` is `#daily/<note>`.
// After a `?` is the tab's own view state, so a view can be linked (`#sessions/runners?rs=failed`).
function route(hash) {
  const [h, q = ""] = String(hash || "").replace(/^#/, "").split(/\?(.*)/s);
  let query = q;
  const at = h.indexOf("/");
  const name = at < 0 ? h : h.slice(0, at);
  let arg = at < 0 ? "" : h.slice(at + 1);
  try { arg = decodeURIComponent(arg); } catch (e) { /* keep it as typed */ }
  if (name === "outbox" && !arg) arg = "outbox";
  // A section that left its tab keeps the query as written: it is that section's view, not the
  // retired tab's table (`#fleet/tokens?q=x` is Costs' q).
  const moved = MOVED[name + "/" + arg.toLowerCase()];
  if (moved) return innerRoute({ name, tab: moved[0], arg: "", query: query || moved[2] || "", section: moved[1] });
  const old = Object.hasOwn(RETIRED_TAB_PAGES, name) ? RETIRED_TAB_PAGES[name] : null;
  if (old && query) {
    // The retired tab's table keeps its view under the prefix it has on its new tab.
    const p = new URLSearchParams(query);
    for (const k of TBL_KEYS) if (p.has(k)) { p.set(old[2] + k, p.get(k)); p.delete(k); }
    query = p.toString();
  }
  if (old && arg) return innerRoute({ name, tab: old[0], arg: old[1] + "/" + arg, query });
  // A retired tab that became a section (`#ci`, layout::section) opens the inner tab holding it.
  const tab = tabOf(name);
  if (tab !== name && !arg && homeOf(tab, name)) return innerRoute({ name, tab, arg: "", query, section: name });
  // A bare `#log` link carrying Actions' view (`#log?q=actor:shepherd&hours=72`, from before the
  // strip) opens Actions: its keys are the table's plain ones and `hours`, Work's are w-prefixed.
  if (tab === "log" && !arg && query && [...TBL_KEYS, "hours"].some((k) => new URLSearchParams(query).get(k))) return innerRoute({ name, tab, arg: "actions", query });
  return innerRoute({ name, tab, arg, query });
}
// Show inner tab `id` of `tab` in place: the URL follows (no history entry, like a tab button),
// the groups' visibility and the strip's marks flip without a repaint. A tab whose inner tabs
// each read their own data (Projects) is told, through its `inner`, which one now shows.
function innerGo(tab, id) {
  const page = st.page;
  st.arg = lastInner[tab] = id;
  st.page = "";
  showUrl();
  // Leaving a record's page (`#infra/ci/<run>`) shows the inner tab's own sections again.
  if (page && st.tab === tab && TABS[tab]) TABS[tab].show();
  const board = $(tab);
  if (!board) return;
  board.querySelectorAll("[data-in]").forEach((e) => { e.hidden = e.dataset.in !== id; });
  stripMark(board, "itab", id);
  // A tab that reads per inner tab (Log) reads the one now shown.
  if (st.tab === tab && TABS[tab] && TABS[tab].inner) TABS[tab].inner(id);
}
// The strip: one button per inner tab, the open one marked, a count pill beside one whose
// sections need a look (`flagged`: section ids, or `counts` by inner id) and only above zero.
const innerStrip = (tab, flagged, counts) => stripHtml(INNER_TABS[tab].tabs, innerOf(tab, st.arg)[0], "itab", flagged, counts);
// A strip's html: `tabs` are [id, title, sections] (an INNER_TABS or PROJECT_PAGE list), `on` the
// open id, `attr` the data- key its buttons carry (itab, or ptab on a project's page). A count
// comes from `flagged` (section ids) or from `counts` by id, and shows only above zero.
function stripHtml(tabs, on, attr, flagged, counts) {
  return `<div class="seg fseg istrip" role="tablist">` + tabs.map(([id, title, secs]) => {
    const n = (counts && counts[id]) || secs.filter((s) => (flagged || []).includes(s)).length;
    return `<button role="tab" data-${attr}="${id}" class="${id === on ? "on" : ""}" aria-selected="${id === on}" tabindex="${id === on ? 0 : -1}">${title}${n ? ` <span class="pill warn">${n}</span>` : ""}</button>`;
  }).join("") + `</div>`;
}
// Mark strip button `id` open among the `attr` buttons inside `root`, for a strip that flips in place.
function stripMark(root, attr, id) {
  root.querySelectorAll(`[data-${attr}]`).forEach((b) => {
    const on = b.dataset[attr] === id;
    b.classList.toggle("on", on);
    b.setAttribute("aria-selected", on ? "true" : "false");
    b.tabIndex = on ? 0 : -1;
  });
}
// A section's html in its inner tab's group, hidden while another inner tab is open; a tab with
// no strip leaves it as it is.
function innerWrap(tab, section, html) {
  const home = homeOf(tab, section);
  if (!home || !html) return html;
  return `<div data-in="${home[0]}"${innerShown(tab, home) ? "" : " hidden"}>${html}</div>`;
}
// Whether inner tab `home` (a homeOf entry) of `tab` is the one open.
const innerShown = (tab, home) => home[0] === innerOf(tab, st.arg)[0];
// innerWrap for an element the page keeps rather than draws (Infra's #jobs, which jobs.js paints
// on its own timer): it joins its section's group, hidden while another inner tab is open.
function innerHide(tab, section, el) {
  const home = homeOf(tab, section);
  if (!home || !el) return;
  el.dataset.in = home[0];
  el.hidden = !innerShown(tab, home);
}
// A strip's click, and the ARIA tabs keys: Left and Right move between tabs, Home and End go to
// the ends. A project page's strip (data-ptab) is the same keys; its click is projects.js's.
document.addEventListener("click", (e) => {
  const b = e.target.closest && e.target.closest("[data-itab]");
  if (b) innerGo(st.tab, b.dataset.itab);
});
document.addEventListener("keydown", (e) => {
  const b = e.target.closest && e.target.closest("[data-itab],[data-ptab]");
  if (!b) return;
  const attr = b.dataset.itab ? "itab" : "ptab";
  const all = [...b.parentNode.querySelectorAll(`[data-${attr}]`)], i = all.indexOf(b);
  const to = { ArrowRight: (i + 1) % all.length, ArrowLeft: (i + all.length - 1) % all.length, Home: 0, End: all.length - 1 }[e.key];
  if (to === undefined) return;
  e.preventDefault();
  all[to].click();
  all[to].focus();
});
// Show tab t; arg is what it opens (blank for its front), query its view state, which a tab
// button leaves as it was. A tab button replaces the URL, so tab hopping makes no history; an
// in-app link (`href="#daily/status/inbox"`) pushes one, so Back returns. page is the record an
// inner tab opens on (innerRoute's `machines/<host>`), blank for none.
function setTab(t, arg, query, page) {
  st.tab = t;
  st.page = page || "";
  // A tab button (no arg) brings back the inner tab that tab last showed.
  st.arg = arg || (arg === undefined && lastInner[t]) || "";
  // A record open on it (a session's id) brings back the inner tab holding it.
  if (INNER_TABS[t]) lastInner[t] = !st.arg || INNER_TABS[t].tabs.some((x) => x[0] === st.arg) ? st.arg : innerOf(t, st.arg)[0];
  st.views[t] = query ?? st.views[t] ?? "";
  // The open tab carries aria-current; web-kit's <kb-shell> marks it and names it on the bar.
  for (const n of TAB_NAMES) {
    if (t === n) $("tab-" + n).setAttribute("aria-current", "page");
    else $("tab-" + n).removeAttribute("aria-current");
    if (n !== "sessions") $(n).hidden = t !== n;
  }
  $("detail").hidden = t !== "sessions";
  if (TABS[t]) TABS[t].show();
  showUrl();
}
function showUrl() {
  const t = st.tab, q = st.views[t];
  // A page's id is one segment whatever it holds: `#infra/machines/<id>`.
  const at = st.page ? st.page.indexOf("/") : -1;
  const segs = st.page ? [st.page.slice(0, at), st.page.slice(at + 1)] : st.arg ? st.arg.split("/") : [];
  const frag = (segs.length ? "#" + t + "/" + segs.map(encodeURIComponent).join("/") : "#" + t) + (q ? "?" + q : "");
  try { history.replaceState(null, "", t === TAB_NAMES[0] && !st.arg && !q ? location.pathname : frag); } catch (e) { /* not fatal */ }
}
// The open tab's view state changed: the URL follows it without a history entry.
function setQuery(q) {
  st.views[st.tab] = q;
  showUrl();
}
for (const n of TAB_NAMES) $("tab-" + n).onclick = () => setTab(n);

// The live line beside the dot, the worst of: the event stream is down (since when, and a Retry),
// the page is catching up after a drop or a hidden spell, or the server could not watch some
// paths (the user's inotify limit, usually; it retries). Nothing to say hides it.
const conn = { open: false, down: 0, catching: false, retrying: false, off: [], html: "" };
function showConn() {
  const off = conn.off, el = $("live-off");
  $("conn").classList.toggle("live", conn.open && !conn.down);
  $("conn").classList.toggle("off", !conn.down && off.length > 0);
  $("conn").title = conn.down ? "live updates down" : off.length ? "live updates off for " + off.join(", ") : "live updates";
  el.className = "cchip live-off" + (conn.down || (!conn.catching && off.length) ? " warn" : "");
  el.hidden = !conn.down && !conn.catching && !off.length;
  el.title = conn.down ? "" : off.join("\n");
  const html = conn.down ? `offline since ${clock(conn.down)} <button class="btn sm" id="live-retry"${conn.retrying ? " disabled>Retrying" : ">Retry"}</button>`
    : conn.catching ? "catching up"
    : off.length ? "live updates off, reload to refresh" : "";
  // Only a change redraws, so an event landing mid-click never swaps the Retry button out.
  if (html !== conn.html) el.innerHTML = conn.html = html;
}
function showLive(ev) {
  conn.off = ev.off || [];
  showConn();
}
// Says "catching up" until `read`, the catch-up's sessions read, lands.
function catchUp(read) {
  conn.catching = true;
  showConn();
  Promise.resolve(read).then(() => { conn.catching = false; showConn(); });
}

// Returns the sessions read the event started, if any, which a catch-up waits on.
function dispatch(ev) {
  let read = null;
  if (ev.kind === "sessions" || ev.kind === "resync") {
    read = refreshAgents();
    if (st.view === "screen") loadScreen();
    // NEEDS YOU reads who is waiting live, so a dialog opened or answered changes it now.
    if (st.tab === "home") refreshHome();
  }
  if (ev.kind === "asks" || ev.kind === "resync") refreshAsks();
  if (ev.kind === "transcript") noteWrite(ev.session);
  // Back from a hidden tab with a session in view: the human is looking at it again.
  if (ev.kind === "resync" && st.sel && viewing(st.sel.session)) markSeen(st.sel.session);
  if ((ev.kind === "transcript" && st.sel && ev.session === st.sel.session) || ev.kind === "resync") {
    if (st.view === "screen") loadScreen(); else loadNewer();
  }
  for (const t of Object.values(TABS)) t.onEvent(ev);
  return read;
}

// A page in a background browser tab reads nothing: events (and poll ticks, ui.js) that arrive
// while it is hidden only mark it behind, and coming back into view replays them as one resync.
// A dashboard left open all day then costs the server nothing until someone looks at it.
let behind = false;
document.addEventListener("visibilitychange", () => {
  if (document.hidden || !behind) return;
  behind = false;
  catchUp(dispatch({ kind: "resync" }));
});

// The stream: EventSource reconnects by itself after a drop, but not after the server answered an
// error (a proxy's 502), so the line's Retry opens a new one.
let es = null;
function connect() {
  if (es) es.close();
  es = new EventSource("/api/events");
  es.onopen = () => {
    const was = conn.down;
    Object.assign(conn, { open: true, down: 0, retrying: false });
    const read = refreshAgents();
    refreshAsks();
    if (st.sel) load();
    if (was) catchUp(read); else showConn();
  };
  es.onerror = () => { Object.assign(conn, { down: conn.down || Date.now(), retrying: false }); showConn(); };
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
  if (r.tab !== st.tab || r.arg !== st.arg || (r.page || "") !== st.page || r.query !== (st.views[r.tab] ?? "")) setTab(r.tab, r.arg, r.query, r.page);
});

// Every script has run by now (they sit at the end of <body>), so every tab is registered.
document.addEventListener("DOMContentLoaded", () => {
  const r = route(location.hash);
  if (RETIRED_TABS[r.name]) st.section = r.name;
  if (r.section) st.section = r.section;
  setTab(r.tab, r.arg, r.query, r.page);
  $("live-off").addEventListener("click", (e) => {
    if (e.target.id !== "live-retry") return;
    conn.retrying = true;
    showConn();
    connect();
  });
  connect();
});
