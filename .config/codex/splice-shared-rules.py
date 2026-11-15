#!/usr/bin/env python3
"""Fill a rulesync overview.md from the global CLAUDE.md, the one source of the shared rules.

    splice-shared-rules.py <overview.md> <CLAUDE.md>
    splice-shared-rules.py --check <overview.md> <CLAUDE.md> <AGENTS.md>

Each `<!-- shared: <section> -->` line in overview.md becomes that section of CLAUDE.md, verbatim,
in place. overview.md stays free of the shared text, so the two cannot drift: 6 of 7 shared sections
had when each was kept by hand. The sync runs this on its staged copy, never on the tracked file.
A section runs from its `## ` heading to the next `## ` heading or `---` rule, and a marker matches a
heading by its leading words, so "Writing Style" finds "Writing Style (all artifacts: ...)".
A marker with no section exits 1: rulesync would ship the comment without a word.
--check writes nothing: it exits 1 listing each non-blank line of the spliced body (frontmatter
dropped, as rulesync drops it) that is not a line of <AGENTS.md>, the generated file a repo tracks.
The private repo's pre-commit and tests/unit/rules_shared_block.bats run it, so a shared-section
edit cannot land without the regenerated opencode AGENTS.md (it once did: ar-1404).
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


def splice(text: list[str], source: Path) -> list[str] | None:
    """overview.md lines with each marker replaced by its section; None once a fault is reported."""
    if not any(MARKER.match(line) for line in text):
        return text
    if not source.is_file():
        print(f"overview.md has shared markers and there is no {source}", file=sys.stderr)
        return None
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
        return None
    return out


def stale_lines(spliced: list[str], generated: Path) -> list[str]:
    """Non-blank lines of the spliced body, past the frontmatter, that are not lines of generated."""
    lines = "\n".join(spliced).splitlines()
    if lines and lines[0] == "---":
        end = next((i for i in range(1, len(lines)) if lines[i] == "---"), None)
        if end is not None:
            lines = lines[end + 1 :]
    have = set(generated.read_text().splitlines())
    return [line for line in lines if line.strip() and line not in have]


def main() -> int:
    args = sys.argv[1:]
    check = args[:1] == ["--check"]
    if check:
        args = args[1:]
    if len(args) != (3 if check else 2):
        print(__doc__, file=sys.stderr)
        return 2
    overview, source = Path(args[0]), Path(args[1])
    out = splice(overview.read_text().splitlines(), source)
    if out is None:
        return 1
    if not check:
        overview.write_text("\n".join(out) + "\n")
        return 0
    stale = stale_lines(out, Path(args[2]))
    if stale:
        print(f"{args[2]} lacks {len(stale)} line(s) of the current rules; re-run the sync into it:", file=sys.stderr)
        for line in stale:
            print(f"    {line}", file=sys.stderr)
    return 1 if stale else 0


if __name__ == "__main__":
    sys.exit(main())
