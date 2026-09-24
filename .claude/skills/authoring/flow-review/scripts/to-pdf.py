#!/usr/bin/env python3
"""Render a flow-review README.md to report.pdf beside it.

Usage: to-pdf.py <report-dir>

Handles only the markdown the flow-review template produces (headings,
paragraphs, bullets, bold, inline code, links, images), so it needs no
pandoc. Screenshots stack one per row: a side-by-side strip would be cropped
on paper. Printing is headless Chromium.
"""
import html, os, re, shutil, subprocess, sys, tempfile

CSS = """
@page { size: A4; margin: 16mm 14mm; }
body { font: 11pt/1.5 system-ui, sans-serif; color: #141413; }
h1 { font-size: 22pt; line-height: 1.15; margin: 0 0 6pt; }
h2 { font-size: 16pt; margin: 22pt 0 4pt; border-bottom: 1px solid #ddd; padding-bottom: 3pt; }
h3 { font-size: 12.5pt; margin: 16pt 0 2pt; break-after: avoid; }
p { margin: 4pt 0; }
ul { padding-left: 14pt; margin: 4pt 0; }
li { margin: 3pt 0; break-inside: avoid; }
code { font: 9.5pt ui-monospace, monospace; background: #f0efe9; padding: 0 3pt; border-radius: 3pt; }
img { display: block; max-width: 100%; max-height: 150mm; margin: 6pt 0 2pt; border: 1px solid #ddd; border-radius: 4pt; break-inside: avoid; }
.cap { font: 8.5pt ui-monospace, monospace; color: #666; margin-bottom: 8pt; }
.sev { font: 600 8pt ui-monospace, monospace; padding: 1pt 5pt; border-radius: 3pt; margin-right: 4pt; }
.FIX { background: #fbe9e7; color: #b3261e; } .POLISH { background: #fbf1dc; color: #8a5a00; }
.VERIFY { background: #e6eef9; color: #1d4f91; } .OK { background: #e3f2e8; color: #1e6b3a; }
"""


def inline(s):
    s = html.escape(s, quote=False)
    s = re.sub(r"`([^`]+)`", r"<code>\1</code>", s)
    s = re.sub(r"\*\*(FIX|POLISH|VERIFY|OK)\*\*", r'<span class="sev \1">\1</span>', s)
    s = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", s)
    return re.sub(r"\[([^\]]+)\]\(([^)]+)\)", r'<a href="\2">\1</a>', s)


def render(md):
    out, in_list = [], False
    for line in md.splitlines():
        img = re.fullmatch(r"!\[([^\]]*)\]\(([^)]+)\)", line.strip())
        bullet = line.startswith("- ")
        if in_list and not bullet:
            out.append("</ul>")
            in_list = False
        if img:
            out.append(f'<img src="{html.escape(img.group(2))}" alt="{html.escape(img.group(1))}"><div class="cap">{html.escape(img.group(1))}</div>')
        elif bullet:
            if not in_list:
                out.append("<ul>")
                in_list = True
            out.append(f"<li>{inline(line[2:])}</li>")
        elif m := re.match(r"(#{1,3}) (.*)", line):
            n = len(m.group(1))
            out.append(f"<h{n}>{inline(m.group(2))}</h{n}>")
        elif line.strip():
            out.append(f"<p>{inline(line)}</p>")
    if in_list:
        out.append("</ul>")
    return "\n".join(out)


def main(d):
    d = os.path.abspath(d)
    md = open(os.path.join(d, "README.md"), encoding="utf-8").read()
    title = re.search(r"^# (.*)", md, re.M)
    page = (f'<!doctype html><meta charset="utf-8"><base href="file://{d}/">'
            f"<title>{html.escape(title.group(1) if title else 'report')}</title>"
            f"<style>{CSS}</style>{render(md)}")
    browser = next((b for b in ("chromium", "google-chrome-stable", "chrome") if shutil.which(b)), None)
    if not browser:
        sys.exit("to-pdf: needs chromium on PATH")
    with tempfile.TemporaryDirectory() as tmp:
        src = os.path.join(tmp, "report.html")
        open(src, "w", encoding="utf-8").write(page)
        pdf = os.path.join(d, "report.pdf")
        subprocess.run([browser, "--headless=new", "--disable-gpu", "--no-pdf-header-footer",
                        "--allow-file-access-from-files", "--virtual-time-budget=10000",
                        f"--print-to-pdf={pdf}", f"file://{src}"],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(pdf)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
