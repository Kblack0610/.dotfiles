// One home per figure (docs/dashboards.md rules 2 and 8): a waybar chip and agent-mqtt-publish lay
// out what hub-core counted (`hub <verb> --json`, the publisher's summary/cards `figures`), never
// a count of their own. This sweep fails when one of them counts records: jq `group_by`, `add`, a
// `select(...) | length` or `[...] | length`, a shell `n=$((n + 1))` or `((n++))`, `wc -l` or
// `grep -c`, outside the allowlists below. It is a tripwire, not a parser: a bare `x | length` is
// not a site, since the chips use it for column widths and empty checks, so a count spelled that
// way passes and review is still the backstop. Each entry carries its site count, so a new count in an
// allowed function fails too, and an entry whose sites are gone fails until it is removed, so the
// list only shrinks. The readers.test.mjs pattern for agent-web, run from tests/unit/waybar_figures.bats.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";

const root = new URL("../../", import.meta.url);
const WAYBAR = ".config/waybar/";

const SITE =
  /\bgroup_by\(|select\(.*\|\s*length\b|\]\s*\|\s*length\b|\|\s*add\b|\b[\w]+(?:\[[^\]]*\])?=\$\(\(\s*\$?\{?[\w]+(?:\[[^\]]*\])?(?::-0)?\}?\s*\+\s*1\s*\)\)|\(\(\s*\w+\+\+\s*\)\)|\bwc\s+-l\b|\bgrep\s+(?:-\w*c|--count\b)/;

// Whole files that show no fleet figure hub-core owns: this machine's own devices and menus.
const PLUMBING_FILES = {
  ".config/waybar/fleet_pulse.sh": "machine liveness from Gatus heartbeats; no hub-core card owns it",
  ".config/waybar/load.sh": "this machine's CPU load",
  ".config/waybar/machines.sh": "the ssh host menu",
  ".config/waybar/pin-hint.sh": "the pin legend",
  ".config/waybar/webcam.sh": "the webcam device",
};

// One entry per (file, fn) holding sites, `n` of them. `by` names the outbox follow-up that moves
// the count into hub-core, or "keeps: <why>" for a count that is not a fleet figure.
const SITES = [
  {
    file: ".config/waybar/ai_agents.sh",
    fn: "main",
    n: 10,
    by: "outbox: sessions figures from one source; the Sessions card counts fleet-sessions state and the chip and its hover read it (of the 10, one is textfile freshness per host, one a column width, one an empty-section check)",
  },
  { file: ".config/waybar/ci_runners.sh", fn: "main", n: 1, by: "keeps: whether the weight footnote prints over `hub ci --json`, no figure" },
  { file: ".config/waybar/health.sh", fn: "main", n: 1, by: "outbox: a card figure for the red count and System domains up/down (from ar-4336)" },
  { file: ".config/waybar/projects.sh", fn: "main", n: 2, by: "outbox: the waybar projects chip reads in flight, the project count and sprints from the Projects card figures" },
  {
    file: ".config/waybar/queue.sh",
    fn: "main",
    n: 4,
    by: "keeps: joins Prometheus series per key, lists room reasons per account and counts hover lines against the bar's line budget, no figure",
  },
  { file: ".local/bin/agent-mqtt-publish", fn: "snapshot", n: 6, by: "outbox: publisher drops asks_open and sensor.agent_sessions (from ar-4336)" },
  { file: ".local/bin/agent-mqtt-publish", fn: "main", n: 2, by: "keeps: the messages it sent, for its own log line" },
];

// Production lines only: comments are skipped. Each hit is {fn, line}, fn the shell function the
// line sits in (`name() {` to a `}` at column 0, or the one line of `name() { ...; }`), else "main".
export function scan(text) {
  const hits = [];
  let fn = "main";
  for (const [i, l] of text.split("\n").entries()) {
    if (/^\s*#/.test(l)) continue;
    const m = l.match(/^\s*(?:function\s+)?([\w-]+)\s*\(\)\s*\{?/);
    if (m) fn = m[1];
    if (SITE.test(l)) hits.push({ fn, line: i + 1 });
    if (/^\}/.test(l) || (m && /\}\s*$/.test(l))) fn = "main";
  }
  return hits;
}

const files = () => [
  ...readdirSync(new URL(WAYBAR, root))
    .filter((f) => f.endsWith(".sh"))
    .map((f) => WAYBAR + f),
  ".local/bin/agent-mqtt-publish",
].map((f) => [f, readFileSync(new URL(f, root), "utf8")]);

test("the scan sees each kind of count and skips comments and layout widths", () => {
  const src = [
    "# a comment: [.x[] | select(.y)] | length",
    "jq '[.cards[] | select(.in_flight)] | length'",
    "jq 'group_by(.h)'",
    "jq 'map(.n) | add'",
    "count() {",
    "  n=$((n + 1))",
    "  c[$b]=$((${c[$b]:-0} + 1))",
    "}",
    "((i++))",
    "x=$(wc -l < f); y=$(grep -c ok f)",
    "z=$(grep --count ok f)",
    "jq 'def pad($n): . + (\" \" * ([$n - length, 0] | max));'",
    "age=$((now - start))",
  ].join("\n");
  assert.deepEqual(scan(src), [
    { fn: "main", line: 2 },
    { fn: "main", line: 3 },
    { fn: "main", line: 4 },
    { fn: "count", line: 6 },
    { fn: "count", line: 7 },
    { fn: "main", line: 9 },
    { fn: "main", line: 10 },
    { fn: "main", line: 11 },
  ]);
});

// Each (file, fn) whose count of sites differs from its allowlist entry, one line each.
export function check(all) {
  const got = {};
  for (const [f, text] of all) {
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
  return bad;
}

test("negative control: a new chip that counts, or an extra count in an allowed function, fails", () => {
  const real = files();
  const chip = [".config/waybar/new.sh", "n=$(jq '[.rows[] | select(.done)] | length' <<< \"$raw\")"];
  assert.deepEqual(check([...real, chip]), [".config/waybar/new.sh fn main: 1 site(s) at 1, none allowed"]);
  const more = real.map(([f, t]) => [f, f === ".config/waybar/health.sh" ? t + "\nx=$(wc -l < f)" : t]);
  assert.equal(check(more).length, 1);
});

test("waybar chips and agent-mqtt-publish count no fleet figure themselves", () => {
  const all = files();
  const bad = check(all);
  assert.deepEqual(
    bad,
    [],
    "a surface counting a figure itself: add it to a hub-core card and read the figure (docs/dashboards.md rules 2 and 8). " +
      "A count that is no fleet figure goes in PLUMBING_FILES or SITES with the reason",
  );
  for (const f of Object.keys(PLUMBING_FILES)) assert.ok(all.some(([n]) => n === f), `${f} is gone: drop it from PLUMBING_FILES`);
  assert.ok(SITES.every((s) => /^(outbox: |keeps: )/.test(s.by)), "every entry names its follow-up or why it stays");
});
