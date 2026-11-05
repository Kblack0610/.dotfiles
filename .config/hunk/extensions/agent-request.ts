// agent-request: press A to copy this review's notes into the repo's agent request, then send
// the request as one queue item or into the repo's Claude session.
//
// The `agent-request` CLI owns the draft (one per repo), so notes left here and notes added in
// nvim go out together. Hunk keeps notes in memory only, so they are copied in by id each time
// A is pressed; the CLI skips an id it already has. Only your notes go: agent and AI notes are
// the other side of the conversation. Usage: ../README.md.

import { execFile } from "node:child_process";
import type { HunkExtensionAPI, ExtensionReviewSnapshot } from "hunkdiff/extension";

// Timeout guard on each external call, so a wedged CLI cannot hold the command forever.
const EXEC_TIMEOUT_MS = 15_000;
const QUEUE = "Queue it (one agent-queue item)";
const SESSION = "Send to this repo's Claude session";
const KEEP = "Keep drafting";

type Snapshot = Pick<ExtensionReviewSnapshot, "files" | "notes">;

/** One `agent-request add` argv per user note worth sending, in review order. */
export function addArgs(snap: Snapshot, root: string): string[][] {
  const paths = new Map(snap.files.map((f) => [f.fileKey, f.path]));
  const out: string[][] = [];
  for (const n of snap.notes) {
    if (n.source !== "user" || n.resolution === "orphaned") continue;
    const path = paths.get(n.fileKey);
    const text = [n.title, n.summary].filter(Boolean).join(": ").trim();
    if (!path || !text) continue;
    const a = n.anchor;
    const side = a.preferred?.side ?? (a.newRange ? "new" : "old");
    const range = side === "new" ? a.newRange : a.oldRange;
    const line = a.preferred?.line ?? range?.[0];
    if (!line) continue;
    const args = ["add", "--file", `${root}/${path}`, "--line", String(line)];
    const end = side === "new" ? range?.[1] : undefined;
    if (end && end > line) args.push("--end", String(end));
    args.push("--id", `hunk:${n.id}`, "--", side === "old" ? `(on the old side of the diff) ${text}` : text);
    out.push(args);
  }
  return out;
}

/** `pane<TAB>target<TAB>doing` lines from a refused `send --session`, as dialog choices. */
export function candidates(stdout: string): { pane: string; label: string }[] {
  return stdout
    .split("\n")
    .filter(Boolean)
    .map((l) => {
      const [pane, target, doing] = l.split("\t");
      return { pane, label: doing ? `${target}  ${doing}` : target };
    });
}

type Result = { code: number; stdout: string; stderr: string };

function run(cmd: string, args: string[], cwd: string): Promise<Result> {
  return new Promise((resolve) => {
    execFile(cmd, args, { cwd, timeout: EXEC_TIMEOUT_MS }, (err, stdout, stderr) => {
      const code = err ? (typeof err.code === "number" ? err.code : 1) : 0;
      resolve({ code, stdout: String(stdout).trim(), stderr: String(stderr).trim() });
    });
  });
}

const firstLine = (s: string) => s.split("\n")[0];

export default function (hunk: HunkExtensionAPI) {
  hunk.registerCommand({ id: "send", title: "Agent request: collect notes and send", key: "A" }, async (ctx) => {
    const snap = ctx.review.snapshot();
    if (!snap) return;
    const top = await run("git", ["rev-parse", "--show-toplevel"], ctx.cwd);
    if (top.code !== 0) return ctx.notify("agent-request: not in a git repo", "error");
    const root = top.stdout;

    for (const args of addArgs(snap, root)) {
      const r = await run("agent-request", args, root);
      if (r.code !== 0) return ctx.notify(`agent-request: ${firstLine(r.stderr)}`, "error");
    }
    const listed = await run("agent-request", ["list", "--json", "--dir", root], root);
    if (listed.code !== 0) return ctx.notify(`agent-request: ${firstLine(listed.stderr)}`, "error");
    const n = (JSON.parse(listed.stdout || "[]") as unknown[]).length;
    if (n === 0) return ctx.notify("agent-request: no notes to send", "warning");

    const choice = await ctx.dialogs.select({ title: `Send ${n} notes`, options: [QUEUE, SESSION, KEEP] });
    if (choice === QUEUE) {
      const repo = root.split("/").pop();
      const title = await ctx.dialogs.input({ title: "Queue title", initial: `${repo}: ${n} notes` });
      if (title === null) return;
      const r = await run("agent-request", ["send", "--queue", "--title", title, "--dir", root], root);
      ctx.notify(firstLine(r.code === 0 ? r.stdout : r.stderr), r.code === 0 ? "info" : "error");
    } else if (choice === SESSION) {
      let r = await run("agent-request", ["send", "--session", "--dir", root], root);
      if (r.code === 2 && r.stdout) {
        const rows = candidates(r.stdout);
        const label = await ctx.dialogs.select({ title: "Which session?", options: rows.map((c) => c.label) });
        const row = rows.find((c) => c.label === label);
        if (!row) return;
        r = await run("agent-request", ["send", "--session", "--pane", row.pane, "--dir", root], root);
      }
      ctx.notify(firstLine(r.code === 0 ? r.stdout : r.stderr), r.code === 0 ? "info" : r.code === 3 ? "warning" : "error");
    }
  });
}
