#!/usr/bin/env python3
"""Batch-only reds in one Tests run: classes that did not pass in their batch and passed alone.

Reads the suite folders `suite.sh` leaves in a run's `test-runs-playmode-*` artifacts
(`batch-N.txt` says which classes did not pass in batch N; `summary.txt` has each class's
last word). Give it a run id to download them, or `--dir` for folders already downloaded.

  batch-only.py --run 41615761653          # from inside the repo; --repo OWNER/NAME elsewhere
  batch-only.py --dir ./downloaded --json
"""
import argparse
import json
import pathlib
import re
import subprocess
import sys
import tempfile

LEFT = re.compile(r"^\s+(\S+) did not pass in batch (\S+); running it alone")
LEFT_FIRST = re.compile(r"^\s+(\S+) did not pass in batch (\S+); running it alone, the other")
RESULT = re.compile(r"^(ok|FAIL|SKIPPED|UNCONFIRMED)\s+(\S+)")


def read(root):
    """Per class short name: the batch it did not pass in, and its last result."""
    left, last = {}, {}
    for suite in sorted(p.parent for p in root.rglob("summary.txt") if p.parent.name.startswith("suite-")):
        for batch in sorted(suite.glob("batch-*.txt")):
            for line in batch.read_text(errors="replace").splitlines():
                m = LEFT_FIRST.match(line) or LEFT.match(line)
                if m:
                    left.setdefault(m.group(1).rsplit(".", 1)[-1], m.group(2))
        for line in (suite / "summary.txt").read_text(errors="replace").splitlines():
            m = RESULT.match(line)
            if m:
                last[m.group(2)] = m.group(1)
    return left, last


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", help="OWNER/NAME; default: the repo gh sees in the current directory")
    ap.add_argument("--run", help="a Tests run id; its test-runs-playmode-* artifacts are downloaded")
    ap.add_argument("--dir", help="folders already downloaded")
    ap.add_argument("--json", action="store_true")
    a = ap.parse_args()
    if not a.run and not a.dir:
        ap.error("give --run or --dir")
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(a.dir or tmp)
        if a.run:
            subprocess.run(["gh", "run", "download", a.run, *(["-R", a.repo] if a.repo else []), "-p", "test-runs-playmode-*", "-D", tmp],
                           check=True, stdout=subprocess.DEVNULL)
        left, last = read(root)
    total = len(last)
    rows = [{"class": c, "batch": b, "alone": last.get(c, "missing")} for c, b in sorted(left.items())]
    only = [r for r in rows if r["alone"] == "ok"]
    if a.json:
        json.dump({"classes": total, "not_passed_in_batch": len(rows), "batch_only": len(only), "rows": rows}, sys.stdout, indent=1)
        print()
        return
    print(f"classes {total}, did not pass in batch {len(rows)}, of them passed alone (batch-only) {len(only)}")
    for r in rows:
        print(f"  {r['alone']:<11} {r['class']}  (batch {r['batch']})")


if __name__ == "__main__":
    main()
