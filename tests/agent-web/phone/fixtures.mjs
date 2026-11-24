// What the phone render harness answers for /api/*: one payload per endpoint, keyed by path.
// Shapes are the ones the page reads (see the sibling tests/agent-web/*.test.mjs), column, state
// and facet keys are the COLUMNS, STATES and FACETS of the hub-core row they name.
import { readFileSync } from "node:fs";

export const NOW = 1794000000;
const ago = (min) => NOW - min * 60;
const iso = (s) => new Date(s * 1000).toISOString();

// Long on purpose: a phone table that survives these survives real rows.
const TEXT = [
  "fix(agent-web): the shared table scrolls inside its own box on a phone and the page never moves sideways again",
  "feat(hub): a Done view of board rows, every row ticked done across all lab sheets, by day and project, with the PR",
  "fix(claude-acct): RUNS-OUT from current burn, ON-PACE with slack, and a Claude-only fleet line under the headline",
  "fix(wt): find what wrote a module-store path into submodule.External/unity-core.url and stop it at the source",
  "chore(ci): the nightly Tests and Multi jobs pin one runner image, so a red means the code and not a moved base image",
  "feat(playground): the lobby keeps its place through a host migration when the second player drops on a slow link",
  "fix(notes): the sync layer retries a rejected push once after a fetch instead of leaving the sheet a day behind",
  "docs(fleet): the shepherd runbook names the one nudge per fact rule and what a stalled session owes the human",
];
const SLUGS = ["phone-table-scroll", "done-view-board-rows", "claude-acct-runs-out", "wt-module-store-url", "ci-nightly-pin-image", "playground-host-migration", "notes-sync-retry", "fleet-shepherd-runbook"];
const PROJECTS = ["agent-runtime", "notes-cockpit", "game-core-playground", "care-directory", "homelab-config", "agent-runtime"];
const REPOS = ["Kblack0610/.dotfiles", "Kblack0610/.dotfiles-private", "studio/game-core-playground", "studio/care-directory", "Kblack0610/homelab-config", "Kblack0610/.dotfiles"];
const pick = (list, i) => list[i % list.length];

const col = (key) => ({ key, sort: null, next_sort: key, next_dir: "desc" });
function facet(key, values) {
  return { key, on: [], clear: "", values: values.map((value, i) => ({ value, n: values.length - i, on: false, q: `${key}:${value}` })) };
}
// A hub_core::table Summary as it serializes; the first state chip keeps every row. A few words
// carry the tone hub_core::vocab::tone gives them, so a screenshot shows the tiles' hues.
const TONE = { failed: "bad", red: "bad", trip: "bad", error: "bad", attention: "warn", "needs you": "warn", stalled: "warn", ok: "ok", done: "ok" };
function table(n, columns, states = ["all"], facets = {}) {
  return {
    q: "", state: states[0], sort: "", dir: "desc", total: n, shown: n,
    states: states.map((name, i) => ({ name, n: i ? Math.max(1, n - i) : n, tone: i ? TONE[name] : undefined })),
    columns: columns.map(col),
    facets: Object.entries(facets).map(([k, v]) => facet(k, v)),
  };
}
const rows = (n, f) => Array.from({ length: n }, (_, i) => f(i));

// Home: hub_core::home needs, proposals.
const NEED = ["plan", "ask", "perm", "turn", "blocked", "red"];
// The wording the server sends beside each kind (hub_core::home NeedKind::label).
const NEED_LABELS = ["Plan to approve", "Question", "Permission", "Your turn", "Blocked", "Failing"];
// Every capped Home list holds more rows than the page draws (hub_core::home SHOWN), the Needs you list at the 83 that read 2783 px live (ar-2038): Home must stay under budget however long they run.
const NEEDS = 83, PROPOSALS = 12;
// The page size the server sends, read from hub-core so a change to it moves the fixture too.
const HOME_SHOWN = Number(readFileSync(new URL("../../../.local/src/hub-core/src/home.rs", import.meta.url), "utf8").match(/pub const SHOWN: usize = (\d+);/)[1]);
const home = {
  errors: [], grafana: "https://grafana.example",
  health: [{ name: "dispatch", level: "ok" }, { name: "shepherd", level: "warn" }, { name: "sentinel", level: "ok" }],
  vitals: null,
  table: table(NEEDS, ["rank", "kind", "project", "waited", "holds", "what"], ["all", "Plan to approve", "Question", "Permission", "Your turn", "Blocked", "To do", "Failing", "Stopped"], { project: PROJECTS.slice(0, 3) }),
  needs: rows(NEEDS, (i) => ({ kind: i % 2 ? "ask" : "session", id: `need-${i}`, need: pick(NEED, i), label: pick(NEED_LABELS, i), holds: `${3 - (i % 3)} waiting`, holds_line: `holds ${3 - (i % 3)}, ${i % 2 ? "high" : "normal"}`, what: "", rank: i + 1, project: pick(PROJECTS, i), since: ago(25 + i * 37), score: { holds: 3 - (i % 3), priority: i % 2 ? "high" : "normal" }, text: pick(TEXT, i), target: `agent-${i}` })),
  proposals: rows(PROPOSALS, (i) => ({ id: `prop-${i}`, stream: pick(["dream", "skill-refine", "sentinel"], i), project: pick(PROJECTS, i), title: pick(TEXT, i + 2), created: iso(ago(120 + i * 60)), error: null, why: pick(TEXT, i), evidence: "", does: "queue", expires: null, verb: "queue" })),
  // One row per stream (hub_core::proposals::by_stream), what the page draws of the proposals.
  streams: ["dream", "skill-refine", "sentinel"].map((stream, i) => ({ stream, project: pick(PROJECTS, i), count: PROPOSALS / 3, newest: NOW - 600 * (i + 1), oldest: NOW - 86400 * (i + 1) })),
  proposals_head: `${PROPOSALS} from 3 streams`, proposals_failed: false,
  proposals_table: table(PROPOSALS, ["stream", "project", "proposal", "created", "verb"], ["all", "queue", "row", "mem0", "none"], { stream: ["dream", "skill-refine"], project: PROJECTS.slice(0, 2) }),
};
// What the server sends of them (agent-web main.rs home_shown): Needs you and Proposals page 1 at
// SHOWN.
for (const [k, t] of [["needs", "table"], ["proposals", "proposals_table"]]) {
  home[t] = { ...home[t], pager: { page: 1, pages: Math.ceil(home[k].length / HOME_SHOWN), per: HOME_SHOWN } };
  home[k] = home[k].slice(0, HOME_SHOWN);
}
const briefing = {
  since: iso(ago(600)), since_label: "since last night", errors: [], ok_line: "4 more lanes green",
  rows: rows(3, (i) => ({ name: pick(["dispatch", "ci", "spend"], i), link: "", level: pick(["warn", "bad", "ok"], i), line: TEXT[i + 3], details: [], fix: null })),
};

