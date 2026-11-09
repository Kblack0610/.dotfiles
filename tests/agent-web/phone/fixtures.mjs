// What the phone render harness answers for /api/*: one payload per endpoint, keyed by path.
// Shapes are the ones the page reads (see the sibling tests/agent-web/*.test.mjs), column, state
// and facet keys are the COLUMNS, STATES and FACETS of the hub-core row they name.
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
  return { key, on: null, clear: "", values: values.map((value, i) => ({ value, n: values.length - i, q: `${key}:${value}` })) };
}
// A hub_core::table Summary as it serializes; the first state chip keeps every row.
function table(n, columns, states = ["all"], facets = {}) {
  return {
    q: "", state: states[0], sort: "", dir: "desc", total: n, shown: n,
    states: states.map((name, i) => ({ name, n: i ? Math.max(1, n - i) : n })),
    columns: columns.map(col),
    facets: Object.entries(facets).map(([k, v]) => facet(k, v)),
  };
}
const rows = (n, f) => Array.from({ length: n }, (_, i) => f(i));

// Home: hub_core::home needs, proposals.
const NEED = ["plan", "ask", "perm", "turn", "blocked", "red"];
const home = {
  errors: [], shown: 6, grafana: "https://grafana.example/d/kb-command-center", sessions: "39 live, 3 need you, 2 stalled", spend: "$412 today",
  health: [{ name: "dispatch", level: "ok" }, { name: "shepherd", level: "warn" }, { name: "sentinel", level: "ok" }],
  flow: { chips: [{ key: "running", label: "running", value: "7", hot: false, to: { tab: "queue", state: "running" } }, { key: "needs", label: "needs you", value: "3", hot: true, to: { tab: "queue", state: "needs you" } }, { key: "ready", label: "ready", value: "12", hot: false, to: { tab: "queue", state: "up next" } }], bottleneck: "review is the slowest stage this week at 41 minutes per PR", error: null, as_of: "13:20", absent: [] },
  vitals: null,
  running: rows(2, (i) => ({ project: pick(PROJECTS, i), title: TEXT[i], slug: SLUGS[i], started: iso(ago(40 + i * 10)), phases: { done: 1 + i, total: 4, next: "wire the renderer", eta: "20m", eta_epoch: NOW + 1200 } })),
  table: table(6, ["rank", "kind", "project", "waited", "holds", "what"], ["all", "Plan to approve", "Question", "Permission", "Your turn", "Blocked", "To do", "Failing", "Stopped"], { project: PROJECTS.slice(0, 3) }),
  needs: rows(6, (i) => ({ kind: i % 2 ? "ask" : "session", id: `need-${i}`, need: pick(NEED, i), rank: i + 1, project: pick(PROJECTS, i), since: ago(25 + i * 37), score: { holds: 3 - (i % 3), priority: i % 2 ? "high" : "normal" }, text: TEXT[i], target: `agent-${i}` })),
  proposals: rows(5, (i) => ({ id: `prop-${i}`, stream: pick(["dream", "skill-refine", "sentinel"], i), project: pick(PROJECTS, i), title: TEXT[i + 2], created: iso(ago(120 + i * 60)), error: null, why: TEXT[i], evidence: "", does: "queue", expires: null, verb: "queue" })),
  proposals_head: "5 from 3 streams", proposals_failed: false,
  proposals_table: table(5, ["stream", "project", "proposal", "created", "verb"], ["all", "queue", "row", "mem0", "none"], { stream: ["dream", "skill-refine"], project: PROJECTS.slice(0, 2) }),
};
const briefing = {
  since: iso(ago(600)), since_label: "since last night", errors: [], ok_line: "4 more lanes green",
  rows: rows(3, (i) => ({ name: pick(["dispatch", "ci", "spend"], i), link: "", level: pick(["warn", "bad", "ok"], i), line: TEXT[i + 3], details: [], fix: null })),
};

