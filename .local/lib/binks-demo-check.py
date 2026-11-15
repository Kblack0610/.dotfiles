#!/usr/bin/env python3
"""binks-demo check: run one html page the way a binks demo runs, in a headless scratch Firefox.

usage: binks-demo check <file.html> [--shot <png>] [--width PX] [--height PX]

The page loads inside the same frame a published demo and the chat preview give it: a wrapper with
`default-src 'none'` holding the page in a srcdoc iframe sandboxed to `allow-scripts
allow-pointer-lock` (an opaque origin: no storage, no cookies), with the demo CSP first in the page
(no network, no outside scripts, styles, fonts or images). It fails on a JavaScript error, an
unhandled rejection, a CSP violation, a missing <title>, a page over the publish cap, or a page that
drew nothing. --shot saves a screenshot of the viewport to look at.
"""
import argparse
import base64
import html
import os
import pathlib
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from marionette import scratch_firefox  # noqa: E402

# The demo sandbox and CSP, as binks-api apps/binks/api/src/demos/page.ts (DEMO_SANDBOX, DEMO_CSP)
# and binks-chat src/lib/preview.ts serve them; their tests keep those two equal, and this copy
# follows them by hand.
SANDBOX = "allow-scripts allow-pointer-lock"
CSP = "; ".join([
    "default-src 'none'", "script-src 'unsafe-inline'", "style-src 'unsafe-inline'",
    "img-src data: blob:", "media-src data: blob:", "font-src data:", "connect-src 'none'",
    "base-uri 'none'", "form-action 'none'",
])
CSP_META = f'<meta http-equiv="Content-Security-Policy" content="{CSP}">'
# binks-api PUBLISH_MAX_BYTES default; a bigger page is refused with a 413.
MAX_BYTES = 1024 * 1024
TITLE_SCAN = 8192  # the server reads the title from this prefix only, counted in UTF-16 units (a JS string)

# Right after the page's own doctype (if any), on its first line, so error line numbers and the
# page's standards or quirks mode stay its own.
PROBE = (
    "<script>window.__bd={errors:[],csp:[]};"
    "addEventListener('error',e=>__bd.errors.push(e.message?`${e.message} (line ${e.lineno})`"
    ":`could not load ${(e.target&&(e.target.src||e.target.href))||'a resource'}`),true);"
    "addEventListener('unhandledrejection',e=>__bd.errors.push('unhandled rejection: '+"
    "((e.reason&&e.reason.message)||e.reason)));"
    "document.addEventListener('securitypolicyviolation',e=>__bd.csp.push("
    "`${e.effectiveDirective} blocked ${e.blockedURI||'inline code'}`));</script>"
)

# Runs in the page's frame once it has loaded: two animation frames let a game draw its first
# frame, then it reports what ran and what drew.
REPORT = r"""
const done = arguments[arguments.length - 1];
requestAnimationFrame(() => requestAnimationFrame(() => {
  const seen = (el) => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
  const canvases = [...document.querySelectorAll("canvas")].filter(seen).map((c) => {
    let ctx = null;
    try { ctx = c.getContext("2d"); } catch (e) {}
    if (!ctx) return "webgl";
    if (!c.width || !c.height) return "blank";
    let d;
    try { d = ctx.getImageData(0, 0, c.width, c.height).data; } catch (e) { return "unreadable"; }
    for (let i = 3; i < d.length; i += 4) if (d[i]) return "drew";
    return "blank";
  });
  const media = [...document.querySelectorAll("svg, img, video")].some(seen);
  const text = (document.body ? document.body.innerText : "").trim().length;
  // Each policy in force reports a violation, the wrapper's and the page's: one line per kind.
  const once = (xs) => [...new Set(xs)];
  done({ errors: once(window.__bd.errors), csp: once(window.__bd.csp), canvases, media, text });
}));
"""
REPORT_TIMEOUT_MS = 20000


def frame(page):
    """The wrapper document: the demo CSP, and the page in a sandboxed srcdoc frame."""
    m = re.match(r"\s*<!doctype[^>]*>", page, re.I)
    head = m.group(0) if m else ""
    inner = head + CSP_META + PROBE + page[len(head):]
    return ("<!doctype html><html><head>" + CSP_META +
            "<style>html,body,iframe{display:block;margin:0;border:0;width:100%;height:100%}</style>"
            f'</head><body><iframe sandbox="{SANDBOX}" srcdoc="{html.escape(inner, quote=True)}"></iframe></body></html>')


def main():
    ap = argparse.ArgumentParser(prog="binks-demo check", description=__doc__.split("\n\n")[0])
    ap.add_argument("file")
    ap.add_argument("--shot", help="save a viewport screenshot here (png)")
    ap.add_argument("--width", type=int, default=1280)
    ap.add_argument("--height", type=int, default=800)
    a = ap.parse_args()
    raw = open(a.file, "rb").read()
    fails = []
    if len(raw) > MAX_BYTES:
        fails.append(f"the page is {len(raw)} bytes; a demo can be at most {MAX_BYTES}")
    page = raw.decode("utf-8", errors="replace")
    # As binks-api demoTitle reads it: the first <title> in the prefix, control chars and spaces collapsed.
    prefix = page.encode("utf-16-le")[: TITLE_SCAN * 2].decode("utf-16-le", errors="ignore")
    t = re.search(r"<title[^>]*>([\s\S]*?)</title>", prefix, re.I)
    if not (t and re.sub(r"[\x00-\x1f\x7f-\x9f\s]+", " ", t.group(1)).strip()):
        fails.append(f"no <title> in the first {TITLE_SCAN} characters: the demo would be named 'Untitled demo'")

    r = None
    with scratch_firefox("binks-demo", a.width, a.height, script_timeout_ms=REPORT_TIMEOUT_MS) as m:
        wrapper = os.path.join(m.profile, "demo.html")
        with open(wrapper, "w") as f:
            f.write(frame(page))
        try:
            m.cmd("WebDriver:Navigate", url=pathlib.Path(wrapper).as_uri())
            el = m.cmd("WebDriver:FindElement", using="css selector", value="iframe")["value"]
            m.cmd("WebDriver:SwitchToFrame", element=next(iter(el.values())))
            r = m.cmd("WebDriver:ExecuteAsyncScript", script=REPORT)["value"]
            if a.shot:
                m.cmd("WebDriver:SwitchToParentFrame")
                with open(a.shot, "wb") as out:
                    out.write(base64.b64decode(m.cmd("WebDriver:TakeScreenshot")["value"]))
        except RuntimeError as e:  # a Marionette command failed: a script timeout, or the page navigated away
            fails.append(f"the check could not finish: {e}")

    if r:
        fails += [f"error: {e}" for e in r["errors"]]
        fails += [f"csp: {c} (a demo has no network: inline it, or use data: URLs)" for c in r["csp"]]
        if not (r["text"] or r["media"] or any(c != "blank" for c in r["canvases"])):
            fails.append("the page drew nothing: no text, no image or svg, and every canvas is blank")
        print(f"canvases: {', '.join(r['canvases']) or 'none'}; text: {r['text']} chars")
    if a.shot and r:
        print(f"screenshot: {a.shot}")
    for line in fails:
        print(f"FAIL {line}")
    print("FAIL" if fails else "PASS")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
