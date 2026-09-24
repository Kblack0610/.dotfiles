#!/usr/bin/env python3
"""Convert a flow-review HTML artifact into README.md + shots/ under a ref folder.

Usage: extract-artifact.py <artifact.html> <out-dir>

Expects the flow-review markup: h1/.lede/.meta/.tally header, h2 per surface,
article.step (h3, p.what, li.sev-* notes, figure.shot with a data: URI image),
and an optional #caveats footer. Screenshots are decoded to files because
terminal viewers cannot render base64 embedded in markdown.
"""
import base64, html, os, re, sys
from html.parser import HTMLParser

SEV = {"fix": "FIX", "minor": "POLISH", "check": "VERIFY", "ok": "OK"}


def slug(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")[:40] or "x"


def text(fragment):
    t = re.sub(r"<[^>]+>", "", fragment)
    return re.sub(r"\s+", " ", html.unescape(t)).strip()


def main(src, out):
    doc = open(src, encoding="utf-8").read()
    shots = os.path.join(out, "shots")
    os.makedirs(shots, exist_ok=True)

    def first(pat, s=doc):
        m = re.search(pat, s, re.S)
        return text(m.group(1)) if m else ""

    md = [f"# {first(r'<h1[^>]*>(.*?)</h1>')}", ""]
    for label, pat in (("", r'<p class="eyebrow">(.*?)</p>'), ("", r'<p class="lede">(.*?)</p>')):
        v = first(pat)
        if v:
            md += [v, ""]
    meta = re.search(r'<div class="meta">(.*?)</div>', doc, re.S)
    if meta:
        for span in re.findall(r"<span>(.*?)</span>", meta.group(1), re.S):
            b = re.match(r"\s*<b>(.*?)</b>(.*)", span, re.S)
            md.append(f"- **{text(b.group(1))}** {text(b.group(2))}" if b else f"- {text(span)}")
        md.append("")
    tally = re.search(r'<div class="tally">(.*?)</div>', doc, re.S)
    if tally:
        md += ["**" + " - ".join(text(s) for s in re.findall(r"<span[^>]*>(.*?)</span>", tally.group(1), re.S)) + "**", ""]

    n = 0

    def figures(chunk, title):
        nonlocal n
        for fig in re.findall(r"<figure.*?</figure>", chunk, re.S):
            m = re.search(r'<img src="data:image/(\w+);base64,([^"]+)"', fig)
            if not m:
                continue
            n += 1
            cap = first(r"<figcaption>(.*?)</figcaption>", fig) or "shot"
            ext = "jpg" if m.group(1) == "jpeg" else m.group(1)
            name = f"{n:02d}-{slug(title)}-{slug(cap)}.{ext}"
            with open(os.path.join(shots, name), "wb") as f:
                f.write(base64.b64decode(m.group(2)))
            md.append(f"![{cap}](shots/{name})")

    body = doc.split('<div class="foot"')[0]
    for chunk in re.split(r"(?=<h2 )|(?=<article )", body)[1:]:
        if chunk.startswith("<h2"):
            md += [f"## {first(r'<h2[^>]*>(.*?)</h2>', chunk)}", ""]
            lede = first(r'<p class="sec-lede">(.*?)</p>', chunk)
            if lede:
                md += [lede.replace(" Click any screenshot for full size.", ""), ""]
            figures(chunk, first(r'<h2[^>]*>(.*?)</h2>', chunk))
            md.append("")
            continue
        num = first(r'<span class="stepno">(.*?)</span>', chunk)
        title = first(r"<h3>(.*?)</h3>", chunk)
        md += [f"### {num}. {title}", "", first(r'<p class="what">(.*?)</p>', chunk), ""]
        for cls, body_ in re.findall(r'<li class="sev-(\w+)"><span class="sev">.*?</span><span>(.*?)</span></li>', chunk, re.S):
            md.append(f"- **{SEV.get(cls, cls.upper())}** {text(body_)}")
        md.append("")
        figures(chunk, title)
        md.append("")

    foot = re.search(r'<div class="foot"[^>]*>(.*?)</div>', doc, re.S)
    if foot:
        md += ["## What this is not", ""]
        for p in re.findall(r"<p>(.*?)</p>", foot.group(1), re.S):
            md += [re.sub(r"^What this is not\.\s*", "", text(p)), ""]

    out_md = re.sub(r"\n{3,}", "\n\n", "\n".join(md)).strip() + "\n"
    open(os.path.join(out, "README.md"), "w", encoding="utf-8").write(out_md)
    print(f"{out}/README.md: {n} screenshots")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    main(sys.argv[1], sys.argv[2])
