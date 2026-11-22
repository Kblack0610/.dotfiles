// One home per figure (docs/dashboards.md rules 2 and 8): a waybar chip, agent-mqtt-publish, a tmux
// script under .local/src/tmux and the CLIs that page or summarise figures (day-log, fleet-bench,
// fleet-shepherd, agent-ask) lay out what hub-core counted (`hub <verb> --json`, the publisher's
// summary/cards `figures`), never a count of their own. This sweep fails when one of them counts
// records: jq `group_by`, `add`, a `select(...) | length` or `[...] | length`, a shell
// `n=$((n + 1))` or `((n++))`, an awk `n++`, `wc -l` or `grep -c`, outside the allowlist in
// figure-sites.json. It is a tripwire, not a parser: a bare `x | length` is not a site, since the
// chips use it for column widths and empty checks, so a count spelled that way passes and review is
// still the backstop. Each entry carries its site count per function, so a new count in an allowed
// function fails too, and an entry whose sites are gone fails until it is removed, so the list only
// shrinks. Every `by` is an open board row id (the pass that moves the site, `ar-NNNN: why`) or
// `keeps: <why>` for a count that is not a fleet figure. The row ids are checked against the real
// agent board and skipped where there is none (CI): a committed copy of the board would only
// restate this list. The readers.test.mjs pattern for agent-web, run from tests/unit/waybar_figures.bats.
import { test } from "node:test";
import assert from "node:assert/strict";
import { existsSync, readFileSync, readdirSync } from "node:fs";
import { homedir } from "node:os";

const root = new URL("../../", import.meta.url);
const WAYBAR = ".config/waybar/";
const TMUX = ".local/src/tmux/";
const BINS = [".local/bin/agent-mqtt-publish", ".local/bin/day-log", ".local/bin/fleet-bench", ".local/bin/fleet-shepherd", ".local/bin/agent-ask"];
const BOARD = process.env.AGENT_BOARD_FILE || `${homedir()}/.notes/lab/projects/current/agent-runtime/agent/README.md`;

const SITE =
  /\bgroup_by\(|select\(.*\|\s*length\b|\]\s*\|\s*length\b|\|\s*add\b|\b[\w]+(?:\[[^\]]*\])?=\$\(\(\s*\$?\{?[\w]+(?:\[[^\]]*\])?(?::-0)?\}?\s*\+\s*1\s*\)\)|\(\(\s*\w+\+\+\s*\)\)|\b\w+(?:\[[^\]]*\])?\+\+\s*(?:$|[;}])|\bwc\s+-l\b|\bgrep\s+(?:-\w*c|--count\b)/;

// PLUMBING_FILES: whole files that show no fleet figure hub-core owns. SITES: one entry per
// (file, fns) holding sites, each fn with its count `n`, and `by` as above.
const { plumbing: PLUMBING_FILES, sites: SITES } = JSON.parse(readFileSync(new URL("figure-sites.json", import.meta.url), "utf8"));

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

const sh = (dir) =>
  readdirSync(new URL(dir, root))
    .filter((f) => f.endsWith(".sh"))
    .map((f) => dir + f);
const files = () => [...sh(WAYBAR), ...sh(TMUX), ...BINS].map((f) => [f, readFileSync(new URL(f, root), "utf8")]);

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
    "awk '{ if ($2 == \"~\") working++; else idle++ } END { print working }'",
    "for ((i = 0; i < 3; i++)); do :; done",
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
    { fn: "main", line: 14 },
  ]);
});

// Each (file, fn) whose count of sites differs from its allowlist entry, one line each.
export function check(all, sites = SITES, plumbing = PLUMBING_FILES) {
  const got = {};
  for (const [f, text] of all) {
    if (f in plumbing) continue;
    for (const h of scan(text)) (got[`${f} fn ${h.fn}`] ||= []).push(h.line);
  }
  const allowed = {};
  const bad = [];
  for (const s of sites)
    for (const [fn, n] of Object.entries(s.fns)) {
      const k = `${s.file} fn ${fn}`;
      if (k in allowed) bad.push(`${k}: listed twice`);
      allowed[k] = { n, by: s.by };
    }
  for (const [k, lines] of Object.entries(got)) {
    const e = allowed[k];
    if (!e) bad.push(`${k}: ${lines.length} site(s) at ${lines.join(",")}, none allowed`);
    else if (lines.length > e.n) bad.push(`${k}: ${lines.length} sites, ${e.n} allowed (lines ${lines.join(",")})`);
    else if (lines.length < e.n) bad.push(`${k}: ${lines.length} left, allowlist says ${e.n}: lower it, the list only shrinks`);
  }
  for (const [k, e] of Object.entries(allowed)) if (!(k in got)) bad.push(`${k}: no site left, delete its entry (${e.by})`);
  return bad;
}

