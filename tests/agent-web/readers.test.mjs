// One reader per store (docs/dashboards.md rule 8, agent-web README): a route in agent-web/src
// calls a hub-core reader, never a second one of its own. This sweep fails when production code
// there shells out (`Command::new`), reads, writes or stats a file (`fs::read*`, `fs::metadata`,
// `File::open`, `OpenOptions`) or parses JSON, YAML or TOML (`serde_json::from_*`) outside the
// allowlists below. Each entry carries the number of sites it covers, so a new site in an
// allowed function fails too. The ones tagged P2..P5 are deleted by those phases of the
// agent-web one-reader chain (board row ar-3369), each removing its entries; an entry whose site
// is gone fails until it is removed, so the list only shrinks. Same pattern as heads.test.mjs,
// run from tests/unit/agent_web_queue.bats.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";

const dir = new URL("../../.local/src/agent-web/src/", import.meta.url);

const SITE = /\bCommand::new\b|\bfs::(?:read\w*|metadata|write|copy|File|OpenOptions)\b|\bFile::open\b|\bOpenOptions\b|\b(?:serde_json|serde_yaml|toml)::from_\w+/;

// Whole files that are plumbing, not readers of a fleet store: login and the Forgejo call, the
// cache and its change feed, web push, and the phone widget's own feed and token.
const PLUMBING_FILES = {
  "auth.rs": "login, credentials and the Forgejo OAuth call",
  "cache.rs": "the TTL cache and its change feed",
  "push.rs": "web push registrations and delivery",
  "widget.rs": "the phone widget's own feed and token",
};

// One entry per (file, fn) holding sites, `n` of them. `by` is the phase that deletes it, or
// "keeps: <why>" for a site that is not a reader (an action, a request body, a file watcher).
const SITES = [
  { file: "audit.rs", fn: "entry", n: 1, by: "keeps: parses the request body it records" },
  { file: "board.rs", fn: "audit_entry", n: 1, by: "keeps: parses a board write's own body" },
  { file: "cli.rs", fn: "put", n: 1, by: "keeps: the `notes` write spawn" },
  { file: "jobs.rs", fn: "log", n: 1, by: "keeps: parses the row's own log reference; hub_core reads the log" },
  { file: "main.rs", fn: "watch", n: 1, by: "keeps: file-watcher targets, not a store read" },
  { file: "main.rs", fn: "read_agents", n: 3, by: "P3: sidebar join moves to hub_core::session_table" },
  { file: "main.rs", fn: "worker_agents", n: 1, by: "P3: worker panel moves to hub_core::session_table" },
  { file: "main.rs", fn: "run_cmd", n: 1, by: "keeps: runs an action's command, never a read" },
  { file: "main.rs", fn: "ask_preview", n: 1, by: "keeps: serves the bytes of the file hub_core::outbound names" },
  { file: "main.rs", fn: "answer", n: 1, by: "keeps: `agent-ask answer` is a write" },
  { file: "queue.rs", fn: "snapshot_key", n: 1, by: "P5: queue reads the dispatch snapshot through hub_core" },
  { file: "queue.rs", fn: "projects", n: 1, by: "P5: project-map.json through project_map::Registry" },
  { file: "queue.rs", fn: "project_names", n: 1, by: "P5: project-map.json through project_map::Registry" },
  { file: "remote.rs", fn: "fresh", n: 1, by: "P3: worker-panel freshness moves to hub_core::session_table" },
  { file: "remote.rs", fn: "find", n: 1, by: "P3: worker-panel freshness moves to hub_core::session_table" },
  { file: "remote.rs", fn: "run", n: 1, by: "keeps: runs a command on a worker host" },
  { file: "shepherd.rs", fn: "stats", n: 1, by: "P3: hub_core::shepherd owns `fleet-shepherd stats`" },
  { file: "shepherd.rs", fn: "parse_stats", n: 1, by: "P3: hub_core::shepherd owns `fleet-shepherd stats`" },
  { file: "stack.rs", fn: "picture", n: 1, by: "keeps: serves the svg a hub_core flow row names" },
];

// Production code only: from the first `#[cfg(test)]` at column 0 to the end is test code.
// Each hit is {fn, line} where fn is the nearest `fn` declared above it.
export function scan(text) {
  const hits = [];
  let fn = "";
  for (const [i, l] of text.split("\n").entries()) {
    if (/^#\[cfg\(test\)\]/.test(l)) break;
    if (/^\s*\/\//.test(l)) continue;
    const m = l.match(/\bfn\s+(\w+)/);
    if (m) fn = m[1];
    if (SITE.test(l)) hits.push({ fn, line: i + 1 });
  }
  return hits;
}

const read = () => readdirSync(dir).filter((f) => f.endsWith(".rs")).map((f) => [f, readFileSync(new URL(f, dir), "utf8")]);

test("the scan sees a shell-out, a file read, a stat and a parse, and skips comments and test code", () => {
  const src = [
    "async fn a() { tokio::process::Command::new(\"agent-ask\"); }",
    "/// fn run is a doc comment, std::fs::read_to_string too",
    "fn b() { let _ = std::fs::read(p); }",
    "fn c() { serde_json::from_str::<V>(s) }",
    "fn d() { let _ = std::fs::metadata(p); let _ = File::open(p); }",
    "fn e() { let x = 1; }",
    "#[cfg(test)]",
    "mod t { fn f() { Command::new(\"x\"); } }",
  ].join("\n");
  assert.deepEqual(scan(src), [{ fn: "a", line: 1 }, { fn: "b", line: 3 }, { fn: "c", line: 4 }, { fn: "d", line: 5 }]);
});

test("agent-web/src reads no store itself: a route calls one hub-core reader", () => {
  const files = read();
  const got = {};
  for (const [f, text] of files) {
    if (f in PLUMBING_FILES) continue;
    for (const h of scan(text)) (got[`${f} fn ${h.fn}`] ||= []).push(h.line);
  }
  const bad = [];
  for (const [k, lines] of Object.entries(got)) {
    const e = SITES.find((s) => `${s.file} fn ${s.fn}` === k);
    if (!e) bad.push(`${k}: ${lines.length} site(s) at ${lines.join(",")}, none allowed`);
    else if (lines.length > e.n) bad.push(`${k}: ${lines.length} sites, ${e.n} allowed (lines ${lines.join(",")})`);
    else if (lines.length < e.n) bad.push(`${k}: ${lines.length} left, allowlist says ${e.n}: lower it, the list only shrinks`);
  }
  for (const s of SITES) if (!(`${s.file} fn ${s.fn}` in got)) bad.push(`${s.file} fn ${s.fn}: no site left, delete its entry (${s.by})`);
  assert.deepEqual(
    bad,
    [],
    "a second reader in agent-web: add the field to the hub-core reader and call it (docs/dashboards.md rule 8). " +
      "Plumbing and actions go in PLUMBING_FILES or SITES with the reason",
  );
  for (const f of Object.keys(PLUMBING_FILES)) assert.ok(files.some(([n]) => n === f), `${f} is gone: drop it from PLUMBING_FILES`);
  assert.ok(SITES.every((s) => /^(P\d|keeps: )/.test(s.by)), "every entry names its phase or why it stays");
});
