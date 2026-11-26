"""Download the web-kit files a site's kit.lock pins and check each against the lock's sha256.

    python3 fetch-kit.py <kit.lock> <dest dir> [--url <template>]

The lock pins one dotfiles commit and a sha256 per kit file (README.md, "Who uses it"). A file whose
hash does not match fails the run before it is written, so an image build fails on a bad checksum.
A site's Dockerfile fetches this file at its pinned commit with `ADD --checksum=sha256:<h>`, and
`kit-lock bump` keeps that hash and the lock in step. Stdlib only: a site needs no pip package.
--url replaces the raw GitHub template ({repo} {commit} {path} {name} from the lock), for a mirror
or a file:// tree in a test.
"""
import argparse
import hashlib
import http.client
import json
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

URL = "https://raw.githubusercontent.com/{repo}/{commit}/{path}/{name}"
TRIES = 4
BACKOFF_S = 5
RETRY_CODES = {408, 429}  # with every 5xx: a timeout or a rate limit clears on a later try


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fetch(lock: dict, dest: Path, url: str = URL, get=None, sleep=time.sleep) -> None:
    raw = get or (lambda u: urllib.request.urlopen(u, timeout=30).read())

    def get_retried(u):
        # raw.githubusercontent.com answers 503 "max_conn reached" under load; that failed trader's build once.
        # Any other 4xx (a wrong commit or name) will not change on a retry, so it fails at once. OSError
        # covers URLError, a timeout and a reset mid-body; HTTPException an IncompleteRead or a dropped link.
        for attempt in range(1, TRIES + 1):
            try:
                return raw(u)
            except urllib.error.HTTPError as e:
                if (e.code < 500 and e.code not in RETRY_CODES) or attempt == TRIES:
                    raise
            except (OSError, http.client.HTTPException):
                if attempt == TRIES:
                    raise
            sleep(BACKOFF_S * attempt)

    got = {}
    for name, want in lock["files"].items():
        if name != Path(name).name or name in (".", ".."):
            raise SystemExit(f"kit file {name!r} is not a bare file name; the kit is one flat directory")
        data = get_retried(url.format(name=name, **lock))
        if sha256(data) != want:
            raise SystemExit(f"kit file {name} does not match the lock (got {sha256(data)}, want {want})")
        got[name] = data
    # Written only once every file matched, so a failed fetch leaves no half-moved kit behind.
    dest.mkdir(parents=True, exist_ok=True)
    for name, data in got.items():
        (dest / name).write_bytes(data)


def main(argv=None) -> None:
    ap = argparse.ArgumentParser(description="Fetch the web-kit files a kit.lock pins, checked by sha256.")
    ap.add_argument("lock", type=Path)
    ap.add_argument("dest", type=Path)
    ap.add_argument("--url", default=URL, help="file URL template (default: raw GitHub)")
    a = ap.parse_args(argv)
    lock = json.loads(a.lock.read_text())
    fetch(lock, a.dest, a.url)
    print(f"web-kit {lock['commit'][:9]} -> {a.dest}", file=sys.stderr)


if __name__ == "__main__":
    main()
