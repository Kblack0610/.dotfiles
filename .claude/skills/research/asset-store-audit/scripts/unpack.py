#!/usr/bin/env python3
"""Unpack every .unitypackage under a cache dir WITHOUT importing, for audit.

usage: unpack.py <cache_dir> <out_dir> [-j N]

Writes <out>/pkgs/<Pack>/manifest.json (every path, guid, size) and
<out>/pkgs/<Pack>/files/<original path> for text assets (.mat .prefab .cs
.shader .shadergraph .asmdef .controller readmes ...) plus FBX .meta files.
Nested per-pipeline sub-packages (URP variants, effect add-ons) are pulled
out and unpacked into <out>/pkgs/<Pack>/nested/<sub>/ the same way.
A .unitypackage is a tar.gz of <guid>/{pathname,asset,asset.meta}.
"""
import sys, os, re, json, shutil, tarfile, argparse
from concurrent.futures import ProcessPoolExecutor

KEEP = {'.mat', '.cs', '.shader', '.shadergraph', '.shadersubgraph', '.asmdef', '.txt', '.md',
        '.json', '.hlsl', '.cginc', '.asset', '.prefab', '.controller', '.rtf'}
MAXKEEP = 3_000_000
# Nested sub-packages worth unpacking: the URP variant and effect add-ons.
NESTED_WANT = re.compile(r'URP|UNPACK', re.I)
NESTED_MAX = 400_000_000


def pack_name(path):
    return re.sub(r'[^A-Za-z0-9_-]', '', os.path.basename(path)[:-len('.unitypackage')].replace(' ', '_'))


def extract(src, out, want_guids=None):
    """Stream one package. With want_guids, return {guid: bytes} for those assets too."""
    paths, sizes, blobs, grabbed = {}, {}, {}, {}
    with tarfile.open(src, 'r|gz') as t:
        for m in t:
            if not m.isfile():
                continue
            parts = m.name.lstrip('./').split('/')
            if len(parts) != 2:
                continue
            g, kind = parts
            if kind == 'pathname':
                paths[g] = t.extractfile(m).read().decode('utf-8', 'replace').splitlines()[0].strip()
            elif kind == 'asset':
                sizes[g] = m.size
                if m.size <= MAXKEEP:
                    blobs[g] = t.extractfile(m).read()
                elif m.size <= NESTED_MAX:
                    # may be a nested package; decide once pathname is known
                    blobs['big:' + g] = t.extractfile(m).read()
            elif kind == 'asset.meta':
                blobs[g + '.meta'] = t.extractfile(m).read()
    os.makedirs(out, exist_ok=True)
    manifest, nested, big = [], [], {}
    for g, p in paths.items():
        ext = os.path.splitext(p)[1].lower()
        manifest.append({'guid': g, 'path': p, 'size': sizes.get(g)})
        b = blobs.get(g)
        if ext == '.unitypackage' and NESTED_WANT.search(os.path.basename(p)):
            b = b if b is not None else blobs.get('big:' + g)
            if b is not None:
                dst = os.path.join(out, '_nested_src', os.path.basename(p).replace(' ', '_'))
                os.makedirs(os.path.dirname(dst), exist_ok=True)
                open(dst, 'wb').write(b)
                nested.append(dst)
            elif sizes.get(g):
                big[g] = os.path.join(out, '_nested_src', os.path.basename(p).replace(' ', '_'))
            continue
        if b is not None and ext in KEEP:
            if ext == '.asset' and not b.startswith(b'%YAML'):
                continue
            dst = os.path.join(out, 'files', p)
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            open(dst, 'wb').write(b)
        if ext == '.fbx' and (g + '.meta') in blobs:
            dst = os.path.join(out, 'files', p + '.meta')
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            open(dst, 'wb').write(blobs[g + '.meta'])
    if big:
        # Sub-packages over NESTED_MAX (URP variants of 1 GB+) are too big to hold in
        # memory: stream the archive again and copy just those to disk.
        os.makedirs(os.path.join(out, '_nested_src'), exist_ok=True)
        with tarfile.open(src, 'r|gz') as t:
            for m in t:
                parts = m.name.lstrip('./').split('/')
                if m.isfile() and len(parts) == 2 and parts[1] == 'asset' and parts[0] in big:
                    with open(big[parts[0]], 'wb') as fh:
                        shutil.copyfileobj(t.extractfile(m), fh, 1 << 20)
        nested += list(big.values())
    json.dump(manifest, open(os.path.join(out, 'manifest.json'), 'w'), indent=0)
    return nested


def job(args):
    src, out = args
    nested = extract(src, out)
    for n in nested:
        extract(n, os.path.join(out, 'nested', os.path.basename(n)[:-len('.unitypackage')]))
        os.remove(n)
    return f'{pack_name(src)}: {len(json.load(open(os.path.join(out, "manifest.json"))))} entries, {len(nested)} nested'


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('cache'); ap.add_argument('out'); ap.add_argument('-j', type=int, default=8)
    a = ap.parse_args()
    srcs = []
    for root, _, fs in os.walk(a.cache):
        srcs += [os.path.join(root, f) for f in fs if f.endswith('.unitypackage')]
    jobs = [(s, os.path.join(a.out, 'pkgs', pack_name(s))) for s in sorted(srcs)]
    with ProcessPoolExecutor(a.j) as ex:
        for line in ex.map(job, jobs):
            print(line, flush=True)