// Queue: hub_core::queue.
const QUEUE_STATE = ["running", "waiting", "queued", "queued", "running", "done", "done"];
const queue = {
  items: rows(7, (i) => ({ slug: SLUGS[i], title: TEXT[i], project: pick(PROJECTS, i), state: QUEUE_STATE[i], status: "ok", hold: i === 3 ? "fleet-assess HOLD" : "", type: pick(["fix", "feat", "chore"], i), size: pick(["s", "m", "l"], i), account: pick(["main", "bnb", "alt"], i), pr: i > 3 ? `#${1590 + i}` : "", pr_label: i > 3 ? `#${1590 + i}` : "", pr_url: i > 3 ? `https://github.com/Kblack0610/.dotfiles/pull/${1590 + i}` : "", pr_merged: i > 4, note: "", unproven: false, timing: { in_state: 14 + i * 9, wait: 3 + i, run: 22 + i * 6 } })),
  table: table(7, ["state", "in", "wait", "run", "project", "kind", "size", "acct", "pr", "title"], ["all", "needs you", "running", "up next", "done"], { project: PROJECTS.slice(0, 3), kind: ["fix", "feat"], size: ["s", "m"], acct: ["main", "bnb"] }),
  section_aliases: {}, needs_you: 1, open_rows: 40,
};
const queueStats = { week: 212, sitting: 9, wait_minutes_median: 7, run_minutes_median: 38, to_pr_minutes_median: 52 };
const flow = { flow: home.flow, grafana: home.grafana };
const candidates = { rows: [], blocked_rows: [], total: 0, auto: 0, urgent_blocked: 0, clear: true, reasons: [], uncovered: [] };

// Projects: hub_core::projects.
const projects = {
  table: table(6, ["project", "profile", "stage", "version", "prio", "open", "doing", "hot", "done", "7d", "pct", "pace", "eta", "run", "wait", "queued", "held", "today", "oldest"], ["all", "in flight", "waiting"], { profile: ["personal", "bnb"], stage: ["alpha", "beta"] }),
  cards: rows(6, (i) => ({ name: `${pick(PROJECTS, i)}${i === 5 ? "-web" : ""}`, profile: pick(["personal", "bnb", "gigantic"], i), stage: pick(["alpha", "beta", "live"], i), version: `0.${i}.${i + 2}`, prio: i + 1, progress: { open: 40 - i * 4, done: 60 + i * 3, closed_7d: 11 - i }, doing: 2 + i % 2, hot: i % 3, percent: 60 - i * 5, pace: 1.4 + i / 10, eta_days: 12 + i * 5, running: [], waiting: i % 2, queued: 4 - i % 3, held: i % 2, done_today: 3 - i % 3, oldest: iso(ago(4000 + i * 1000)), summary: TEXT[i], goal: TEXT[i + 1], counts: { open: 40 - i * 4 }, note_says: "", status: "ok" })),
  unlinked: [], errors: [],
};

// Board: hub_core::tasks.
const board = {
  table: table(8, ["priority", "project", "lane", "state", "id", "version", "size", "tier", "since", "text", "profile", "tag"], ["all", "in progress", "filed today", "urgent", "requested"], { project: PROJECTS.slice(0, 3), lane: ["agent", "human"], priority: ["high", "normal"] }),
  rows: rows(8, (i) => ({ sheet: `~/.notes/lab/projects/current/${pick(PROJECTS, i)}/tasks.md`, raw: `- [ ] ${TEXT[i]}`, id: `ar-${1100 + i}`, priority: pick(["high", "normal", "low"], i), project: pick(PROJECTS, i), lane: pick(["agent", "human"], i), state: pick(["todo", "doing"], i), version: "0.2", game: "", size: pick(["s", "m"], i), tier: "", since: iso(ago(2000 + i * 300)), text: TEXT[i], tags: ["requested"], worker: i % 3 ? "" : `agent-${i}`, ask: "" })),
  projects: PROJECTS.slice(0, 5).map((project) => ({ profile: "personal", project, inbox: 2 })),
  focus: [{ profile: "personal", open: 12 }],
};

// Sessions: hub_core::session_table.
const BUCKET = ["WORKING", "STALLED", "NEEDS", "WORKING", "LANDED", "DONE"];
const sessions = {
  table: table(6, ["bucket", "activity", "project", "task", "pr", "phases", "idle", "cost", "acct", "harness", "item", "source", "session"], ["all", "running", "needs you", "stalled", "done today"], { project: PROJECTS.slice(0, 3), harness: ["claude", "codex"] }),
  rows: rows(6, (i) => ({ key: `s-${i}`, target: `agent-${i}`, session_id: `0000000${i}-aaaa-bbbb-cccc-000000000000`, bucket: BUCKET[i], activity: pick(["editing", "gate", "review"], i), project: pick(PROJECTS, i), task: TEXT[i], pr: i > 2 ? `#${1590 + i}` : "", pr_state: i > 2 ? "open" : "", ci: i > 2 ? "green" : "", phases_done: i, phases_total: 5, idle_min: 2 + i * 6, ended: null, cost_usd: 1.5 + i * 2.25, account: pick(["main", "bnb", "alt"], i), harness: pick(["claude", "codex"], i), source: pick(["queue", "hand"], i) })),
  spend_usd: 41.5, buckets: ["NEEDS", "STALLED", "WORKING", "LANDED", "DONE"], errors: [],
};
const capacity = { parts: [{ text: "39 live", warn: false, start: "", confirm: "" }, { text: "2 slots free", warn: true, start: "", confirm: "" }], unlinked: 0, live: 39, errors: [] };
const watch = { state: { sessions: [], vocab: { buckets: sessions.buckets }, generated_at: iso(NOW) }, transitions: [] };
const shepherd = { target: "", status: "", stats: null, ledger: { due: [], lease_at: null, lease_holder: "" }, rundowns: [] };

