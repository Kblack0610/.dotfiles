// One reader per store (docs/dashboards.md rule 8, agent-web README): a route in agent-web/src
// calls a hub-core reader, never a second one of its own. This sweep fails when a source file
// shells out (`Command::new`), reads a file (`fs::read*`) or parses JSON (`serde_json::from_*`)
// in production code outside the allowlists below. The plan is
// ~/.claude/plans/quiet-hopping-hammock.md: each later phase deletes its sites and their
// entries; an entry whose site is gone fails here until it is removed, so the list only shrinks.
// Same pattern as heads.test.mjs, run from tests/unit/agent_web_queue.bats.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";

const dir = new URL("../../.local/src/agent-web/src/", import.meta.url);

// A site is a call that reads or parses a store itself.
const SITE = /\bCommand::new\b|\bfs::read\w*|\bserde_json::from_\w+/;

// Whole files that are plumbing, not readers of a fleet store: login and the Forgejo call, the
// cache and its change feed, the embedded assets, web push, the phone widget, the request log.
const PLUMBING_FILES = {
  "auth.rs": "login, credentials and the Forgejo OAuth call",
  "cache.rs": "the TTL cache and its change feed",
  "assets.rs": "the embedded static assets and their route tables",
  "push.rs": "web push registrations and delivery",
  "widget.rs": "the phone widget feed and its token",
  "reqlog.rs": "the request log",
};

// One entry per (file, fn) holding a site. `by` is the phase that deletes it, or "keeps: <why>"
// for a site that is not a reader (an action, a request body, a file watcher).
const SITES = [
  { file: "audit.rs", fn: "entry", by: "keeps: parses the request body it records" },
  { file: "board.rs", fn: "audit_entry", by: "keeps: parses a board write's own body" },
  { file: "cli.rs", fn: "put", by: "keeps: the `notes` write spawn" },
  { file: "cloud.rs", fn: "manifest", by: "P4: the cloud override moves to a hub-core action" },
  { file: "jobs.rs", fn: "log", by: "keeps: parses the row's own log reference; hub_core reads the log" },
  { file: "main.rs", fn: "watch", by: "keeps: file-watcher targets, not a store read" },
  { file: "main.rs", fn: "read_agents", by: "P3: sidebar join moves to hub_core::session_table" },
  { file: "main.rs", fn: "worker_agents", by: "P3: worker panel moves to hub_core::session_table" },
  { file: "main.rs", fn: "run_cmd", by: "keeps: runs an action's command, never a read" },
  { file: "main.rs", fn: "list_asks", by: "P2: one Ask reader in hub_core::boards" },
  { file: "main.rs", fn: "ask_trace", by: "P2: trace text comes from hub_core::home" },
  { file: "main.rs", fn: "ask_preview", by: "keeps: serves the bytes of the file hub_core::outbound names" },
  { file: "main.rs", fn: "answer", by: "keeps: `agent-ask answer` is a write" },
  { file: "queue.rs", fn: "projects", by: "P5: project-map.json through project_map::Registry" },
  { file: "queue.rs", fn: "project_names", by: "P5: project-map.json through project_map::Registry" },
  { file: "remote.rs", fn: "fresh", by: "P3: worker-panel freshness moves to hub_core::session_table" },
  { file: "remote.rs", fn: "find", by: "P3: worker-panel freshness moves to hub_core::session_table" },
  { file: "remote.rs", fn: "run", by: "keeps: runs a command on a worker host" },
  { file: "shepherd.rs", fn: "stats", by: "P3: hub_core::shepherd owns `fleet-shepherd stats`" },
  { file: "shepherd.rs", fn: "parse_stats", by: "P3: hub_core::shepherd owns `fleet-shepherd stats`" },
  { file: "stack.rs", fn: "picture", by: "keeps: serves the svg a hub_core flow row names" },
];

// Production code only: from the first `#[cfg(test)]` at column 0 to the end is test code.
// Each hit is {fn, line} where fn is the nearest enclosing `fn` above it.
export function scan(text) {
  const hits = [];
  let fn = "";
  for (const [i, l] of text.split("\n").entries()) {
    if (/^#\[cfg\(test\)\]/.test(l)) break;
    const m = l.match(/\bfn\s+(\w+)/);
    if (m) fn = m[1];
    if (/^\s*\/\//.test(l)) continue;
    if (SITE.test(l)) hits.push({ fn, line: i + 1 });
  }
  return hits;
}

const read = () => readdirSync(dir).filter((f) => f.endsWith(".rs")).map((f) => [f, readFileSync(new URL(f, dir), "utf8")]);

test("the scan sees a shell-out, a file read and a parse, and skips comments and test code", () => {
  const src = [
    "async fn a() { tokio::process::Command::new(\"agent-ask\"); }",
    "// std::fs::read_to_string in a comment",
    "fn b() { let _ = std::fs::read(p); }",
    "fn c() { serde_json::from_str::<V>(s) }",
    "fn d() { let x = 1; }",
    "#[cfg(test)]",
    "mod t { fn e() { Command::new(\"x\"); } }",
  ].join("\n");
  assert.deepEqual(scan(src), [{ fn: "a", line: 1 }, { fn: "b", line: 3 }, { fn: "c", line: 4 }]);
});

test("agent-web/src reads no store itself: a route calls one hub-core reader", () => {
  const files = read();
  const bad = [];
  const used = new Set();
  for (const [f, text] of files) {
    if (f in PLUMBING_FILES) continue;
    for (const h of scan(text)) {
      const e = SITES.findIndex((s) => s.file === f && s.fn === h.fn);
      if (e < 0) bad.push(`${f}:${h.line} (fn ${h.fn})`);
      else used.add(e);
    }
  }
  assert.deepEqual(
    bad,
    [],
    "a second reader in agent-web: add the field to the hub-core reader and call it (docs/dashboards.md rule 8). " +
      "Plumbing and actions go in PLUMBING_FILES or SITES with the reason",
  );
  const stale = SITES.filter((_, i) => !used.has(i)).map((s) => `${s.file} fn ${s.fn} (${s.by})`);
  assert.deepEqual(stale, [], "an allowlist entry whose site is gone: delete the entry, the list only shrinks");
  for (const f of Object.keys(PLUMBING_FILES)) assert.ok(files.some(([n]) => n === f), `${f} is gone: drop it from PLUMBING_FILES`);
});

test("remaining second readers, by the phase that removes them", () => {
  const left = SITES.filter((s) => /^P\d/.test(s.by));
  const byPhase = {};
  for (const s of left) (byPhase[s.by.slice(0, 2)] ||= []).push(`${s.file}:${s.fn}`);
  console.log(`readers allowlist: ${left.length} to remove`, JSON.stringify(byPhase));
  assert.ok(SITES.every((s) => /^(P\d|keeps: )/.test(s.by)), "every entry names its phase or why it stays");
});