// The board rows open on the agent board: `- [ ]` or `- [/]` lines carrying `<!-- id:ar-N ...`.
export const openRows = (text) =>
  new Set([...text.matchAll(/^- \[[ /]\] .*<!-- id:(ar-\d+)\b/gm)].map((m) => m[1]));

// Each entry whose `by` is neither `keeps: <why>` nor `ar-N: <why>` with ar-N in `open` (a Set, or
// null to check the form only).
export function checkBy(sites, open) {
  const bad = [];
  for (const s of sites) {
    const row = s.by.match(/^(ar-\d+): \S/);
    if (/^keeps: \S/.test(s.by)) continue;
    if (!row) bad.push(`${s.file} (${Object.keys(s.fns).join(",")}): by must be "ar-N: why" or "keeps: why": ${s.by}`);
    else if (open && !open.has(row[1])) bad.push(`${s.file} (${Object.keys(s.fns).join(",")}): ${row[1]} is not an open row on the agent board`);
  }
  return bad;
}

test("negative control: a new chip that counts, or an extra count in an allowed function, fails", () => {
  const real = files();
  const chip = [".config/waybar/new.sh", "n=$(jq '[.rows[] | select(.done)] | length' <<< \"$raw\")"];
  assert.deepEqual(check([...real, chip]), [".config/waybar/new.sh fn main: 1 site(s) at 1, none allowed"]);
  const more = real.map(([f, t]) => [f, f === ".config/waybar/health.sh" ? t + "\nx=$(wc -l < f)" : t]);
  assert.equal(check(more).length, 1);
});

test("negative control: a tmux script or a figure CLI with its own count fails", () => {
  const real = files();
  const tmux = [".local/src/tmux/new.sh", "asks=$(agent-ask list --pending | grep -c .)"];
  assert.deepEqual(check([...real, tmux]), [".local/src/tmux/new.sh fn main: 1 site(s) at 1, none allowed"]);
  const shep = real.map(([f, t]) => [f, f === ".local/bin/fleet-shepherd" ? t + "\nn=\"$(hub needs --json | jq '[.needs[] | select(.score.human)] | length')\"" : t]);
  const bad = check(shep);
  assert.equal(bad.length, 1);
  assert.match(bad[0], /fleet-shepherd fn main: 1 site\(s\)/);
});

test("negative control: an entry whose site is gone, or whose by names no open row, fails", () => {
  const real = files();
  const ghost = [...SITES, { file: ".local/src/tmux/questions.sh", by: "ar-4395: x", fns: { no_such_fn: 1 } }];
  assert.deepEqual(check(real, ghost), [`.local/src/tmux/questions.sh fn no_such_fn: no site left, delete its entry (ar-4395: x)`]);
  const board = "- [ ] a row #of/ar-1 <!-- id:ar-4395 tier:backlog -->\n- [/] b <!-- id:ar-4396 run:1121 -->\n- [x] c <!-- id:ar-9 done:2026-11-21 -->\n";
  const open = openRows(board);
  assert.deepEqual([...open], ["ar-4395", "ar-4396"]);
  const e = (by) => [{ file: "f", by, fns: { main: 1 } }];
  assert.deepEqual(checkBy(e("ar-4395: moves it"), open), []);
  assert.deepEqual(checkBy(e("keeps: not a figure"), open), []);
  assert.equal(checkBy(e("ar-9999: made up"), open).length, 1);
  assert.equal(checkBy(e("ar-9: closed row"), open).length, 1);
  assert.equal(checkBy(e("outbox: filed nowhere"), open).length, 1);
  assert.equal(checkBy(e("ar-4395"), open).length, 1);
});

test("waybar chips, tmux scripts, agent-mqtt-publish and the figure CLIs count no fleet figure themselves", () => {
  const all = files();
  const bad = check(all);
  assert.deepEqual(
    bad,
    [],
    "a surface counting a figure itself: add it to a hub-core card and read the figure (docs/dashboards.md rules 2 and 8). " +
      "A count that is no fleet figure goes in PLUMBING_FILES or SITES with the reason",
  );
  for (const f of Object.keys(PLUMBING_FILES)) assert.ok(all.some(([n]) => n === f), `${f} is gone: drop it from PLUMBING_FILES`);
  assert.deepEqual(checkBy(SITES, null), [], "every entry names its row or why it stays");
});

test("every by: row id is open on the agent board", { skip: !existsSync(BOARD) && `no board at ${BOARD}` }, () => {
  assert.deepEqual(checkBy(SITES, openRows(readFileSync(BOARD, "utf8"))), [], "name a row the board carries: file it with `notes ptask <project> --agent add`, then use its id");
});