// A table's page size as agent-web pages it: its hub_core::layout PAGE_ROWS entry, read from layout.rs
// so a change there moves the fixture.
const LAYOUT = readFileSync(new URL("../../../.local/src/hub-core/src/layout.rs", import.meta.url), "utf8");
export const pageRows = (section) => {
  const m = LAYOUT.match(new RegExp(`\\("${section}",\\s*(\\d+)\\)`));
  if (!m) throw new Error(`hub-core layout.rs PAGE_ROWS has no ("${section}", N) entry`);
  return Number(m[1]);
};
// Queue: hub_core::queue, live-sized: the active view of 2026-11-12 (637 of 3,007 items, titles
// that wrap and a note on some), of which the server sends the first page.
const QUEUE_STATE = ["running", "waiting", "queued", "queued", "running", "done", "done"];
const qTitle = (i) => (i % 3 ? TEXT[i % TEXT.length] : `${TEXT[i % TEXT.length]}, and ${TEXT[(i + 1) % TEXT.length]}`);
const QUEUE_TABLE = table(637, ["#", "title", "project", "priority", "state", "hold", "from", "in", "wait", "run", "pr", "row", "kind", "size", "pts", "acct", "mode", "plan"], ["active", "needs you", "running", "on a PR", "ready", "held", "done", "all"], { project: PROJECTS.slice(0, 3), priority: ["urgent", "high"], state: ["running", "ready"], hold: ["after"], from: ["human", "board"], kind: ["fix", "feat"], acct: ["main", "bnb"] });
QUEUE_TABLE.states = [["active", 637], ["needs you", 6], ["running", 9], ["on a PR", 40], ["ready", 582], ["done", 2370], ["all", 3007]].map(([name, n]) => ({ name, n, tone: TONE[name] }));
// Candidates: fleet-dispatch's snapshot as /api/queue/candidates sends it (the first page of rows on
// the shared table), and the counts its `?counts=1` read sends for the heading.
const candRow = (i) => ({ profile: "personal", project: pick(PROJECTS, i), lane: "agent", key: `ar-${1400 + i}`, text: TEXT[i % TEXT.length], title: TEXT[i % TEXT.length], stage: "alpha", priority: pick(["urgent", "high", "normal"], i), why: `${pick(PROJECTS, i)} is behind its pace and this row unblocks ${TEXT[(i + 2) % TEXT.length]}`, auto: i % 3 === 0, verdict: i % 5 ? "start" : "hold", held: i % 5 === 0, area: "ui", prio: i % 7 ? 2 : 0, blocked: i % 4 ? [] : ["no worker covers the project", "size l over the slot"], start_label: pick(["oneshot", "plan"], i) });
const CAND_TABLE = table(2612, ["rank", "project", "key", "task", "start", "why", "blocked"], ["all", "clear", "blocked"], { project: PROJECTS.slice(0, 3), blocked: ["no worker", "size"] });
CAND_TABLE.states = [["all", 2612], ["clear", 2140], ["blocked", 472]].map(([name, n]) => ({ name, n, tone: name === "blocked" ? "warn" : undefined }));
const candidates = { ...paged({ rows: rows(CAND_TABLE.total, (i) => ({ rank: i + 1, ...candRow(i) })), table: CAND_TABLE }, "candidates"), auto: 412, urgent_blocked: 3, uncovered: PROJECTS.slice(2, 4), as_of: "13:10" };
const queue = {
  items: rows(637, (i) => ({ slug: `${pick(SLUGS, i)}-${i}`, title: qTitle(i), project: pick(PROJECTS, i), state: pick(QUEUE_STATE, i), status: "ok", priority: pick(["urgent", "high", "normal"], i), start: i === 2 ? 1 : null, hold: i === 3 ? `after ${SLUGS[2]}` : "", waits_for: i === 3 ? `after ${SLUGS[2]}` : "", source: pick(["human", "board"], i), row_id: i % 2 ? `ar-${1100 + i}` : "", mode: "oneshot", plan_label: i === 1 ? "queue table" : "", type: pick(["fix", "feat", "chore"], i), size: pick(["s", "m", "l"], i), account: pick(["main", "bnb", "alt"], i), pr: i > 3 ? `#${1590 + i}` : "", pr_label: i > 3 ? `#${1590 + i}` : "", pr_url: i > 3 ? `https://github.com/Kblack0610/.dotfiles/pull/${1590 + i}` : "", pr_merged: i > 4, note: i % 4 ? "" : TEXT[(i + 3) % TEXT.length], unproven: false, timing: { in_state: 14 + i * 9, wait: 3 + i, run: 22 + i * 6 } })),
  table: QUEUE_TABLE,
  section_aliases: {}, needs_you: 6,
};
{ const p = paged({ rows: queue.items, table: queue.table }, "queue/table"); Object.assign(queue, { items: p.rows, table: p.table }); }
const candCounts = { total: CAND_TABLE.total, auto: candidates.auto, urgent_blocked: candidates.urgent_blocked, as_of: candidates.as_of };
const queueStats = { week: 212, sitting: 9, wait_minutes_median: 7, run_minutes_median: 38, to_pr_minutes_median: 52 };
// /api/flow: hub_core::flow::Rail as `line`, the step `worst` names open (a stopped one here).
const RAIL = [["inbox", "inbox", null], ["backlog", "agent backlog", { tab: "projects/all", state: "" }], ["queued", "queued", { tab: "queue", state: "ready" }], ["running", "running", { tab: "queue", state: "running" }], ["review", "review", null], ["needs", "needs you", { tab: "queue", state: "needs you" }], ["done", "done", { tab: "queue", state: "done" }]];
const flow = {
  grafana: home.grafana,
  line: {
    worst: 3, as_of: "13:20", stale: false, reading: false, error: null, absent: false,
    nodes: RAIL.map(([key, label, to], i) => ({ key, label, count: String(12 - i), sub: key === "done" ? "24h" : `p90 ${20 + i * 7}m`, hot: i === 5, stopped: i === 3, to, stop: i === 3 ? "fleet-assess says HOLD" : null, facts: [`${12 - i} in the step, bound 30m`], problems_n: i === 3 ? 2 : 0, problems: i === 3 ? [{ text: `01:16  ${SLUGS[0]}  failed  ${TEXT[0]}`, item: SLUGS[0] }, { text: `00:42  inbox line  ${TEXT[1]}`, item: null }] : [], elsewhere: null })),
  },
};

// Projects: hub_core::projects.
const projects = {
  table: table(6, ["project", "state", "profile", "stage", "version", "prio", "open", "doing", "hot", "done", "7d", "pts", "pts7d", "window", "due", "pace", "run", "wait", "queued", "shipped", "oldest"], ["all", "in flight", "waiting"], { profile: ["personal", "bnb"], stage: ["alpha", "beta"], state: ["on track", "at risk", "late"] }),
  cards: rows(6, (i) => ({ name: `${pick(PROJECTS, i)}${i === 5 ? "-web" : ""}`, state: pick(["on track", "at risk", "late"], i), state_level: pick(["ok", "warn", "bad"], i), profile: pick(["personal", "bnb", "gigantic"], i), stage: pick(["alpha", "beta", "live"], i), version: `0.${i}.${i + 2}`, prio: i + 1, progress: { open: 40 - i * 4, done: 60 + i * 3, closed_7d: 11 - i, done_weight: 90 + i * 4, closed_weight_7d: 15 - i }, doing: 2 + i % 2, hot: i % 3, window: { version: `0.${i}.${i + 2}`, committed: 80 - i * 5, delivered: 20 + i * 3, due: "2026-11-30", days_left: 12 - i }, window_says: `${20 + i * 3}/${80 - i * 5} due 11-30`, window_cell: `${20 + i * 3}/${80 - i * 5}`, due_cell: `${12 - i}d`, pace: 1.4 + i / 10, running: [], waiting: i % 2, queued: 4 - i % 3, today: { shipped: 3 - i % 3, checks: i % 2 }, oldest: iso(ago(4000 + i * 1000)), summary: TEXT[i], goal: pick(TEXT, i + 1), counts: { open: 40 - i * 4 }, note_says: "", status: { headline: { role: "note", text: TEXT[i] }, rows: [["Done", pick(TEXT, i + 1)], ["Doing", pick(TEXT, i + 2)], ["Next", pick(TEXT, i + 3)], ["Needs you", "nothing."]].map(([l, v]) => ({ label: { role: "chip", text: l }, value: { role: "note", text: v } })) }, status_date: "2026-11-21" })),
  unlinked: [], errors: [],
};

// Deliverables: hub_core::deliverables, one row per open feature epic.
const deliverables = {
  table: table(5, ["project", "epic", "sys", "done", "eta", "track"], ["all", "behind", "on track", "verify"], { project: PROJECTS.slice(0, 3), sys: ["gameplay", "ui", "save"] }),
  rows: rows(5, (i) => ({ project: pick(PROJECTS, i), profile: "personal", id: `ep-${i + 1}`, title: TEXT[i], system: pick(["gameplay", "ui", "save"], i), done: 9 - i, total: 15, percent: 60 - i * 7, done_says: `${60 - i * 7}% ${9 - i}/15`, eta: ago(-1440 * (i + 1)), eta_day: `11-${14 + i}`, track: pick(["behind", "verify", "on track"], i) })),
  verify: 2, on_track: 1, behind: 2, coverage: { linked: 1013, open_rows: 2600, none: ["infra", "demo-web"] },
  says: "Deliverables (5 open, 2 ready to verify, 1 on track, 2 behind)",
  coverage_says: "Coverage: 1,013 linked / 2,600 open rows (39%); no feature epic: infra, demo-web",
  legend: "percent is the epic's rows by size (#size/s 1, m 3, l 8), then rows done/all",
};

// Coverage: hub_core::departments, every typed project's department cells, worst first.
const DEPTS = [["product", "Product"], ["engineering", "Engineering"], ["ops", "Ops"], ["design", "Design"], ["analytics", "Analytics"], ["marketing", "Marketing"], ["legal", "Legal"], ["support", "Support"], ["money", "Money"]];
const CELLS = ["red", "amber", "off", "ok"];
const coverage = {
  table: { ...table(4, ["project", "type", "stage", ...DEPTS.map(([d]) => d)], ["all", "red", "amber", "off", "ok"], { type: ["game", "app"] }), legend: "red: a required department has a gap; amber: a gap before it is due; off: no source yet" },
  rows: rows(4, (i) => ({ key: `bnb/${PROJECTS[i + 1]}`, profile: "bnb", name: PROJECTS[i + 1], type: pick(["game", "app"], i), stage: pick(["dev", "alpha", "beta"], i), cells: Object.fromEntries(DEPTS.map(([d], j) => [d, pick(CELLS, i + j)])) })),
  head: "2 red  |  14 off", says: [], red: 2, amber: 4, off: 14, failing: 2, departments: DEPTS,
};

// Ladder: hub_core::stages, each staged project against its next stage, then stages.md's Requirements.
const STAGES = ["idea", "dev", "alpha", "beta", "prod"];
const stages = {
  table: table(5, ["project", "type", "stage", "next", "met", "failing", "filed"], ["all", "failing", "met", "not read"], { type: ["game", "app", "infra"], stage: STAGES.slice(1) }),
  rows: rows(5, (i) => ({ name: pick(PROJECTS, i), profile: pick(["personal", "bnb"], i), type: pick(["game", "app", "infra"], i), stage: STAGES[1 + (i % 4)], next: STAGES[Math.min(4, 2 + (i % 4))], met: 4 + i, total: 9, fail: i < 3 ? 3 - i : 0, todo: 2, human: 1, filed_open: 3 - (i % 3), filed_closed: i, error: i === 4 ? "project-stage-check: no stage beta-2 in stages.md" : null, state: i === 4 ? "not read" : i < 3 ? "failing" : "met", met_says: i === 4 ? "" : `${4 + i}/9`, filed_says: `${3 - (i % 3)}/${i}` })),
  says: "", gate_says: "report only until 2026-11-19 (in 6 days), then a failing row blocks a stage move", gate_level: "warn",
  filer_says: "nightly, last 04:30 today: 6 filed, 1 met and closed, 0 epics opened", filer_level: "",
  kinds_says: "on fix feat chore docs; off legal store", kinds_level: "", failing: 4, doc: "~/.local/src/docs/stages.md", filer_href: "#schedules?q=name:=project-index",
};
const stageReqs = {
  table: table(6, ["stage", "applies", "requirement", "check", "by"], ["all", "test", "human", "not yet"], { stage: STAGES, applies: ["base", "game", "store"], check: ["test", "human", "not yet"] }),
  rows: rows(6, (i) => ({ stage: STAGES[i % 5], applies: i % 3 ? ["game", "store"] : ["base"], requirement: TEXT[i], check: pick(["`test -f README.md`", "human", "not yet: a store check"], i), kind: pick(["predicate", "human", "not-yet"], i), skills: i % 2 ? ["fix-ci"] : [], says: pick(["test", "human", "not yet"], i) })),
  says: "",
};

