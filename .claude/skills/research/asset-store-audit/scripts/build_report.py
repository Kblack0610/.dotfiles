#!/usr/bin/env python3
"""Assemble the report page from verdict JSONs + a synthesis HTML fragment.

usage: build_report.py <out_dir> <synth.html> <report.html>
Reads <out_dir>/verdicts/*.json, injects them and the synthesis into
assets/report-template.html (next to this script's skill dir), checks every
pack in <out_dir>/facts has a verdict and every verdict is plain ASCII.
"""
import sys, os, json, glob
out, synth, dst = sys.argv[1:4]
tpl = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'assets', 'report-template.html')
facts = {os.path.basename(f)[:-5] for f in glob.glob(os.path.join(out, 'facts', '*.json'))}
packs, problems = [], []
for f in sorted(glob.glob(os.path.join(out, 'verdicts', '*.json'))):
    raw = open(f, encoding='utf-8').read()
    if any(ord(c) > 127 for c in raw): problems.append('non-ASCII: ' + f)
    d = json.loads(raw); d['key'] = os.path.basename(f)[:-5]; packs.append(d)
missing = facts - {p['key'] for p in packs}
if missing: problems.append('no verdict for: ' + ', '.join(sorted(missing)))
if problems:
    sys.exit('\n'.join(problems))
counts = {}
for p in packs: counts[p['verdict']] = counts.get(p['verdict'], 0) + 1
page = open(tpl).read().replace('/*DATA*/', json.dumps(packs).replace('</', '<\\/')).replace('<!--SYNTH-->', open(synth).read())
page = page.replace('/*COUNT*/', str(len(packs)))
open(dst, 'w').write(page)
print(f'{len(packs)} packs -> {dst}; verdict counts {counts} (use these exact numbers in the synthesis)')