// Infra: Prometheus instant vectors, and the jobs board from hub_core::jobs.
const runner = (i) => ({ labels: { name: `runner-${i}`, host: pick(["asus-laptop", "mac-mini", "workstation"], i), site: "home", state: "busy", pool: pick(["unity", "default"], i), repo: "game-core-playground", pr: `${1700 + i}`, job_name: "Tests (EditMode)", title: TEXT[i], workflow: "ci", branch: `feat/${SLUGS[i]}` }, value: 600 + i * 120 });
const infra = {
  ok: true, at: NOW, grafana: home.grafana, down: [],
  instant: { cc: [{ labels: { __name__: "cc:overall_status" }, value: 0 }, { labels: { __name__: "cc:asks_open" }, value: 2 }], red: [], runners: rows(4, runner), waiting: [], gates: [], finished: [], hourly: [], local_hourly: [], failed: [], local_failed: [], recent: [], recent_dur: [], power: [], governor: [], cores: [], runner_cores: [], withheld: [] },
};
const reds = { open: [{ slug: SLUGS[0], red: TEXT[0], outcome: "", queued: iso(ago(30)), pr: "", pr_url: "" }], settled: [], summary: "1 open" };
const jobs = {
  table: table(7, ["state", "source", "name", "started", "took", "result", "detail"], ["all", "running", "queued", "done", "failed"], { source: ["forgejo", "github", "local"], result: ["ok", "failed"] }),
  jobs: rows(7, (i) => ({ state: pick(["running", "done", "failed"], i), source: pick(["forgejo", "github", "local"], i), name: `Tests (EditMode) ${SLUGS[i]}`, started: ago(10 + i * 11), finished: i % 3 ? ago(i * 3) : null, secs: 240 + i * 90, result: pick(["", "ok", "failed"], i), ok: i % 3 === 1, runs: 1, next: null, url: "https://github.com/Kblack0610/.dotfiles/actions/runs/1", log: null, detail: TEXT[i] })),
  window_secs: 86400, at: NOW, ci: { level: "ok", says: "CI green" }, errors: [],
};

// Log: the day, and the actions table from hub_core::actions.
const log = {
  date: "2026-11-05", live: true, gathered_at: iso(NOW),
  merged: rows(6, (i) => ({ repo: pick(REPOS, i), project: pick(PROJECTS, i), number: 1580 + i, url: "https://github.com/Kblack0610/.dotfiles/pull/1", title: TEXT[i], merged_at: iso(ago(30 + i * 40)), area: pick(["agent-web", "hub", "ci"], i), group: pick(["agent-web", "hub", "ci"], i), scope: pick(["agent-web", "hub"], i), by: "agent" })),
  open: rows(3, (i) => ({ repo: pick(REPOS, i), project: pick(PROJECTS, i), number: 1600 + i, url: "https://github.com/Kblack0610/.dotfiles/pull/2", title: TEXT[i + 2], created_at: iso(ago(90)), draft: false, ci: "green", by: "agent" })),
  projects: [], hours: { hours: [], rows: [] }, usage: [{ project: "TOTAL", sessions: 42 }], waiting: { main: [], needs: [], asks: [] },
  bench: { headline: "212 merged this week, 52% first try", sessions: rows(3, (i) => ({ target: `agent-${i}`, plan: SLUGS[i], phase: "2/4", working_h: 1.5, waiting_h: 0.2, stalled_h: 0, prs_merged: 2, ci_reds: 1, peak_k: 310, cost_usd: 12.5 })) },
  timeline: [], unreadable: [],
};
const logHistory = rows(5, (i) => ({ date: `2026-11-0${5 - i}`, merged: 40 - i * 3, repos: 4, areas: { "agent-web": 9, hub: 7 } }));
const actions = {
  table: table(7, ["when", "actor", "verb", "prio", "source", "text"], ["all", "loud", "failed"], { actor: ["shepherd", "dispatch", "sentinel"], verb: ["page", "nudge", "start"] }),
  actions: rows(7, (i) => ({ at: ago(5 + i * 13), actor: pick(["shepherd", "dispatch", "sentinel"], i), verb: pick(["page", "nudge", "start"], i), priority: pick(["high", "normal"], i), source: pick(["fleet-lead", "cron"], i), text: TEXT[i] })),
  counts: { actor: { shepherd: 3, dispatch: 2, sentinel: 2 }, verb: { page: 3, nudge: 2, start: 2 } }, errors: [],
};

