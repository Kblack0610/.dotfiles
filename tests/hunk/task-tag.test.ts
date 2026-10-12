// Pure-function tests for .config/hunk/extensions/task-tag.ts. Lives here, not beside the
// extension: every *.ts in ~/.config/hunk/extensions/ is loaded by Hunk as an extension.
import { describe, expect, test } from "bun:test";
import { located, parseTaskNote, route, toAsciiLine, withPriority } from "../../.config/hunk/extensions/task-tag.ts";

describe("parseTaskNote", () => {
  test("no tag is not a task", () => {
    expect(parseTaskNote("fix this")).toBeNull();
    expect(parseTaskNote("see #tasks list")).toBeNull();
    expect(parseTaskNote("issue#task")).not.toBeNull(); // tag position is free-form
  });

  test("bare tag strips and leaves no project", () => {
    expect(parseTaskNote("fix this #task")).toEqual({ text: "fix this" });
    expect(parseTaskNote("#task fix this")).toEqual({ text: "fix this" });
    expect(parseTaskNote("fix #task this")).toEqual({ text: "fix this" });
  });

  test("explicit project is captured", () => {
    expect(parseTaskNote("fix this #task:agent-runtime")).toEqual({ project: "agent-runtime", text: "fix this" });
    // Sentence punctuation after the name is not part of it.
    expect(parseTaskNote("drop it #task:home-config.")?.project).toBe("home-config");
  });

  test("tag alone yields empty text", () => {
    expect(parseTaskNote("  #task  ")).toEqual({ text: "" });
  });

  test("multi-line body collapses to one line", () => {
    expect(parseTaskNote("line one\n\nline two #task")).toEqual({ text: "line one line two" });
  });
});

describe("toAsciiLine", () => {
  test("typographic characters map to ASCII, the rest drop", () => {
    expect(toAsciiLine("a \u2014 b \u201cq\u201d \u2026 x \u2192 y \u00e9")).toBe('a - b "q" ... x -> y');
  });
});

describe("located / withPriority", () => {
  test("appends location", () => {
    expect(located("fix this", "src/a.ts", 12)).toBe("fix this (src/a.ts:12)");
  });
  test("defaults to #low", () => {
    expect(withPriority("fix this (a.ts:1)")).toBe("fix this (a.ts:1) #low");
  });
  test("keeps an explicit priority instead of #low", () => {
    expect(withPriority("fix this #urgent (a.ts:1)")).toBe("fix this #urgent (a.ts:1)");
    expect(withPriority("#high fix (a.ts:1)")).toBe("#high fix (a.ts:1)");
  });
  test("#lowercase is not a priority", () => {
    expect(withPriority("#lowercase it")).toBe("#lowercase it #low");
  });
});

describe("route", () => {
  test("explicit project wins over candidates", () => {
    expect(route("home-config", ["a", "b"])).toEqual({ kind: "ptask", project: "home-config" });
  });
  test("exactly one candidate goes to its board", () => {
    expect(route(undefined, ["agent-runtime"])).toEqual({ kind: "ptask", project: "agent-runtime" });
  });
  test("zero or several go to the inbox", () => {
    expect(route(undefined, []).kind).toBe("inbox");
    const r = route(undefined, ["notes-cockpit", "agent-runtime"]);
    expect(r.kind).toBe("inbox");
    expect(r.kind === "inbox" && r.why).toContain("notes-cockpit, agent-runtime");
  });
});

// The handler as Hunk calls it: a stub `hunk.on`, a fake ctx, and a stub `notes` on PATH
// that records its argv, so the event -> CLI wiring is exercised without a TUI.
describe("note_created handler", () => {
  const { mkdtempSync, writeFileSync, readFileSync, chmodSync, existsSync } = require("node:fs");
  const { join } = require("node:path");
  const { tmpdir } = require("node:os");

  async function fire(body: string, opts: { draft?: boolean; id?: string } = {}) {
    const dir = mkdtempSync(join(tmpdir(), "task-tag-"));
    const log = join(dir, "calls.log");
    writeFileSync(join(dir, "notes"), `#!/bin/sh\nprintf '%s\\n' "$*" >> "${log}"\n`);
    chmodSync(join(dir, "notes"), 0o755);
    const saved = { PATH: process.env.PATH, HOME: process.env.HOME };
    process.env.PATH = `${dir}:${saved.PATH}`;
    process.env.HOME = dir; // no project-name.sh here, so bare #task cannot resolve a board
    const toasts: string[] = [];
    let handler: any;
    const mod = await import("../../.config/hunk/extensions/task-tag.ts");
    mod.default({ on: (ev: string, h: any) => { if (ev === "note_created") handler = h; } } as any);
    try {
      const note = { id: opts.id ?? "n1", body, draft: !!opts.draft, filePath: "src/a.ts", line: 7 };
      await handler({ note }, { cwd: dir, notify: (m: string) => toasts.push(m) });
    } finally {
      process.env.PATH = saved.PATH;
      process.env.HOME = saved.HOME;
    }
    return { calls: existsSync(log) ? readFileSync(log, "utf8").trim() : "", toasts };
  }

  test("#task:<project> adds a #low row to that board", async () => {
    const r = await fire("fix this #task:agent-runtime");
    expect(r.calls).toBe("ptask agent-runtime add fix this (src/a.ts:7) #low");
    expect(r.toasts[0]).toContain("agent-runtime board");
  });

  test("bare #task with no resolvable board goes to the inbox and says why", async () => {
    const r = await fire("look at this #task");
    expect(r.calls).toBe("inbox add look at this (src/a.ts:7)");
    expect(r.toasts[0]).toContain("notes inbox");
  });

  test("an untagged note or a draft files nothing", async () => {
    expect((await fire("just a comment")).calls).toBe("");
    expect((await fire("draft #task:x", { draft: true })).calls).toBe("");
  });
});