// A project page (hub_core::page) as big as unity-core-playground's on 2026-11-12, which read
// 33,558 px before it had inner tabs: 16 systems, 1,000 items needing the human, a 29-check stage
// and a long timeline. render.mjs holds each of its inner tabs to the height budget.
export const BIG_PROJECT = { profile: "personal", name: "agent-runtime" };
const SYSTEMS = ["gameplay", "ci", "ui", "save", "netcode", "audio", "input", "render", "tools", "build", "perf", "art", "levels", "ai", "store", "docs"];
const needs = (kind, n, says) => ({ kind, says: `${n} ${says}`, items: rows(n, (i) => `ep-${i + 1}: ${TEXT[i % TEXT.length]}`) });
// Its Releases tab (hub_core::project_releases): a long line, its apps, and a Legacy fold of 60.
const bigVer = (n, status, line) => ({ version: `v0.${Math.floor(n / 10)}.${n % 10}`, status, level: status === "legacy" ? "neutral" : "ok", line_text: line, done: 20, total: 24, progress_text: "20 of 24 rows done", cut_text: `v0.${Math.floor(n / 10)}.${n % 10} 11-12 14:02`, href: `#releases/versions/agent-runtime%2F0.${Math.floor(n / 10)}.${n % 10}` });
const bigApp = (i, line) => ({ app: `agent-runtime-${i}`, status_text: "ok", level: "ok", live_text: "v0.4.0 prod", released_text: "11-10", line_text: line, href: `#releases/apps/agent-runtime-${i}` });
const bigReleases = {
  versions: rows(30, (i) => bigVer(99 - i, pick(["released", "cut", "unreleased"], i), "on the line")), apps: rows(6, (i) => bigApp(i, "line from v0.4.0")),
  legacy_versions: rows(60, (i) => bigVer(59 - i, "legacy", "before the line")), legacy_apps: rows(4, (i) => bigApp(i + 6, "no line (no releaseFrom)")),
  line_text: "line from v0.4.0", legacy_says: "60 versions, 4 apps from before the release line", elsewhere: [], errors: [],
};
const bigPage = {
  project: BIG_PROJECT.name, flow_line: "plan 12, building 30, landed 37, verified 4",
  releases: { level: "ok", says: "0.4.0 prod ok" }, alerts: { level: "warn", says: "1 firing of 9 watches" },
  gate: { stage: "beta", fail: 4, human: 2 }, next_says: "beta: 9 of 29 met, 4 failing", errors: [],
  need_count: 1000,
  need_groups: [needs("verify", 600, "epics landed with no live proof"), needs("ask", 250, "asks waiting on you"), needs("red", 150, "red watches on this project")],
  next_rows: rows(29, (i) => ({ result: pick(["FAIL", "HUMAN", "PASS", "PASS", "PASS"], i), requirement: TEXT[i % TEXT.length], stage: "beta" })),
  systems_says: "16 systems, 30 open epics",
  systems: SYSTEMS.map((id, i) => ({ id, percent: 5 + i * 6, features: 2 + i % 3, features_done: i % 2, standing: 1, open_rows: 40 + i * 7, behind: i % 3, criteria_met: i % 5, criteria_total: 5, wave: { title: TEXT[i % TEXT.length], percent: 30 + i, more: i % 4 } })),
  shipped_says: "3 versions", shipped: ["0.4.0 (Nov 10)", "0.3.2 (Oct 28)", "0.3.1 (Oct 14)"],
  timeline: { says: "40 events in 14 days", notes: [], lines: rows(40, (i) => ({ line: `11-${String(12 - (i % 12)).padStart(2, "0")} ${TEXT[i % TEXT.length]}`, url: "", level: pick(["ok", "ok", "warn"], i) })), older: 160 },
  release_tab: bigReleases,
};

// Board: hub_core::tasks.
const board = {
  table: table(8, ["section", "title", "epic", "priority", "state", "when", "project", "lane", "id", "version", "size", "tier", "since", "text", "profile", "tag"], ["all", "in progress", "filed today", "urgent", "requested", "done"], { project: PROJECTS.slice(0, 3), lane: ["agent", "human"], priority: ["high", "normal"] }),
  rows: rows(8, (i) => ({ sheet: `~/.notes/lab/projects/current/${pick(PROJECTS, i)}/tasks.md`, raw: `- [ ] ${TEXT[i]}`, label: pick(["Now", "Next", "Later"], i), when: pick(["queued, ETA 14:10", "", "running 40m"], i), id: `ar-${1100 + i}`, priority: pick(["high", "normal", "low"], i), project: pick(PROJECTS, i), lane: pick(["agent", "human"], i), state: pick(["todo", "doing"], i), version: "0.2", game: "", size: pick(["s", "m"], i), tier: "", since: iso(ago(2000 + i * 300)), text: TEXT[i], title: TEXT[i], summary: "", epic: i % 2 ? "" : "ui to standard", tags: ["requested"], worker: i % 3 ? "" : `agent-${i}`, ask: "" })),
  projects: PROJECTS.slice(0, 5).map((project) => ({ profile: "personal", project, inbox: 2 })),
  focus: [{ profile: "personal", open: 12 }],
};

// Projects > Sprints: /api/sprints, hub_core::tasks::SprintRow per open or queued window, then each
// project's last score (hub_core::project_sprints::LastScore).
const SPRINT_COLS = ["project", "version", "started", "cut", "left", "done", "finish", "build"];
const sprints = {
  rows: PROJECTS.slice(0, 6).map((project, i) => ({ profile: "personal", project, version: `v0.${i + 1}.0`, queued: i % 3 === 2, started: "11-19 14:25", cut: "11-20 15:59", left: i % 3 === 2 ? "queued" : "6h", done: `${i}/5`, finish: "~15:40", late: false, build: "none" })),
  table: { columns: SPRINT_COLS.map((key) => ({ key, role: key === "project" ? "lead" : "" })), links: PROJECTS.slice(0, 6).map((project, i) => ({ version: `#projects/personal%2F${project}/sprint/v0.${i + 1}.0` })) },
  heads: Object.fromEntries(SPRINT_COLS.map((k) => [k, k.toUpperCase()])),
  last: PROJECTS.slice(0, 4).map((project, i) => ({ profile: "personal", project, version: `v0.${i}.0`, line: "delivered 4 of 5" })),
};

// Sessions: hub_core::session_table, live-sized: 342 rows on 2026-11-12, of which the server sends
// the first page, and a lane a session under the table.
const BUCKET = ["WORKING", "STALLED", "NEEDS", "WORKING", "LANDED", "DONE"];
const SESSION_ROWS = 342;
const sessions = {
  table: table(SESSION_ROWS, ["bucket", "activity", "project", "task", "by", "pr", "phases", "idle", "ctx", "cost", "acct", "harness", "close", "item", "source", "session"], ["all", "running", "needs you", "stalled", "ended today"], { project: PROJECTS.slice(0, 3), harness: ["claude", "codex"] }),
  rows: rows(SESSION_ROWS, (i) => ({ key: `s-${i}`, target: `agent-${i}`, session_id: `${String(i).padStart(8, "0")}-aaaa-bbbb-cccc-000000000000`, bucket: pick(BUCKET, i), activity: pick(["editing", "gate", "review"], i), project: pick(PROJECTS, i), task: qTitle(i), by: pick(["dispatch", "hand", "resume"], i), pr: i > 2 ? `#${1590 + i}` : "", pr_state: i > 2 ? "open" : "", ci: i > 2 ? "green" : "", phases_done: i % 6, phases_total: 5, idle_min: 2 + i * 6, ended: null, context_tokens: i % 4 ? 40000 + i * 900 : null, context_window: i % 4 ? 200000 : null, context_pct: i % 4 ? Math.round((40000 + i * 900) / 2000) : null, cost_usd: 1.5 + i * 2.25, account: pick(["main", "bnb", "alt"], i), harness: pick(["claude", "codex"], i), source: pick(["queue", "hand"], i) })),
  spend_usd: 41.5, buckets: ["NEEDS", "STALLED", "WORKING", "LANDED", "DONE"], errors: [],
};
Object.assign(sessions, paged(sessions, "sessions/sessions"));
const capacity = { parts: [{ text: "39 live", warn: false, start: "", confirm: "" }, { text: "2 slots free", warn: true, start: "", confirm: "" }], unlinked: 0, live: 39, errors: [] };
const watch = { state: { sessions: rows(39, (i) => ({ target: `lab/agent-${i}:1`, bucket: pick(BUCKET, i), age_min: 30 + i * 20 })), vocab: { buckets: sessions.buckets }, generated_at: iso(NOW) }, transitions: [] };
// Log's Rundowns: as many as agent-web keeps (shepherd.rs RUNDOWNS), each a long sum-up like the
// live ones, of which the server sends the first page, so the inner tab's height is measured at a live count.
const rundownBody = (i) => `## Your requests\n\n${rows(24, (k) => `- ${SLUGS[(i + k) % SLUGS.length]}-${k}, queued, no open PR, no ETA, waits on: ${TEXT[k % TEXT.length]}`).join("\n")}\n`;
const shepherd = {
  target: "", status: "", stats: null, ledger: { due: [], lease_at: null, lease_holder: "" },
  rundowns: rows(60, (i) => ({ file: `2026-11-${String(12 - Math.floor(i / 6)).padStart(2, "0")}T${String(2359 - i).padStart(4, "0")}Z.md`, title: TEXT[i % TEXT.length].slice(0, 60), stamp: `2026-11-${String(12 - Math.floor(i / 6)).padStart(2, "0")} 12:${String(i % 60).padStart(2, "0")} UTC`, body: rundownBody(i) })),
};
{ const p = paged({ rows: shepherd.rundowns, table: { shown: shepherd.rundowns.length, pager: null } }, "rundowns"); Object.assign(shepherd, { rundowns: p.rows, rundowns_table: p.table }); }

