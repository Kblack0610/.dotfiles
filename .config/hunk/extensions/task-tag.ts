// task-tag: a review note containing `#task` (or `#task:<project>`) files a task row.
//
// Hunk keeps review notes in the session only; nothing reaches disk. This turns the
// ones you mark into rows through the `notes` CLI so they outlive the review:
//
//   #task:<project>   -> notes ptask <project> add "<text> #low"
//   #task             -> the repo's project board when exactly one maps to it
//                        (project_lab_names in ~/.config/shared-hooks/project-name.sh),
//                        else notes inbox add "<text>"
//
// Listens on `note_created`, which in Hunk 0.22.0 fires only when YOU save a new note in
// the TUI (agent `hunk session comment add` notes never reach it) and carries the file
// path and line directly. `note_changed` also exists in 0.22.0 but reports agent notes
// too and names the file by an opaque key. Editing an existing note to add the tag does
// not file it: only creation does.

import { execFile } from "node:child_process";
import type { HunkExtensionAPI } from "hunkdiff/extension";

const TAG = /#task(?::([\w.-]+))?\b/;
const PRIORITY = /(^|\s)#(urgent|high|low)\b/;
// Timeout guard on each external call, so a wedged `notes` cannot hold a handler forever.
const EXEC_TIMEOUT_MS = 10_000;

// Typographic characters a note picks up from a paste, mapped to their ASCII spelling.
// Anything else outside printable ASCII is dropped: rows on the sheet are plain ASCII.
const ASCII_MAP: Record<string, string> = {
  "\u2013": "-",
  "\u2014": "-",
  "\u2018": "'",
  "\u2019": "'",
  "\u201c": '"',
  "\u201d": '"',
  "\u2026": "...",
  "\u2192": "->",
};
const TYPOGRAPHIC = new RegExp(`[${Object.keys(ASCII_MAP).join("")}]`, "g");

export interface TaskNote {
  /** Explicit `#task:<project>`, when given. */
  project?: string;
  /** Note body with the tag removed, one line, plain ASCII. */
  text: string;
}

export function toAsciiLine(s: string): string {
  return s
    .replace(TYPOGRAPHIC, (c) => ASCII_MAP[c])
    .replace(/\s+/g, " ")
    .replace(/[^\x20-\x7e]/g, "")
    .replace(/ {2,}/g, " ")
    .trim();
}

/** The task a note body asks for, or null when it carries no `#task` tag. */
export function parseTaskNote(body: string): TaskNote | null {
  const m = TAG.exec(body);
  if (!m) return null;
  const text = toAsciiLine(body.slice(0, m.index) + " " + body.slice(m.index + m[0].length));
  return m[1] ? { project: m[1], text } : { text };
}

/** The note text plus where it was written. */
export function located(text: string, filePath: string, line: number): string {
  return `${text} (${toAsciiLine(filePath)}:${line})`;
}

/** A board row defaults to #low: a bare `ptask add` is tagged #high, which means "nobody decided". */
export function withPriority(text: string): string {
  return PRIORITY.test(text) ? text : `${text} #low`;
}

export type Route = { kind: "ptask"; project: string } | { kind: "inbox"; why: string };

/** Where a task goes: an explicit project wins, else exactly one mapped board, else the inbox. */
export function route(explicit: string | undefined, candidates: readonly string[]): Route {
  if (explicit) return { kind: "ptask", project: explicit };
  if (candidates.length === 1) return { kind: "ptask", project: candidates[0] };
  if (candidates.length === 0) return { kind: "inbox", why: "no project board maps to this repo" };
  return { kind: "inbox", why: `${candidates.length} boards match (${candidates.join(", ")}); use #task:<project>` };
}

function run(cmd: string, args: string[], cwd: string): Promise<string> {
  return new Promise((resolve, reject) => {
    execFile(cmd, args, { cwd, timeout: EXEC_TIMEOUT_MS }, (err, stdout, stderr) => {
      if (err) reject(new Error((String(stderr).trim() || err.message).split("\n")[0]));
      else resolve(String(stdout));
    });
  });
}

/** Lab project names for the repo at `cwd`, the same join the session preflight uses. */
async function labNames(cwd: string): Promise<string[]> {
  const script =
    '. "$HOME/.config/shared-hooks/project-name.sh" && project_lab_names "$(resolve_project_name "$1")"';
  const out = await run("bash", ["-c", script, "task-tag", cwd], cwd);
  return out.split("\n").map((s) => s.trim()).filter(Boolean);
}

export default function (hunk: HunkExtensionAPI) {
  const filed = new Set<string>();

  hunk.on("note_created", async ({ note }, ctx) => {
    try {
      if (note.draft || filed.has(note.id)) return;
      const task = parseTaskNote(note.body);
      if (!task) return;
      filed.add(note.id);
      if (!task.text) {
        ctx.notify("#task note has no text to file", "warning");
        return;
      }

      let candidates: string[] = [];
      let resolveError = "";
      if (!task.project) {
        try {
          candidates = await labNames(ctx.cwd);
        } catch (e) {
          resolveError = `project lookup failed: ${(e as Error).message}`;
        }
      }
      const where = route(task.project, candidates);
      const text = located(task.text, note.filePath, note.line);

      if (where.kind === "ptask") {
        const row = withPriority(text);
        await run("notes", ["ptask", where.project, "add", row], ctx.cwd);
        ctx.notify(`#task -> ${where.project} board: ${row}`, "info");
      } else {
        await run("notes", ["inbox", "add", text], ctx.cwd);
        ctx.notify(`#task -> notes inbox (${resolveError || where.why})`, resolveError ? "warning" : "info");
      }
    } catch (e) {
      // Leave the id in `filed`: a failed `notes` call may still have written the row, and
      // a retry on a later event must not double it. The toast carries the error instead.
      ctx.notify(`#task not filed: ${(e as Error).message}`, "error");
    }
  });
}