// Log's Work table: hub_core::worklog.
const logWork = {
  table: table(8, ["state", "when", "project", "what", "kind", "pr", "cost"], ["all", "done", "active", "waiting", "queued", "failed", "cancelled"], { project: PROJECTS.slice(0, 5), kind: ["fix", "feat", "chore"] }),
  rows: rows(8, (i) => ({ state: pick(["failed", "waiting", "active", "done", "done", "queued"], i), when: iso(ago(30 + i * 90)).slice(0, 16), project: pick(PROJECTS, i), what: TEXT[i], kind: pick(["fix", "feat", "chore"], i), pr: `.dotfiles#${1580 + i}`, url: "https://github.com/Kblack0610/.dotfiles/pull/1", cost: 1.25 * i, slug: SLUGS[i % SLUGS.length], unproven: false })),
  more: 12, errors: [], today: iso(NOW).slice(0, 10), items_from: "2026-11-04", prs_from: "2026-10-14",
};

// Fleet: hub_core::fleet::who.
const fleet = {
  table: table(6, ["kind", "who", "state", "cost", "activity", "since", "for", "doing", "under", "project"], ["all", "lead", "deliver", "observe", "learn", "maintain", "session", "held", "failed", "working", "needs you", "stalled"], { kind: ["deliver", "observe"], state: ["working", "held"], project: PROJECTS.slice(0, 2) }),
  who: rows(6, (i) => ({ key: `who-${i}`, kind: pick(["lead", "deliver", "observe", "maintain"], i), who: `fleet-${SLUGS[i]}`, state: pick(["working", "held", "needs you"], i), activity: pick(["editing", "reading", "gate"], i), since: ago(20 + i * 15), for: `${20 + i * 15}m`, doing: TEXT[i], under: "", project: pick(PROJECTS, i), opens: "", kids: 0 })),
  hidden: 0, legend: [], at: NOW, errors: [], workers: [],
  dispatch: { recent: [], eval: { rules: [], prompt_sha: "" } }, judge: { prompt: "", verdicts: [], eval: { rules: [], prompt_sha: "" } },
};

// Schedules: hub_core::schedules.
const schedules = {
  table: table(7, ["kind", "name", "schedule", "last", "result", "streak", "triage", "repo", "next"], ["all", "red", "ok", "unknown", "no-purpose"], { kind: ["runner", "timer"], repo: ["dotfiles", "homelab-config"], result: ["ok", "failed"] }),
  rows: rows(7, (i) => ({ kind: pick(["runner", "timer"], i), name: `fleet-${SLUGS[i]}`, schedule: pick(["every 5m", "daily 04:00", "hourly"], i), last: ago(14 + i * 90), result: pick(["ok", "failed", "unknown"], i), ok: i % 3 === 0, streak: 1 + i, streak_word: i % 3 ? "reds" : "greens", triage: i % 3 === 1 ? TEXT[i] : "", purpose: TEXT[i], page: "", status: TEXT[i], inside: "", before: "", after: [], open: [], runs: [] })),
  summary: "7 schedules, 2 red", at: NOW, errors: [],
};