// Infra: Prometheus instant vectors, and the jobs board from hub_core::jobs.
const runner = (i) => ({ labels: { name: `runner-${i}`, host: pick(["asus-laptop", "mac-mini", "workstation"], i), site: "home", state: "busy", pool: pick(["unity", "default"], i), repo: "game-core-playground", pr: `${1700 + i}`, job_name: "Tests (EditMode)", title: TEXT[i], workflow: "ci", branch: `feat/${SLUGS[i]}` }, value: 600 + i * 120 });
const infra = {
  ok: true, at: NOW, grafana: home.grafana, down: [],
  instant: { cc: [{ labels: { __name__: "cc:overall_status" }, value: 0 }, { labels: { __name__: "cc:asks_open" }, value: 2 },
    ...["workstation", "asus-laptop"].flatMap((host, i) => [["cc:host_cores", 24], ["cc:host_cpu_busy_ratio", 0.7 - i / 2], ["cc:host_mem_used_ratio", 0.5], ["cc:host_load1", 12], ["cc:host_temp_c", 71]].map(([__name__, value]) => ({ labels: { __name__, host }, value })))], red: [], runners: rows(4, runner), waiting: [], gates: [], hourly: [], local_hourly: [], failed: [], local_failed: [], recent: [], recent_dur: [], power: [], governor: [], cores: [], runner_use: [], withheld: [] },
};
const jobs = {
  table: table(7, ["state", "source", "name", "started", "took", "result", "host", "detail"], ["all", "running", "queued", "done", "failed"], { source: ["forgejo", "github", "local"], result: ["ok", "failed"] }),
  jobs: rows(7, (i) => ({ state: pick(["running", "done", "failed"], i), source: pick(["forgejo", "github", "local"], i), name: `Tests (EditMode) ${SLUGS[i]}`, started: ago(10 + i * 11), finished: i % 3 ? ago(i * 3) : null, secs: 240 + i * 90, result: pick(["", "ok", "failed"], i), ok: i % 3 === 1, host: pick(["workstation", "asus-laptop", "mac-mini"], i), runs: 1, next: null, url: "https://github.com/Kblack0610/.dotfiles/actions/runs/1", log: null, detail: TEXT[i] })),
  window_secs: 86400, at: NOW, ci: { level: "ok", says: "CI green" }, errors: [],
};
// Runners: hub_core::ci's head and its tables, each under its view as infra.rs renders them.
const localFail = (i) => ({ repo: "game-core-playground", branch: `feat/${SLUGS[i]}`, platform: pick(["android", "windows", "ios"], i), result: pick(["failure", "cancelled"], i), n: 3 - i, last: ago(30 + i * 90) });
infra.ci = { hosts: 3, slots: 6, busy: 4, queued: 1, oldest: ago(25), red: [], day: { runs: 40, pass: 0.9, failed_main: 1, failed_branch: 3, cancelled: 2, local: 5, local_pass: 0.8, read: true } };
infra.tables = {
  machines: { rows: [], table: table(0, ["machine", "state", "taken", "cpu", "6h", "load", "mem", "temp", "disk", "running", "next", "governor", "power", "up"]) },
  pools: { rows: [], table: table(0, ["pool", "weight", "running", "waiting", "oldest", "done", "pass", "machines"]) },
  runners: { rows: [], table: table(0, ["host", "slot", "state", "pool", "ran", "usual", "job", "ref"]) },
  queued: { rows: [], table: table(0, ["job", "pool", "ref", "n", "wait", "needs", "can"]) },
  local: { rows: rows(3, localFail), table: table(3, ["last", "repo", "branch", "platform", "result", "failed"], ["all"], { repo: ["game-core-playground"], platform: ["android", "windows", "ios"] }) },
};

// Log: the day, and the actions table from hub_core::actions.
const log = {
  date: "2026-11-05", live: true, gathered_at: iso(NOW),
  merged: rows(6, (i) => ({ repo: pick(REPOS, i), project: pick(PROJECTS, i), number: 1580 + i, url: "https://github.com/Kblack0610/.dotfiles/pull/1", title: TEXT[i], merged_at: iso(ago(30 + i * 40)), area: pick(["agent-web", "hub", "ci"], i), group: pick(["agent-web", "hub", "ci"], i), scope: pick(["agent-web", "hub"], i), by: "agent" })),
  open: rows(3, (i) => ({ repo: pick(REPOS, i), project: pick(PROJECTS, i), number: 1600 + i, url: "https://github.com/Kblack0610/.dotfiles/pull/2", title: TEXT[i + 2], created_at: iso(ago(90)), draft: false, ci: "green", by: "agent" })),
  projects: [], hours: { hours: [], rows: [] }, usage: [{ project: "TOTAL", sessions: 42 }], waiting: { main: [], needs: [], asks: [] },
  counts: { merged: 6, repos: 4, open: 3, nightly: 0, asks: 0 },
  bench: { headline: "212 merged this week, 52% first try", sessions: rows(3, (i) => ({ target: `lab/unity-core-playground-agent-${i}:1`, plan: SLUGS[i], name: TEXT[i].slice(0, 48), phase: "2/4", working_h: 1.5, waiting_h: 0.2, stalled_h: 0, prs_merged: 2, ci_reds: 1, peak_k: 310, cost_usd: 12.5 })) },
  timeline: [], unreadable: [],
};
const logHistory = rows(5, (i) => ({ date: `2026-11-0${5 - i}`, merged: 40 - i * 3, repos: 4, areas: { "agent-web": 9, hub: 7 } }));
const actions = {
  table: table(7, ["when", "actor", "verb", "prio", "source", "text"], ["all", "loud", "failed"], { actor: ["shepherd", "dispatch", "sentinel"], verb: ["page", "nudge", "start"] }),
  actions: rows(7, (i) => ({ at: ago(5 + i * 13), actor: pick(["shepherd", "dispatch", "sentinel"], i), verb: pick(["page", "nudge", "start"], i), priority: pick(["high", "normal"], i), source: pick(["fleet-lead", "cron"], i), text: TEXT[i] })),
  counts: { actor: { shepherd: 3, dispatch: 2, sentinel: 2 }, verb: { page: 3, nudge: 2, start: 2 } }, errors: [],
};

// Log's Work table: hub_core::worklog, a live-sized table of which the server sends the first
// page of WORK_SHOWN rows (hub_core::layout::page_rows("work")) and its pager.
const WORK_SHOWN = pageRows("work");
const WORK_TOTAL = 3235;
const logWork = {
  table: table(WORK_TOTAL, ["state", "when", "project", "what", "plan", "kind", "ci", "pr", "cost"], ["all", "done", "active", "waiting", "queued", "failed", "cancelled"], { project: PROJECTS.slice(0, 5), kind: ["fix", "feat", "chore"] }),
  rows: rows(WORK_SHOWN, (i) => ({ state: pick(["failed", "waiting", "active", "done", "done", "queued"], i), when: iso(ago(30 + i * 90)).slice(0, 16), project: pick(PROJECTS, i), what: TEXT[i % TEXT.length], kind: pick(["fix", "feat", "chore"], i), pr: `.dotfiles#${1580 + i}`, url: "https://github.com/Kblack0610/.dotfiles/pull/1", cost: 1.25 * i, slug: SLUGS[i % SLUGS.length], unproven: false, plan: i % 3 ? null : `${SLUGS[i % SLUGS.length]}: ${TEXT[(i + 2) % TEXT.length].slice(0, 30)} P${1 + (i % 9)}`, ci: i % 7 ? null : pick(["CI pending", "draft"], i) })),
  errors: [], today: iso(NOW).slice(0, 10), items_from: "2026-11-04", prs_from: "2026-10-14",
};
logWork.table.pager = { page: 1, pages: Math.ceil(WORK_TOTAL / WORK_SHOWN), per: WORK_SHOWN };

// Sessions' Runners: hub_core::fleet::who, live-sized: 42 runners on 2026-11-12, a FOR up to 152
// characters and a DOING NOW up to 390, so a row that wraps shows here as it does live.
const RUNNERS = 42;
const fleet = {
  table: table(RUNNERS, ["kind", "who", "state", "cost", "since", "for", "doing", "under"], ["all", "lead", "deliver", "observe", "learn", "maintain", "held", "failed", "working", "stalled"], { kind: ["deliver", "observe"], state: ["working", "held"] }),
  who: rows(RUNNERS, (i) => ({ tier: i ? 2 : 1, kind: pick(["lead", "deliver", "observe", "maintain"], i), who: `${pick(SLUGS, i)}-${i}`, state: pick(["working", "held", "idle", "failed"], i), since: ago(20 + i * 15), cost_24h: i % 2 ? 1.2 * i : null, cost_estimated: false,
    for: pick(TEXT, i + 1), doing: i % 3 ? pick(TEXT, i) : `FAILED ${pick(TEXT, i)} why: ${pick(TEXT, i + 2)} (1 failed 24h)`, under: i % 5 ? "" : "4 sessions" })),
  hidden: 0, legend: [], at: NOW, errors: [], workers: [],
  // Log's Judges at live counts: hub_core::fleet reads the newest 30 dispatch verdicts
  // (RECENT_VERDICTS) and the answer judge's newest 200, whose question and why run long; the
  // server sends the first page of each (below).
  dispatch: {
    recent: rows(30, (i) => ({ at: iso(ago(5 + i * 9)), ts: ago(5 + i * 9), project: pick(PROJECTS, i), key: `ar-${1990 - i}`, verdict: pick(["dispatch", "skip", "failed"], i), tier: 1 + (i % 3), clear: i % 2 === 0, reason: TEXT[i % TEXT.length] })),
    counts_24h: { dispatch: 12, skip: 9, failed: 9 }, counts_7d: { dispatch: 80, skip: 51, failed: 40 }, log_24h: { started: 12, reaped: 10 }, partial: false, eval: { rules: [], prompt_sha: "" },
  },
  judge: {
    agree: 40, disagree: 5, deferred: 3, pending: 20, unscored: 2, precision: 88.9, kappa: 0.7, prompt: "", week: { live_pct: 40, coverage: 43.8, precision: 88.9 }, cells: [], eval: { rules: [], prompt_sha: "" },
    verdicts: rows(200, (i) => ({ id: `v${i}`, at: ago(4 + i * 7), project: pick(PROJECTS, i), question: `${TEXT[i % TEXT.length]}?`, type: pick(["credential_or_account", "agent_policy", "scope"], i), rule: pick(["knowledge", "policy"], i), said: pick(["passed", "answered", "would answer"], i), judge: "human", evidence: TEXT[(i + 3) % TEXT.length], reason: `${TEXT[(i + 5) % TEXT.length]}; ${TEXT[(i + 6) % TEXT.length]}`, you: pick(["pending", "a", "b"], i), score: pick(["pending", "right", "wrong"], i) })),
  },
};
{
  const d = paged({ rows: fleet.dispatch.recent, table: { shown: fleet.dispatch.recent.length, pager: null } }, "verdicts");
  const v = paged({ rows: fleet.judge.verdicts, table: table(fleet.judge.verdicts.length, ["when", "project", "type", "said", "question", "why", "you"], ["all", "answered", "would answer", "passed", "wrong"]) }, "verdicts");
  Object.assign(fleet, { dispatch_table: d.table, dispatch: { ...fleet.dispatch, recent: d.rows }, judge: { ...fleet.judge, verdicts: v.rows, table: v.table } });
}

