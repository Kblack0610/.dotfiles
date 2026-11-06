// Pure-function tests for .config/hunk/extensions/agent-request.ts. Lives here, not beside the
// extension: every *.ts in ~/.config/hunk/extensions/ is loaded by Hunk as an extension.
import { describe, expect, test } from "bun:test";
import { addArgs, candidates } from "../../.config/hunk/extensions/agent-request.ts";

const files = [{ fileKey: "k1", path: "cfg/a.json" }] as any;
const note = (over: object) =>
  ({ id: "n1", source: "user", fileKey: "k1", summary: "raise it", resolution: "active", anchor: { intersectingHunkIndices: [] }, ...over }) as any;

describe("addArgs", () => {
  test("a user note on new lines becomes one add with its range and id", () => {
    const n = note({ anchor: { newRange: [4, 6], preferred: { side: "new", line: 4 }, intersectingHunkIndices: [0] } });
    expect(addArgs({ files, notes: [n] }, "/r")).toEqual([
      ["add", "--file", "/r/cfg/a.json", "--line", "4", "--end", "6", "--id", "hunk:n1", "--", "raise it"],
    ]);
  });

  test("agent and ai notes, orphaned notes and unknown files are skipped", () => {
    const notes = [
      note({ id: "a", source: "agent", anchor: { newRange: [1, 1], intersectingHunkIndices: [] } }),
      note({ id: "b", source: "ai", anchor: { newRange: [1, 1], intersectingHunkIndices: [] } }),
      note({ id: "c", resolution: "orphaned", anchor: { newRange: [1, 1], intersectingHunkIndices: [] } }),
      note({ id: "d", fileKey: "nope", anchor: { newRange: [1, 1], intersectingHunkIndices: [] } }),
    ];
    expect(addArgs({ files, notes }, "/r")).toEqual([]);
  });

  test("a note on a removed line says so and carries no range", () => {
    const n = note({ anchor: { oldRange: [9, 12], preferred: { side: "old", line: 9 }, intersectingHunkIndices: [0] } });
    const [args] = addArgs({ files, notes: [n] }, "/r");
    expect(args).not.toContain("--end");
    expect(args.at(-1)).toBe("(on the old side of the diff) raise it");
    expect(args[4]).toBe("9");
  });

  test("a title leads the text", () => {
    const n = note({ title: "spawn", anchor: { newRange: [2, 2], intersectingHunkIndices: [] } });
    expect(addArgs({ files, notes: [n] }, "/r")[0].at(-1)).toBe("spawn: raise it");
  });
});

describe("candidates", () => {
  test("refused-send rows become pane choices", () => {
    expect(candidates("hub/%7\thub/x:1\tediting\nhub/%8\thub/y:2\t\n")).toEqual([
      { pane: "hub/%7", label: "hub/x:1  editing" },
      { pane: "hub/%8", label: "hub/y:2" },
    ]);
  });
});
