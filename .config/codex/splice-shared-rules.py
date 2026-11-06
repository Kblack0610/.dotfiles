#!/usr/bin/env python3
"""Fill a rulesync overview.md from the global CLAUDE.md, the one source of the shared rules.

    splice-shared-rules.py <overview.md> <CLAUDE.md>

Each `<!-- shared: <section> -->` line in overview.md becomes that section of CLAUDE.md, verbatim,
in place. overview.md stays free of the shared text, so the two cannot drift: 6 of 7 shared sections
had when each was kept by hand. The sync runs this on its staged copy, never on the tracked file.
A section runs from its `## ` heading to the next `## ` heading or `---` rule, and a marker matches a
heading by its leading words, so "Writing Style" finds "Writing Style (all artifacts: ...)".
A marker with no section exits 1: rulesync would ship the comment without a word.
"""
import re
import sys
from pathlib import Path

MARKER = re.compile(r"^<!-- shared: (.+?) -->$")


def section(lines: list[str], name: str) -> str | None:
    start = next(
        (i for i, line in enumerate(lines) if line == f"## {name}" or line.startswith(f"## {name} ")),
        None,
    )
    if start is None:
        return None
    end = next(
        (i for i in range(start + 1, len(lines)) if lines[i].startswith("## ") or lines[i] == "---"),
        len(lines),
    )
    return "\n".join(lines[start:end]).rstrip()


def main() -> int:
    if len(sys.argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    overview, source = Path(sys.argv[1]), Path(sys.argv[2])
    text = overview.read_text().splitlines()
    if not any(MARKER.match(line) for line in text):
        return 0
    if not source.is_file():
        print(f"overview.md has shared markers and there is no {source}", file=sys.stderr)
        return 1
    lines = source.read_text().splitlines()
    out, missing = [], []
    for line in text:
        marker = MARKER.match(line)
        if not marker:
            out.append(line)
            continue
        body = section(lines, marker.group(1))
        if body is None:
            missing.append(marker.group(1))
        else:
            out.append(body)
    if missing:
        print(f"no section in {source}: {', '.join(missing)}", file=sys.stderr)
        return 1
    overview.write_text("\n".join(out) + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