// One runner's page, hub_core::fleet::runner at the counts its reader sends (runs, activity and
// calls at 20, an extras block's rows at 10, every conf line), sized from live inbox-triage and
// shepherd on 2026-11-15, which read 4,955 and 3,310 px at 1400x900 before the page capped them.
// `shown` is the cap agent-web sends beside them, read from its source.
const RUNNER_ROWS = Number(readFileSync(new URL("../../../.local/src/agent-web/src/fleet.rs", import.meta.url), "utf8").match(/pub const RUNNER_ROWS: usize = (\d+);/)[1]);
const ACTIVITY = ["moved 0 from the outbox, filed 0, left 0, refused 0, answered 0, asked you 0, batch 40", "2 due, none urgent, last pass 30m ago: no new pass"];
const score = (rule, i) => ({ rule, verdicts: 6 + i, errors: 0, scored: i, precision: i ? 80 + i : null, false_defer_pct: null, live: i % 2 === 0 });
const runnerPage = (name, { running, runs, older, calls, conf, rules = 0, extras = { kind: "none" } }) => ({
  at: NOW, name, shown: RUNNER_ROWS, errors: [], lane: "agent", description: TEXT[7], enabled: true, state: running ? "running" : "idle", running_since: running ? ago(480) : null, next: null,
  registry: { kind: "persistent", trigger: "always on", role: "distill", role_desc: "reads and returns data", caps: "write no, task no, bash no, mcp none", model: "claude-opus-5-5", effect: "acts", prompt: "", calls: { n_24h: calls, errors_24h: 0, cost_24h: 4.86, tokens_24h: 634602, p95_ms: 12568, prompt_sha: "", recent: [] },
    eval: rules ? { prompt_sha: "3fa1c2d", live: [], total: score("", rules), rules: rows(rules, (i) => score(pick(["proceed_or_hold", "credential_or_account", "scope", "agent_policy"], i) + (i >= 4 ? `_${i}` : ""), i)) } : null },
  conf: rows(conf, (i) => ({ key: `KEY_${i}`, value: i % 5 ? `value-${pick(SLUGS, i)}` : TEXT[i % TEXT.length] })),
  status: { detail: ACTIVITY[0], item: "unity-core-playground", next: "", project: "", state: "working", updated: String(ago(2)) },
  activity: rows(20, (i) => ({ word: pick(["NOOP", "WORKED"], i), ok: true, at: ago(2 + i * 30), text: pick(ACTIVITY, i) })),
  runs: rows(runs, (i) => ({ source: "agentctl", name, state: running && !i ? "running" : "done", ok: running && !i ? null : true, result: running && !i ? "running" : pick(["NOOP", "WORKED"], i), started: ago(480 + i * 600), finished: running && !i ? null : ago(470 + i * 600), secs: 171, detail: `inv ${(0x35a8b1da + i).toString(16)}`, log: { kind: "runner", name, out: [0, 100], err: [0, 0] }, runs: 1 })),
  runs_total: runs + older, runs_older: older, failed_total: 0,
  days: rows(14, (i) => ({ day: `11-${String(2 + i).padStart(2, "0")}`, runs: runs ? 3 + i : 0, failed: 0 })),
  calls: { day: { calls, errors: 0, tokens: 634602, cost: calls ? 4.86 : null, p50_ms: 9000 }, week: { calls: calls * 5, errors: 0, tokens: 3e6, cost: calls ? 24.3 : null, p50_ms: 9000 }, partial: false,
    recent: rows(calls, (i) => ({ id: `fac8221${i}`, at: ago(30 + i * 60), ms: 12568, ok: true, model: "claude-opus-5-5", cost: 0.73, tokens: 89929, link: `https://langfuse.example/sessions/${i}` })) },
  extras,
});
const ingest = { kind: "ingest", partial: false, counts_7d: { moved: 40, filed: 12, planned: 9, refused: 30 },
  steps: rows(10, (i) => ({ ts: iso(ago(20 + i * 5)), action: pick(["refused", "planned"], i), from: "unity-core-playground", to: "", lane: "", text: `${TEXT[i % TEXT.length]} #size/m #plan`, id: i % 2 ? `ucp-${2277 + i}` : null, why: i % 2 ? "12 plan lines" : `no open task matches '- [ ] ${TEXT[i % TEXT.length]}'`, row: null, by: "inbox-plan" })) };
// The judges' pages at their live counts: the dispatch judge's newest 10 verdicts (runner::PAGE_ROWS),
// the answer judge's 8 cells and its newest RUNNER_ROWS verdicts, cut by Judge::view and counted in `table`.
const dispatchVerdicts = { kind: "dispatch-verdicts", dispatch: { ...fleet.dispatch, recent: fleet.dispatch.recent.slice(0, 10) } };
const askJudge = { kind: "ask-judge", judge: { ...fleet.judge, verdicts: fleet.judge.verdicts.slice(0, RUNNER_ROWS),
  cells: rows(8, (i) => ({ type: pick(["credential_or_account", "agent_policy", "scope", ""], i), level: pick(["self", "repo", "fleet"], i), verdicts: 4 + i, scored: i, pending: 1, precision: i ? 66.7 : null, precision_lo: i ? 20.8 : null, precision_hi: i ? 93.9 : null, live: i % 2 === 0, audited: i, level_raised_pct: i % 3 ? 25 : null })),
  table: table(200, ["when", "project", "type", "said", "question", "why", "you"], ["all", "answered", "would answer", "passed", "wrong"]) } };
// The runner pages render.mjs measures, each `#sessions/runners/<name>`.
export const RUNNER_PAGES = {
  "inbox-triage": runnerPage("inbox-triage", { running: true, runs: 20, older: 12, calls: 20, conf: 20, extras: ingest }),
  shepherd: runnerPage("shepherd", { runs: 20, older: 1118, calls: 0, conf: 22 }),
  "dispatch-judge": runnerPage("dispatch-judge", { runs: 0, older: 0, calls: 20, conf: 19, rules: 12, extras: dispatchVerdicts }),
  "ask-judge": runnerPage("ask-judge", { runs: 0, older: 0, calls: 20, conf: 23, rules: 6, extras: askJudge }),
};

// Alerts: hub_core::alerts, the firing rows a hub_core::table view of Alert.
const alertRows = rows(6, (i) => ({ sev: pick(["high", "normal", "low"], i), what: SLUGS[i], source: pick(["sentinel", "red_now", "infra"], i), since: ago(20 + i * 45),
  project: pick(PROJECTS, i), owner: i % 2 ? "-" : `${SLUGS[i]} fixing`, state: pick(["fixing", "no owner", "error"], i), slug: i % 2 ? undefined : SLUGS[i], about: TEXT[i], place: TEXT[i + 1], action: TEXT[i + 2] || "", evidence: "" }));
// An Alertmanager rule firing in three places is one row with its alerts under it, each with its
// own description, so the row has none (alerts::am_rows).
const amPage = (i) => ({ sev: "normal", what: `CVEs in ${SLUGS[i]}`, project: "", source: "alertmanager", since: ago(90 + i), owner: "-", state: "firing", about: TEXT[i], place: `image=${SLUGS[i]}`, action: "routed to ntfy", evidence: "" });
alertRows.push({ ...amPage(0), what: "HomelabCriticalVulnerability", about: "", place: "", pages: [0, 1, 2].map(amPage) });
const alerts = {
  at: NOW, level: "red", health: [{ name: "k3s", level: "red" }, { name: "ci", level: "ok" }], components: [{ domain: "k3s", name: "nodes", level: "red" }],
  firing: alertRows, rows: alertRows,
  table: table(7, ["sev", "what", "project", "source", "since", "owner", "state"], ["all", "trip", "error", "no owner"], { sev: ["high", "normal", "low"], source: ["sentinel", "red_now", "infra"], state: ["fixing", "no owner", "error"] }),
  fixes: { open: [{ slug: SLUGS[0], red: TEXT[0], outcome: "fixing", queued: iso(ago(30)), pr: "", pr_url: "" }], settled: [], summary: "1 open" },
  history: rows(3, (i) => ({ at: ago(30 + i * 60), actor: "sentinel", verb: "tripped", text: `Sentinel: ${TEXT[i]}`, source: "agent-notify" })),
  watches: rows(4, (i) => ({ name: SLUGS[i], state: pick(["TRIP", "ERROR", "OK", "new"], i), severity: "high", since: ago(40), lastrun: ago(2), lasttrip: null, place: TEXT[i], what: "", action: "", evidence: "" })),
  counts: { firing: 7, tripped: 4, errors: 2, no_owner: 2, fixes_open: 1, fixes_settled: 0, history: 3, history_older: 0, watches: 4, watches_tripped: 1, watches_error: 1, watches_ok: 1, watches_new: 1, alertmanager: 1, alertmanager_alerts: 3 },
  strip: { firing: 7, fixes: 1, watches: 3 },
  watches_table: table(4, ["name", "state", "severity", "project", "since", "lastrun", "place"], ["all", "trip", "error", "new", "ok"], { severity: ["high"], project: PROJECTS.slice(0, 2) }),
  history_table: table(3, ["when", "actor", "verb", "prio", "source", "text"], ["all", "loud", "failed"], { actor: ["sentinel"], verb: ["tripped"] }),
  errors: [],
};

