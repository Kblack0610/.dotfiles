// One link builder (docs/dashboards.md rule 8 and the Link pattern): a record's link comes from
// `hub_core::links`, served as `Link::href`, never a `"#<tab>/..."` string built in static/*.js.
// This sweep counts the string literals that start one, per file, against the allowlist below.
// The agent-web one-reader chain (board row ar-3369) sends the rest through hub_core::links in
// its P7, and an earlier phase may delete sites sooner; an entry whose count is off in either
// direction fails here, so the list only shrinks and ends at the `keeps:` entries. Forms the
// pattern does not see (a `#` joined to a tab name at run time) are caught in review. Same
// pattern as heads.test.mjs, run from tests/unit/agent_web_queue.bats.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);

// The tabs a hash can name, current and retired (app.js TAB_NAMES and RETIRED_TABS), then `/`,
// `?` or the closing quote: `"#queue?q="`, `` `#sessions/sessions/${id}` ``, `"#home"`. A selector
// (`"#home .card"`) and a bare `"#" + tag` do not match.
const TABS = "home|daily|reports|log|queue|sessions|projects|releases|alerts|infra|schedules|costs|stack|waiting|asks|watch|shepherd|fleet|jobs|ci|machines|today|history|actions|outbox|focus|numbers|board";
const LINK = new RegExp(`["'\`]#(?:${TABS})(?:[/?]|["'\`])`, "g");

// file -> {n: lines building a link, by: the phase that removes them, or "keeps: <why>"}.
// Every site below is the plan's P7 unless an earlier phase deletes it first.
const ALLOW = {
  "alerts.js": { n: 1, by: "P7" },
  "app.js": { n: 1, by: "P7" },
  "board.js": { n: 1, by: "P7" },
  "ci.js": { n: 1, by: "P7" },
  "costs.js": { n: 5, by: "P7" },
  "fleet.js": { n: 7, by: "P7" },
  "flow.js": { n: 1, by: "P7" },
  "focus.js": { n: 2, by: "P7" },
  "home.js": { n: 1, by: "P7" },
  "infra.js": { n: 5, by: "P7" },
  "jobs.js": { n: 2, by: "P7" },
  "log.js": { n: 1, by: "P7" },
  "md.js": { n: 2, by: "keeps: a note's own wikilinks and #p: tags are text the note holds, not a record link" },
  "outbox.js": { n: 1, by: "P7" },
  "projects.js": { n: 5, by: "P7" },
  "releases.js": { n: 2, by: "P7" },
  "sessions.js": { n: 1, by: "P7" },
  "stack.js": { n: 4, by: "P7" },
  "work.js": { n: 1, by: "P7" },
};

// Each `#<tab>` string literal in code, not in a comment, as its line number (twice on a line
// that holds two).
export function sites(text) {
  return text.split("\n").flatMap((l, i) =>
    /^\s*(\/\/|\/\*|\*\s|\*$)/.test(l) ? [] : Array.from(l.matchAll(LINK), () => i + 1));
}

const files = () => readdirSync(dir).filter((f) => f.endsWith(".js"));

test("the sweep sees a built record link, and skips comments, selectors and tag chips", () => {
  const src = [
    "const a = (n) => \"#sessions/runners/\" + n;",
    "// href=\"#queue/<slug>\" in a comment",
    "const b = `<a href=\"#home\">Home</a>`;",
    "keepTyping(\"#home .card\", draw);",
    "const c = (t) => \"#\" + t;",
    "const d = `#costs?by=model`;",
    "const e = `<a href=\"#queue\">Q</a><a href=\"#log/actions\">L</a>`;",
  ].join("\n");
  assert.deepEqual(sites(src), [1, 3, 6, 7, 7]);
});

test("static/*.js builds no record link by hand: hub_core::links serves it", () => {
  const got = {};
  for (const f of files()) {
    const s = sites(readFileSync(new URL(f, dir), "utf8"));
    if (s.length) got[f] = s;
  }
  const bad = [];
  for (const [f, lines] of Object.entries(got)) {
    const a = ALLOW[f];
    if (!a) bad.push(`${f}: ${lines.length} hand-built link(s) at ${lines.join(",")}, none allowed`);
    else if (lines.length > a.n) bad.push(`${f}: ${lines.length} hand-built links, ${a.n} allowed (lines ${lines.join(",")})`);
    else if (lines.length < a.n) bad.push(`${f}: ${lines.length} left, allowlist says ${a.n}: lower it, the list only shrinks`);
  }
  for (const f of Object.keys(ALLOW)) if (!(f in got)) bad.push(`${f}: no hand-built link left: delete its entry`);
  assert.deepEqual(bad, [], "a record link is a hub_core::links Kind served as Link::href; do not build a `#tab/id` string in JS");
  assert.ok(Object.values(ALLOW).every((a) => /^(P\d|keeps: )/.test(a.by)), "every entry names its phase or why it stays");
});