// Costs: hub_core::costs, the shape costs.test.mjs pins.
const LINE_COLS = ["session", "tool", "kind", "project", "harness", "model", "runner", "title", "sessions", "calls", "tokens", "cost", "share", "landed", "redo", "reverts", "per_pr", "src", "pr", "at"];
const line = (o) => ({ session: null, title: null, tool: null, kind: null, project: null, harness: null, model: null, runner: null, sessions: null, calls: null, tokens: null, cost: 0, share: 0, landed: null, redo: null, reverts: null, per_pr: null, src: null, pr: null, at: null, ...o });
const account = (name, live, used, gone, burn, sustain) => ({ name, kind: "claude", unpaced: false, reserve: null, parent: null, state: "ok", room: { ok: true, reasons: [], headroom: 4.2, text: "room, 4 points spare" }, live, used, used_text: `${used}%`, gone, burn, sustain, over: burn / sustain, idle_at: NOW + 3600, burn_at: null, run_out: null, resets: NOW + 200000, cost_24h: 80 });
// costs::columns("model"), which is also all the server keeps of the table's columns.
const COST_CUT = ["model", "harness", "sessions", "tokens", "cost", "share", "landed", "redo", "reverts", "per_pr", "src"];
const costs = {
  at: NOW, by: "model", window: "7d", cuts: ["session", "model", "harness", "tool", "project", "runner", "kind"], windows: ["24h", "7d", "30d"],
  totals: [{ window: "24h", usd: 412.5, sessions: 73, unpriced: 0 }, { window: "7d", usd: 2204, sessions: 512, unpriced: 2 }, { window: "30d", usd: 8120, sessions: 2040, unpriced: 2 }],
  live: { claude_24h: 311 }, direct: { usd: 1.25, unpriced: 1, note: "opencode lazer/*, nightly; other direct use unseen" },
  sources: [{ name: "outcomes", as_of: NOW - 600, stale: false }], errors: [], columns: COST_CUT, source: "outcomes rows", eval_days: 7, unpriced: null,
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

// Releases: hub_core::releases and builds.
const releases = {
  table: table(6, ["project", "channel", "pinned", "live", "status", "prev", "last_deploy", "telemetry", "deps", "id", "where"], ["all", "attention", "green"], { project: PROJECTS.slice(0, 3), status: ["green", "behind"] }),
  rows: rows(6, (i) => ({ project: pick(PROJECTS, i), id: `rel-${i}`, label: pick(["prod", "beta", "Steam beta"], i), pinned_text: `v1.${i}.0 (${SLUGS[i]})`, live_text: `v1.${i}.0`, status: TEXT[i], status_level: pick(["ok", "warn", "bad"], i), prev_text: `v1.${i - 1 < 0 ? 0 : i - 1}.9`, last_deploy_text: "2h ago by agent", deploy_level: "ok", telemetry_text: "0 crashes in 24h, 41 sessions", watch_level: "ok", deps_text: "", deps: [], pinned: { source: "tag" }, live: { source: "cluster" }, deploys: { history: [] }, telemetry: [] })),
  fold: false, question: "", summary: "6 releases, 2 need attention", at: NOW, stale_after: 3600, errors: [],
};
const builds = {
  table: table(6, ["started", "state", "repo", "workflow", "branch", "took", "owner", "forge", "event", "title"], ["all", "running", "queued", "red", "green"], { repo: REPOS.slice(0, 2), forge: ["github"], event: ["push", "pull_request"], state: ["green", "red"] }),
  rows: rows(6, (i) => ({ forge: "github", repo: pick(REPOS, i), id: 9000 + i, attempt: 1, started: ago(20 + i * 30), state: pick(["running", "green", "red"], i), level: pick(["warn", "ok", "bad"], i), workflow: "ci", branch: `feat/${SLUGS[i]}`, took: 300 + i * 60, owner: "agent", event: pick(["push", "pull_request"], i), title: TEXT[i], url: "https://github.com/Kblack0610/.dotfiles/actions/runs/1", prs: [] })),
  more: 0, summary: "6 builds, 1 red", at: NOW, stale_after: 3600, errors: [],
};

export const FIXTURES = {
  "/api/agents": [], "/api/asks": [], "/api/session-options": { describe: {}, accounts: [] },
  "/api/home": home, "/api/briefing": briefing, "/api/home/proposals": { proposals: home.proposals, proposals_head: home.proposals_head, proposals_table: home.proposals_table, proposals_failed: false },
  "/api/queue": queue, "/api/queue/stats": queueStats, "/api/flow": flow, "/api/queue/candidates": candidates, "/api/queue/projects": PROJECTS.slice(0, 5),
  "/api/projects": projects, "/api/board": board,
  "/api/sessions/table": sessions, "/api/sessions/capacity": capacity, "/api/watch": watch, "/api/shepherd": shepherd, "/api/outcomes": [],
  "/api/infra": infra, "/api/reds": reds, "/api/jobs": jobs,
  "/api/log": log, "/api/log/work": logWork, "/api/log/history": logHistory, "/api/actions": actions,
  "/api/fleet": fleet, "/api/schedules": schedules, "/api/costs": costs, "/api/releases": releases, "/api/builds": builds,
};