// Schedules: hub_core::schedules.
const schedules = {
  table: table(7, ["kind", "name", "state", "schedule", "next", "last", "took", "passed", "failed", "streak", "triage", "result", "repo"], ["all", "failing", "stale", "never", "off", "ok", "no-purpose"], { kind: ["runner", "timer"], state: ["failing", "ok"], repo: ["dotfiles", "homelab-config"], result: ["ok", "failed"] }),
  rows: rows(7, (i) => ({ kind: pick(["runner", "timer"], i), name: `fleet-${SLUGS[i]}`, state: pick(["ok", "failing", "stale", "off"], i), state_level: pick(["ok", "bad", "warn", "ok"], i), state_why: "", took: 30 + i * 200, ok_at: ago(14 + i * 90), fail_at: i % 2 ? ago(400) : null, every: 3600, schedule: pick(["every 5m", "daily 04:00", "hourly"], i), last: ago(14 + i * 90), result: pick(["ok", "failed", "unknown"], i), ok: i % 3 === 0, streak: 1 + i, streak_word: i % 3 ? "reds" : "greens", triage: i % 3 === 1 ? TEXT[i] : "", purpose: TEXT[i], page: "", status: TEXT[i], inside: "", before: "", after: [], open: [], runs: [] })),
  summary: "7 scheduled: 2 failing, 2 stale, 0 never ran, 1 off, 0 no purpose, CI read 4m ago", at: NOW, errors: [],
};

// Stack: hub_core::stack, five tables in one read (agent-web src/stack.rs), each paged by the server
// at its hub_core::layout PAGE_ROWS entry (pageRows).
const STACK_SKILLS = 124, STACK_HOOKS = 30, STACK_RULES = 120;
// One table as hub_core::table::page leaves it: the rows of `page`, and the pager when there is more than one.
function paged(part, section, page = 1) {
  const per = pageRows(section), pages = Math.ceil(part.rows.length / per);
  if (pages < 2) return part;
  return { table: { ...part.table, pager: { page, pages, per } }, rows: part.rows.slice((page - 1) * per, page * per) };
}
const stackAll = {
  at: NOW, runners: 52, drift_day: "2026-11-18", use_days: 30, use_window: 30, strip: { flows: 6, skills: 18, hooks: 1, rules: 28 }, errors: [],
  flows: { table: table(12, ["flow", "question", "source", "picture", "checked", "state"], ["all", "unchecked", "broken"], { state: ["ok", "unchecked"] }), rows: rows(12, (i) => ({ flow: `${pick(SLUGS, i)} flow`, question: TEXT[i % TEXT.length], source: `~/.config/agentctl/QUEUE.md#${pick(SLUGS, i)}-section`, picture: i ? "" : "~/.local/src/docs/fleet-close-flow.svg", checked: i % 2 ? [] : ["tests/unit/fleet_states_doc.bats"], state: i % 2 ? "unchecked" : "ok", why: [] })) },
  table: table(STACK_SKILLS, ["skill", "category", "repo", "calls", "runners", "drift"], ["all", "drift", "scoped", "runner"], { category: ["ops", "workstreams"], repo: ["public", "private"], drift: ["deadpath", "unused"] }),
  rows: rows(STACK_SKILLS, (i) => ({ name: `${pick(SLUGS, i)}-${i}`, category: pick(["ops", "workstreams", "monitoring"], i), description: TEXT[i % TEXT.length], repo: pick(["public", "private"], i), paths: i % 9 ? [] : ["**/*.unity"], calls: i * 7, runners: i % 4 ? [] : [`fleet-${pick(SLUGS, i)}`], drift: i % 5 ? [] : [{ kind: "deadpath", item: "~/gone", detail: "path does not exist" }] })),
  agents: { table: table(12, ["agent", "model", "tools", "repo"], ["all"], { model: ["sonnet", "inherit"] }), rows: rows(12, (i) => ({ name: `${pick(SLUGS, i)}-agent`, model: i % 2 ? "sonnet" : "", tools: "Read, Grep, Glob, Bash, WebSearch, WebFetch", repo: "public", description: TEXT[i % TEXT.length] })) },
  hooks: { table: table(STACK_HOOKS, ["harness", "event", "matcher", "script", "from", "rules"], ["all", "missing"], { harness: ["claude", "codex"], event: ["PreToolUse", "Stop"] }), rows: rows(STACK_HOOKS, (i) => ({ harness: pick(["claude", "codex"], i), event: pick(["PreToolUse", "Stop", "SessionStart"], i), matcher: i % 3 ? "Bash|Read|Edit|Write|MultiEdit" : "", script: `${pick(SLUGS, i)}.sh`, command: `~/.claude/hooks/${pick(SLUGS, i)}.sh`, from: "settings.json", found: i !== 3, rules: i % 4 ? 0 : 2, source: `~/.dotfiles/.claude/hooks/${pick(SLUGS, i)}.sh` })) },
  rules: { table: table(STACK_RULES, ["rule", "kind", "number", "confidence", "state", "source"], ["rules", "mechanisms", "all", "stale", "moved", "restates", "dead", "absent"], { kind: ["invariant", "provisional"], state: ["ok", "moved"] }), rows: rows(STACK_RULES, (i) => ({ rule: TEXT[i % TEXT.length], kind: pick(["provisional", "invariant"], i), number: String(i * 3), confidence: pick(["high", "medium", "low"], i), form: "rule", state: i % 7 ? "ok" : "moved", source: "~/.local/src/docs/standards.md", today: "", revisit: "", why: TEXT[(i + 1) % TEXT.length] })) },
  rule_files: [{ name: "agent-runtime.md", paths: [".local/bin/agentctl*", ".local/bin/fleet-*"] }, { name: "skill-corpus.md", paths: [".claude/skills/**"] }],
};
// The read with Rules on page `rp`: what /api/stack and /api/stack?rpg=N answer.
const stackPage = (rp) => {
  const skills = paged(stackAll, "skills");
  return { ...stackAll, ...skills, flows: paged(stackAll.flows, "flows"), agents: paged(stackAll.agents, "agents"), hooks: paged(stackAll.hooks, "hooks"), rules: paged(stackAll.rules, "rules", rp) };
};
const stack = stackPage(1);
// The rules the fixture holds, so a check can name the row a page starts on.
export const STACK_RULE_ROWS = stackAll.rules.rows;

