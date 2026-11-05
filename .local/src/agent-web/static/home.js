"use strict";
// The Home tab, the front page: what needs you, what runs, the numbers and the health strip.
// The list and the numbers are hub_core::home (/api/home), the same join the hub TUI's Home tab
// draws; this file only lays them out. An ask or an open dialog is drawn with waiting.js's
// answer card, so it is answered in place.

// Prometheus pushes nothing, so the open tab also re-reads on the board's cadence; the fleet
// state, the queue and the asks push file events and re-read on those.
const HOME_REFRESH_MS = 60e3;
const hst = { data: null, err: null };

const refreshHome = coalesce(async () => {
  try { hst.data = await api("/api/home"); hst.err = null; } catch (e) { hst.err = e.message; }
  if (st.tab === "home") renderHome();
});

const NEED_KIND = { ask: "question", session: "waiting on you", queue: "waiting", nightly: "nightly failed", red: "failing" };

// A row with no answer card: what it is, how long it has waited, and a way to it.
function needCard(n) {
  const age = n.since ? ` ${ago(n.since)}` : "";
  const cls = n.kind === "nightly" || n.kind === "red" ? "bad" : "waiting";
  const head = cardHead(n.text, [cchip(cls, `${esc(NEED_KIND[n.kind] || n.kind)}${age}`)], n.target || n.id);
  const live = n.target && st.agents.find((a) => a.target === n.target);
  const btn = live ? `<div class="opts"><button class="btn sm" data-open="${esc(n.target)}">Open session</button></div>`
    : n.kind === "queue" ? `<div class="opts"><button class="btn sm" data-tab="queue">Open the queue</button></div>` : "";
  return `<div class="card">${head}${cardLine([esc(n.project), [n.text, n.target, n.project].includes(n.id) ? "" : esc(n.id)])}${btn}</div>`;
}

// An ask or a session dialog the page can answer gets its answer card; the rest a plain card.
function needHtml(n) {
  if (n.kind === "ask") {
    const a = st.asks.find((x) => x.id === n.id);
    if (a) return askCard(a);
  }
  if (n.kind === "session") {
    const a = st.agents.find((x) => x.target === n.target && x.question);
    if (a) return sessionCard(a);
  }
  return needCard(n);
}

function runningCard(r) {
  const p = r.phases;
  const chips = [cchip("running", `running${r.started ? ` ${ago(r.started)}` : ""}`)];
  const line = cardLine([esc(r.project), p ? `phase ${p.done}/${p.total}` : "", p && p.next ? `next: ${esc(p.next)}` : "", etaText(p)]);
  return `<div class="card">${cardHead(r.title, chips, r.slug)}${line}</div>`;
}

// Green collapses to one chip; only what is not green is named.
const LEVEL = { ok: ["ok", "OK"], warn: ["warn", "WARN"], red: ["bad", "RED"], nodata: ["", "NO DATA"] };
function healthHtml(chips) {
  if (!chips.length) return `<span class="muted">no data</span>`;
  const bad = chips.filter((c) => c.level !== "ok");
  if (!bad.length) return cchip("ok", `all green (${chips.length})`);
  return bad.map((c) => cchip(LEVEL[c.level][0], `${esc(c.name)} ${LEVEL[c.level][1]}`)).join(" ") +
    ` <span class="muted">${chips.length - bad.length} green</span>`;
}

function drawHome() {
  const el = $("home"), h = hst.data;
  if (!h) { paint(el, hst.err ? `<div class="err">${esc(hst.err)}</div>` : '<div class="empty">Reading...</div>', askst.open); return; }
  const sec = (title, n, body) => `<h2 class="sec">${title}${n != null ? ` <span class="muted">${n}</span>` : ""}</h2>${body}`;
  const errs = [hst.err, ...h.errors].filter(Boolean).map((e) => `<div class="cline warn">${esc(e)}</div>`).join("");
  // A long list shows its first `shown` rows; the rest fold under "+N older" (dashboards: capped lists).
  const capped = (k, rows, card, word, empty) => !rows.length ? `<div class="empty">${empty}</div>` :
    rows.slice(0, h.shown).map(card).join("") +
    (rows.length > h.shown ? cfold(k, `+${rows.length - h.shown} ${word}`, rows.slice(h.shown).map(card).join(""), askst.open) : "");
  const needs = capped("home-needs", h.needs, needHtml, "older", "Nothing waits on you.");
  const running = capped("home-running", h.running, runningCard, "more", "Nothing running from the queue.");
  const nums = h.numbers.map((n) => `<span><b>${esc(n.label)}</b> ${esc(n.value)}</span>`).join(", ");
  // The two summary lines lead, so a long Needs list never buries them.
  paint(el, errs + sec("Numbers", null, `<div class="cline hnum">${nums}</div>`) +
    sec("Health", null, `<div class="cline">${healthHtml(h.health)}</div>`) +
    sec("Needs you", h.needs.length, needs) + sec("Running", h.running.length, running), askst.open);
}
// Session events re-render this often; keep a reply that is being typed.
const renderHome = () => keepTyping("#home .card", drawHome);

$("home").addEventListener("click", (e) => {
  if (e.target.closest("summary")) return;
  const open = e.target.dataset.open;
  if (open) {
    const a = st.agents.find((x) => x.target === open);
    if (a) { setTab("sessions"); select(a); }
    return;
  }
  if (e.target.dataset.tab) { setTab(e.target.dataset.tab); return; }
  const card = e.target.closest(".card[data-t], .card[data-id]");
  if (card) answerCard(card, e).then(refreshHome);
});
$("home").addEventListener("keydown", answerOnEnter);
$("home").addEventListener("toggle", (e) => {
  if (e.target.dataset && e.target.dataset.k) askst.open[e.target.dataset.k] = e.target.open;
}, true);

const pollHome = poll("home", refreshHome, HOME_REFRESH_MS);
TABS.home = {
  show() { renderHome(); pollHome(); },
  onEvent(ev) { if (st.tab === "home" && ["watch", "queue", "asks", "resync"].includes(ev.kind)) refreshHome(); },
};
