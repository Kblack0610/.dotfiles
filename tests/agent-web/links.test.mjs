// One link builder (docs/dashboards.md rule 8 and the Link pattern): a record's link comes from
// `hub_core::links`, served as `Link::href`, never a `"#<tab>/..."` string built in static/*.js.
// This sweep counts the lines that build one, per file, against the allowlist below. The plan is
// ~/.claude/plans/quiet-hopping-hammock.md: P7 sends the rest through hub_core::links, and each
// phase may delete sites sooner; an entry whose count is off in either direction fails here, so
// the list only shrinks and ends empty. Same pattern as heads.test.mjs, run from
// tests/unit/agent_web_queue.bats.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync } from "node:fs";

const dir = new URL("../../.local/src/agent-web/static/", import.meta.url);

// The tabs a hash can name, current and retired (app.js TAB_NAMES and RETIRED_TABS), then `/`,
// `?` or the closing quote: `"#queue?q="`, `` `#sessions/sessions/${id}` ``, `"#home"`. A selector
// (`"#home .card"`) and a bare `"#" + tag` do not match.
const TABS = "home|daily|log|queue|sessions|projects|releases|alerts|infra|schedules|costs|stack|waiting|asks|watch|shepherd|fleet|jobs|ci|machines|today|history|actions|outbox|focus|numbers|board";
const LINK = new RegExp(`["'\`]#(?:${TABS})(?:[/?]|["'\`])`);

// file -> {n: lines building a link, by: the phase that removes them, or "keeps: <why>"}.
// Every site below is the plan's P7 unless an earlier phase deletes it first.
const ALLOW = {
  "alerts.js": { n: 2, by: "P7" },
  "app.js": { n: 1, by: "P7" },
  "board.js": { n: 1, by: "P7" },
  "ci.js": { n: 1, by: "P7" },
  "costs.js": { n: 5, by: "P7" },
  "fleet.js": { n: 7, by: "P7" },
  "flow.js": { n: 1, by: "P7" },
  "focus.js": { n: 2, by: "P7" },
  "home.js": { n: 3, by: "P7" },
  "infra.js": { n: 8, by: "P7" },
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

// Lines that build a link: code, not a comment, with a `#<tab>` string literal in it.
export function sites(text) {
  return text.split("\n").flatMap((l, i) => (/^\s*(\/\/|\*|\/\*)/.test(l) || !LINK.test(l) ? [] : [i + 1]));
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
  ].join("\n");
  assert.deepEqual(sites(src), [1, 3, 6]);
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
});

test("remaining hand-built links, by the phase that removes them", () => {
  const left = Object.entries(ALLOW).filter(([, a]) => /^P\d/.test(a.by));
  console.log(`links allowlist: ${left.reduce((n, [, a]) => n + a.n, 0)} to remove in ${left.length} files`);
  assert.ok(Object.values(ALLOW).every((a) => /^(P\d|keeps: )/.test(a.by)), "every entry names its phase or why it stays");
});