// Costs: hub_core::costs, the shape costs.test.mjs pins.
const LINE_COLS = ["session", "tool", "kind", "project", "harness", "model", "runner", "title", "sessions", "calls", "tokens", "cost", "share", "landed", "redo", "reverts", "per_pr", "src"];
const line = (o) => ({ session: null, title: null, tool: null, kind: null, project: null, harness: null, model: null, runner: null, sessions: null, calls: null, tokens: null, cost: 0, share: 0, landed: null, redo: null, reverts: null, per_pr: null, src: null, ...o });
const account = (name, live, used, gone, burn, sustain) => ({ name, kind: "claude", unpaced: false, reserve: null, parent: null, state: "ok", room: { ok: true, reasons: [], headroom: 4.2, text: "room, 4 points spare" }, live, used, used_text: `${used}%`, gone, burn, sustain, over: burn / sustain, idle_at: NOW + 3600, burn_at: null, run_out: null, resets: NOW + 200000, cost_24h: 80 });
// costs::columns("model"), which is also all the server keeps of the table's columns.
const COST_CUT = ["model", "harness", "sessions", "tokens", "cost", "share", "landed", "redo", "reverts", "per_pr", "src"];
const costs = {
  at: NOW, by: "model", window: "7d", cuts: ["session", "model", "harness", "tool", "project", "runner", "kind"], windows: ["24h", "7d", "30d"],
  totals: [{ window: "7d", usd: 2204, estimated: 0, sessions: 512, days: 7, through: "2026-11-14" }, { window: "30d", usd: 8120, estimated: 0, sessions: 2040, days: 30, through: "2026-11-14" }],
  totals_note: "7d and 30d are whole nightly days to the newest snapshot; the cut table's 24h is the live file",
  fleet_cost: {
    why: null, usd: "about $859", cash: "$320", burn: "$539", as_of: NOW - 600, stale: false,
    coverage: "69% of tokens estimated: 275 of 453 sessions have no cost telemetry",
    unpriced: ["claude-sonnet-4-6: 32M tokens in 1 session not in the total, no billed sessions"],
    foot: "% is of the whole fleet's 24h cost. \"estimated\" is priced from tokens at rates fitted to measured sessions.",
  },
  direct: { usd: 1.25, unpriced: 1, note: "opencode lazer/*, nightly; other direct use unseen" },
  // hub_core::spend_history: the 30-day chart, and the picked day's sessions (the spend table).
  history: {
    why: null, head: "Nov $1,579/day vs Oct $1,102/day (+43%); 11-12 $1,312 vs 7d median $1,120 (+17%)", older: 0, missing: 1, stale: false,
    note: "est. is the share priced from tokens",
    rows: [{ kind: "month", period: "2026-11", total: "$14,210", days: 12, per_day: "$1,579", per_session: "$2.50", vs_prev: "+43%", est: "21%" }, { kind: "day", period: "11-12", total: "$1,312", days: 1, per_day: "$1,312", per_session: "$2.50", vs_prev: "+69%", est: "21%" }],
    chart: rows(7, (i) => {
      const key = `2026-11-${String(6 + i).padStart(2, "0")}`, usd = i === 2 ? null : 900 + i * 70;
      return { key, label: key.slice(5), usd, measured: usd && usd * 0.8, estimated: usd && usd * 0.2, tip: usd == null ? `${key}: no figure` : `${key}: $${usd}` };
    }),
    months: [{ key: "2026-10", label: "10", usd: 34200, measured: 27000, estimated: 7200, tip: "2026-10: $34,200" }, { key: "2026-11", label: "11", usd: 14210, measured: 11200, estimated: 3010, tip: "2026-11: $14,210" }],
  },
  // The spend table opens grouped by who, on the live day, with its total row on top.
  day: {
    day: "24h", head: "last 24h: 6 sessions, $1,140 of the day's $1,312", why: null, group: "who", cuts: ["who", "project", "harness", "account", "sessions"], live: true, has_live: true,
    in_group: "", open: null, outside: "+$172 not in a session row (helper calls and the gateway)", more: 0, shown_usd: "$0.00", rows: [], table: null, series: null,
    total: { name: "total", sessions: 6, cost: 1140, share: 87, est: 40, per_session: 190 },
    groups: [{ name: "queue items", sessions: 3, cost: 760, share: 58, est: 50, per_session: 253 }, { name: "shepherd", sessions: 2, cost: 280, share: 21, est: 0, per_session: 140 }, { name: "dream", sessions: 1, cost: 100, share: 8, est: 30, per_session: 100 }],
  },
  sources: [{ name: "token snapshot", as_of: NOW - 600, stale: false }], errors: [], columns: COST_CUT, source: "fleet-cost session rows: the live file for 24h, the nightly snapshot days for 7d and 30d", eval_days: 7, unpriced: null,
  rows: rows(6, (i) => line({ model: pick(["opus-5-5", "sonnet-4-5", "gpt-5-codex", "haiku-4-5", "lazer/qwen3-coder-next-long-model-name", "lazer/deepseek-v3-2-exp"], i), harness: pick(["claude", "codex", "opencode"], i), sessions: 120 - i * 15, tokens: 9e9 - i * 1e9, cost: 900 - i * 120, share: 0.4 - i * 0.05, landed: 0.8 - i * 0.05, redo: i, reverts: i % 2, per_pr: 5.14 + i, src: pick(["outcomes", "mixed"], i) })),
  shown_usd: 300,
  table: table(6, LINE_COLS.filter((k) => COST_CUT.includes(k)), ["all"], { model: ["opus-5-5", "gpt-5-codex"], runner: ["queue"] }),
  grafana: home.grafana, tokens: null, sections: null,
  burn: {
    at: NOW, level: "bad", head: "4.5 pts/h vs 1.4 sustainable, 3.3x OVER, 39 live, carries ~11", drip_line: "15 started in 1h, 349 in 24h", stale: false, keys: null,
    accounts: [account("alt", 9, 55, 25, 1.04, 0.36), account("bnb", 17, 7, 1, 1.97, 0.56), account("main", 13, 33, 12, 1.51, 0.45)],
    fleet: { live: 39, burn: 4.52, sustain: 1.37, over: 3.3, rate: 0.116, carries: 11 }, drip: { hour: 15, day: 349, held: "fleet-assess says HOLD" },
    pace: { on_pace: false, at_burn: [["main", NOW + 600]], idle_all_by: NOW + 3600, idle_rest_after_reset: false },
  },
};

// Releases: agent-web's releases::Shown, one row per hub_core::releases::App whose cells are
// worded from its channels (hub_core::releases), each channel keyed `project|id` uniquely.
const REL_STATUS = [["ok", "ok"], ["drift", "bad"], ["released", "warn"]];
const channel = (project, app, c) => {
  const [status, level] = pick(REL_STATUS, app + c);
  return { project, id: `rel-${app}-${c}`, channel: pick(["prod", "beta", "internal"], c), where: "cluster", implicit: false, tag: `v1.${app}.0`, label: pick(["prod", "beta", "Steam beta"], c), pinned_text: `v1.${app}.0`, live_text: `v1.${app}.0`, status, status_text: status, level, status_level: level, prev_text: `v1.${Math.max(app - 1, 0)}.9`, last_deploy_text: "2h ago by agent", deploy_level: "ok", telemetry_text: "2/2", watch_level: "ok", deps_text: "", deps: [], pinned: { value: `v1.${app}.0`, source: "tag", error: null, image: null }, live: { value: `v1.${app}.0`, source: "cluster", error: null, image: null }, deploys: { source: REPOS[0], error: null, history: [], prev: null, last: null }, telemetry: [], drift_since: null, probed_at: NOW - 600 };
};
const LEVEL_RANK = ["ok", "warn", "bad"];
function app(i) {
  const project = pick(PROJECTS, i), channels = rows(2 + i % 2, (c) => channel(project, i, c));
  const worst = channels.reduce((w, c) => (LEVEL_RANK.indexOf(c.level) > LEVEL_RANK.indexOf(w.level) ? c : w));
  const counts = REL_STATUS.map(([s]) => [s, channels.filter((c) => c.status === s).length]).filter(([, n]) => n);
  return { project, stage: pick(["draft", "alpha", "beta", "prod"], i), stage_text: "alpha: no alpha target deployed", stage_level: pick(["ok", "warn"], i), status: worst.status, status_text: worst.status_text, level: worst.level, checks: pick([{ says: "Operational", level: "ok" }, { says: "Partial outage: api", level: "bad" }, { says: "no check", level: "ok" }], i), live_text: `v1.${i}.0 prod`, channels_text: `${counts.map(([s, n]) => `${n} ${s}`).join(", ")}`, unread: 0, released_text: `v1.${i}.0 3h ago`, last_deploy_text: "2h ago by agent", deploy_level: "ok", channels, lead: 1, others_text: channels.slice(1).map((c) => `${c.channel} 1 ${c.status}`).join("; ") };
}
const releases = {
  table: table(6, ["project", "stage", "live", "status", "checks", "channels", "released", "last_deploy", "channel", "id"], ["all", "attention", "ok"], { project: PROJECTS.slice(0, 3), stage: ["draft", "alpha"], status: ["ok", "drift"] }),
  rows: rows(6, app), blanks: ["not recorded", "none declared", "no check"],
  question: "", summary: `6 apps: ${REL_STATUS.map(([s]) => [s, rows(6, app).filter((a) => a.status === s).length]).filter(([, n]) => n).map(([s, n]) => `${n} ${s}`).join(", ")}`, gaps: "", look: true, at: NOW, stale_after: 3600, errors: [],
};
const builds = {
  table: table(6, ["started", "state", "repo", "workflow", "branch", "took", "usual", "eta", "owner", "release", "forge", "event", "title", "id", "pr"], ["all", "running", "queued", "red", "green"], { repo: REPOS.slice(0, 2), forge: ["github"], event: ["push", "pull_request"], state: ["green", "red"] }),
  rows: rows(6, (i) => ({ forge: "github", repo: pick(REPOS, i), id: 9000 + i, attempt: 1, started: ago(20 + i * 30), state: pick(["running", "green", "red"], i), level: pick(["warn", "ok", "bad"], i), workflow: "ci", branch: `feat/${SLUGS[i]}`, took: 300 + i * 60, usual: { median: 280 + i * 30, p90: 520 + i * 40 }, eta: pick([NOW + 240, null, null], i), owner: "agent", release: i === 1 ? { project: PROJECTS[1], tag: "v1.1.0" } : null, event: pick(["push", "pull_request"], i), title: TEXT[i], url: "https://github.com/Kblack0610/.dotfiles/actions/runs/1", prs: [] })),
  more: 0, summary: "6 builds, 1 red", at: NOW, stale_after: 3600, errors: [],
  counts: { total: 6, running: 2, queued: 0, red: 2, recent_red: 2 }, look: true,
};
// Releases > Flow: hub_core::lanes::Flow over a 7d window; `keys` and `windows` copy lanes.rs KEYS
// and WINDOWS, which a change there must follow.
const LANE_KEYS = ["green", "red", "running", "queued", "other"];
const seg = (i, key, a, b) => ({ a, b, key, title: `${key} ${TEXT[i % TEXT.length].slice(0, 40)}`, link: "#infra/runs", n: 1 + (i % 3) });
const flowLane = (label, sub, n, keyOf) => ({ label, sub, segs: rows(n, (i) => { const a = NOW - 7 * 86400 + Math.round(((i + 0.5) * 7 * 86400) / n); return seg(i, keyOf(i), a, a + 1200); }) });
const lanes = {
  project: PROJECTS[0], window: "7d", keep_days: 30, clipped: "", t0: NOW - 7 * 86400, t1: NOW,
  projects: [...new Set(PROJECTS)].sort(), windows: ["24h", "7d", "30d"],
  keys: [["red", "failed"], ["running", "running"], ["queued", "queued"], ["reached", "reached the channel"], ["tag", "tagged"], ["green", "passed"], ["other", "cancelled or skipped"]],
  ci: rows(6, (i) => flowLane(pick(["tests", "lint", "rust", "release", "nightly", "other workflows"], i), `${8 + i} runs, ${i % 3} red`, 8 + i, (j) => pick(LANE_KEYS, i + j))),
  release: [flowLane("agent-web", "", 3, (j) => pick(["tag", "green", "reached"], j)), flowLane("agent-web", "beta", 2, () => "reached")],
  ci_empty: "", release_empty: "", errors: [],
};
// Pipelines: hub_core::pipelines rows, one per workflow of each repo.
const PIPE_STATE = ["red", "amber", "ok", "off"];
const pipeline = (i) => ({ state: pick(PIPE_STATE, i), why: `${pick(["last run on main failed", "late for its 02:00 start", "last run on main passed", "held from the night"], i)} 11-11 22:04`, forge: "github", repo: pick(REPOS, i), project: pick(PROJECTS, i), pipeline: pick(["Tests (all)", "Multi (all)", "Checks", "Vuln scan", "Nightly build", "Release"], i), file: `.github/workflows/${pick(["test", "multi", "checks", "vuln-scan", "nightly", "release"], i)}.yml`, trigger: pick(["dispatch, cron", "pr, push", "cron"], i), nightly: pick(["on", "held", ""], i), schedule: pick(["02:00 daily", "09:00 Mon", ""], i), next: i % 3 === 2 ? null : NOW + 3600 * (i + 1), runner: i % 3 === 0 ? "playground-night" : null, last: ago(60 + i * 200), last_id: 42000 + i, last_result: pick(["failure", "success"], i), pass: 40 + i * 10, runs: 12 + i, usual: 1500 + i * 60, p90: 2400 + i * 60, running: i % 2 });
const pipelines = {
  at: NOW, summary: "6 pipelines in 5 repos, 2 red, 1 held from the night", red: 2, errors: [],
  rows: rows(6, pipeline),
  table: { ...table(6, ["state", "repo", "pipeline", "file", "trigger", "nightly", "schedule", "next", "last", "pass", "runs", "usual", "p90", "running"], ["all", "red", "amber", "ok", "off"], { repo: PROJECTS.slice(0, 5), trigger: ["dispatch", "cron", "pr"], nightly: ["on", "held"] }), links: [] },
};
// Tests: hub_core::junit's suites of the picked run of one repo's test workflow, and the quarantine.
const testRun = (id, o = {}) => ({ repo: "studio/game-core-playground", id, attempt: 1, branch: "main", sha: "abc1234", title: TEXT[4], state: "red", level: "bad", started: ago(90), prs: [], url: "https://github.com/studio/game-core-playground/actions/runs/1", ...o });
const suite = (i) => ({ tier: pick(["EditMode", "PlayMode"], i), suite: `Game.Core.${pick(["Lobby", "HostMigration", "Inventory", "Yard"], i)}Tests`, tests: 40 + i, passed: 38 + i - (i % 2), failed: i % 2, quarantined: 0, skipped: 1, time: 60 + i * 12.5, state: i % 2 ? "failed" : "passed", level: i % 2 ? "bad" : "ok" });
const tests = {
  at: NOW, stale_after: 1800, repos: ["studio/game-core-playground", "Kblack0610/.dotfiles"], repo: "studio/game-core-playground",
  runs: [testRun(43001), testRun(43000, { state: "green", level: "ok", branch: "feat/yard" })], run: testRun(43001),
  summary: "main abc1234: 166 tests in 4 suites: 2 failed, 4 skipped, 160 passed", totals: { suites: 4, tests: 166, passed: 160, failed: 2, skipped: 4, failed_suites: 2, time: 315 },
  rows: rows(4, suite), more: 0, fold: null, note: null, errors: [],
  table: table(4, ["state", "tier", "suite", "tests", "failed", "quarantined", "skipped", "time"], ["all", "failed", "quarantined", "skipped", "passed"], { tier: ["EditMode", "PlayMode"] }),
};

// /api/home/cards: Needs you, then hub_core::cards::grid (Main red is the widgets' only; cards.rs PAGE_SKIPS), one card per tab, a link as its href.
const kcard = (tab, title, big, unit, level, bar, parts, first = [], { first_head = "Where to look first", ...o } = {}) => ({ tab, title, big, unit, level,
  bar: bar.map(([l, n]) => ({ level: l, n })), parts: parts.map(([label, value, l = "ok"]) => ({ label, value, level: l })),
  lists: [{ head: first_head, rows: first.map(([text, sub, l = "warn"]) => ({ text, sub, level: l, link: null })) }],
  counted: `counted by the ${title} tab`, error: null, link: `#${tab}`, ...o });
const GRID_CARDS = [
  kcard("needs", "Needs you", "5", "waiting on you", "warn", [["warn", 5]], [["Asks", "3", "warn"], ["Sessions", "1", "warn"], ["Queue", "1", "warn"]],
    [["Which model should settings.json pin for every account, opus or opus[1m]?", "2d dotfiles", "warn"], ["agent-web review", "3h dotfiles", "warn"]], { first_head: "Oldest" }),
  kcard("red", "Main red", "2", "repos red on main", "red", [["red", 2]], [], [["unity-core-playground", "nightly", "red"], ["trader", "nightly", "red"]], { first_head: "Red" }),
  kcard("sessions", "Sessions", "39", "live sessions", "warn", [["ok", 34], ["warn", 3], ["red", 2]], [["Working", "34"], ["Need you", "3", "warn"], ["Stalled", "2", "red"]], [["trader-x", "stalled 3h", "red"], ["binks", "ask 40m"]]),
  kcard("board", "Board", "4115", "open rows, 277 doing", "red", [["ok", 3882], ["warn", 232], ["red", 1]], [["Doing", "277"], ["Requested", "232", "warn"], ["Late", "1", "red"]], [["submit Shape City", "shape-city - backlog, due 11-17", "red"], ["one tag table for intake lines", "agent-runtime - next up"]]),
  kcard("queue", "Queue", "12", "queued, 7 running", "warn", [["ok", 7], ["warn", 5]], [["Ready", "9"], ["Held", "3", "warn"], ["Done 24h", "41"]], [["review", "5 waiting 2h"]], { first_head: "Bottleneck" }),
  kcard("alerts", "Alerts", "3", "firing", "red", [["red", 1], ["warn", 2]], [["Red", "1", "red"], ["Amber", "2", "warn"], ["Owned", "1"]], [["gateway 5xx", "home-k3s", "red"], ["board-chain", "stale 2h"]]),
  kcard("done", "Done today", "85", "PRs merged", "ok", [], [["Shipped", "62"], ["Checks", "9"]], [["unity-core-playground", "30 shipped, 2 checks, 25 PRs", "ok"], ["dotfiles", "21 shipped, 40 PRs", "ok"]], { first_head: "By project", link: "#queue" }),
  kcard("health", "Health", "11 of 12", "machines up", "red", [["ok", 11], ["red", 1]], [["Domains down", "0"], ["Domains warn", "1", "warn"], ["Domains up", "6"], ["Vitals", "5/6", "warn"]], [["mac-mini", "down 2h", "red"]], { link: "#infra" }),
  kcard("ci", "CI", "4", "CI running", "red", [["ok", 5], ["red", 1]], [["Queued", "1"], ["Runners up", "5/6", "red"], ["No runner", "0"], ["Stuck", "0"]], [["runner-3 down", "CI runner", "red"], ["app CI", "oldest queued, 4m x1"]], { link: "#ci" }),
  kcard("costs", "Costs", "$412", "Claude in 24h", "ok", [["ok", 3]], [["5h left", "62%"], ["Week", "41%"], ["Est.", "18%"]], [["agent-runtime", "$210", "ok"]]),
  kcard("releases", "Releases", "6", "apps", "warn", [["ok", 5], ["warn", 1]], [["Draft", "1", "warn"], ["Failed", "0"], ["Pinned", "2"]], [["binks", "draft gate"]]),
  kcard("schedules", "Schedules", "41", "scheduled", "ok", [["ok", 39], ["warn", 2]], [["Failing", "2", "warn"], ["Streak", "1"]], []),
  kcard("projects", "Projects", "-", "no data", "nodata", [], [], [], { error: "lab: unreadable" }),
];

// The one order every surface draws (hub_core::cards::ORDER), read from hub-core so a change there
// moves the fixture too.
const CARDS_RS = readFileSync(new URL("../../../.local/src/hub-core/src/cards.rs", import.meta.url), "utf8");
const ids = (name) => [...CARDS_RS.match(new RegExp(`pub const ${name}: &\\[&str\\] = &\\[([^\\]]*)\\]`))[1].matchAll(/"(\w+)"/g)].map((m) => m[1]);
const byTab = (tab) => GRID_CARDS.find((c) => c.tab === tab) ?? (() => { throw new Error(`hub_core::cards has a card "${tab}" that fixtures.mjs GRID_CARDS lacks`); })();
export const CARD_ORDER = ids("ORDER");
const homeCards = CARD_ORDER.filter((t) => t !== "red").map(byTab);
export const FIXTURES = {
  "/api/agents": [], "/api/asks/parked": [], "/api/home/waiting": { count: home.needs.length, sessions: 0, href: "#home" }, "/api/session-options": { describe: {}, accounts: [] },
  "/api/home": home, "/api/home/cards": homeCards, "/api/briefing": briefing, "/api/home/proposals": { proposals: home.proposals, proposals_head: home.proposals_head, proposals_table: home.proposals_table, proposals_failed: false },
  "/api/queue": queue, "/api/queue/stats": queueStats, "/api/flow": flow, "/api/queue/candidates": candidates, "/api/queue/candidates?counts=1": candCounts, "/api/queue/projects": PROJECTS.slice(0, 5),
  "/api/projects": projects, "/api/deliverables": deliverables, "/api/coverage": coverage, "/api/stages": stages, "/api/stages/requirements": stageReqs, "/api/board": board, "/api/sprints": sprints, [`/api/projects/${BIG_PROJECT.name}/page`]: bigPage,
  "/api/sessions/table": sessions, "/api/sessions/capacity": capacity, "/api/watch": watch, "/api/shepherd": shepherd, "/api/outcomes": [],
  "/api/alerts": alerts, "/api/infra": infra, "/api/jobs": jobs,
  "/api/log": log, "/api/log/work": logWork, "/api/log/history": logHistory, "/api/actions": actions,
  "/api/fleet": fleet, "/api/schedules": schedules, "/api/stack": stack, "/api/stack?rpg=2": stackPage(2), "/api/costs": costs, "/api/releases": releases, "/api/releases/lanes": lanes, "/api/builds": builds,
  "/api/pipelines": pipelines, "/api/tests": tests,
  ...Object.fromEntries(Object.entries(RUNNER_PAGES).map(([name, r]) => [`/api/fleet/runner?name=${name}`, r])),
};
