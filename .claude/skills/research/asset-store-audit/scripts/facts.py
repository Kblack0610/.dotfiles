#!/usr/bin/env python3
"""Deterministic per-pack fact sheet from unpack.py output.

usage: facts.py <out_dir>   -> <out_dir>/facts/<Pack>.json

Material shaders are resolved by GUID: builtin (fileID in the f000... guid), URP
(known GUIDs), the pack's own .shader/.shadergraph, or external. The remap summary
says how many a Standard/Legacy/Mobile/Unlit -> URP remap could convert.
Binary-serialized assets (no %YAML header) are reported with their authoring version.
"""
import json, os, re, glob, collections
BUILTIN = {46:'Standard',45:'Standard (Specular setup)',7:'Legacy/Diffuse',200:'Sprites/Default',10750:'Legacy? (10750)',10752:'Unlit/Texture',10751:'Unlit/Color',10753:'Unlit/Transparent',10720:'Particles/Standard Unlit',10721:'Particles/Standard Surface',203:'Particles/*legacy',211:'Particles/Standard Unlit',10703:'Mobile/Diffuse',10704:'Mobile/Bumped Diffuse',4:'Legacy/Bumped Diffuse'}
URP = {'933532a4fcc9baf4fa0491de14d08ed7':'URP/Lit','8d2bb70cbf9db8d4da26e15b26e74248':'URP/SimpleLit','650dd9526735d5b46b79224bc6e94025':'URP/Unlit','b7839dad95683814aa64166edc107ae2':'URP/Particles/Lit','0406db5a14f94604a8c57ccfbc9f3b46':'URP/Particles/Unlit','8516d7a69675844a7a0b7095af7c46af':'URP/Particles/SimpleLit','e6e9a19c3678ded42a3bc431ebef7dbd':'URP/2D/Sprite-Lit-Default','34ed1c7d1b8f4b5a8b0a11f8b3b0a8ff':'URP/TerrainLit','69c1f799e772cb6438f56c23efccb782':'URP/TerrainLit','c579b0fa0d7e2f848ae6b12b0ac2d4a6':'URP/Terrain?'}
HDRP_LIT='6e4ae4064600d784cac1e41a9e6f2e59'
REMAPPABLE={'Standard','Standard (Specular setup)','Legacy/Diffuse','Legacy/Bumped Diffuse','Mobile/Diffuse','Mobile/Bumped Diffuse','Unlit/Texture','Unlit/Color','Unlit/Transparent','Sprites/Default'}
def ext(p): return os.path.splitext(p)[1].lower()
def analyze(root, manifest):
    f = {}
    files = os.path.join(root,'files')
    byext = collections.Counter(); bytesby = collections.Counter()
    for e in manifest:
        x = ext(e['path']) or '(dir)'
        if e['size'] is None: continue
        byext[x]+=1; bytesby[x]+=e['size']
    f['entries']=len(manifest)
    f['total_mb']=round(sum(e['size'] or 0 for e in manifest)/1048576,1)
    f['by_ext']={k:[v,round(bytesby[k]/1048576,1)] for k,v in byext.most_common(25)}
    roots=collections.Counter('/'.join(e['path'].split('/')[:2]) for e in manifest if e['size'])
    f['top_folders']=dict(roots.most_common(6))
    f['sub_folders']=dict(collections.Counter('/'.join(e['path'].split('/')[:4]) for e in manifest if e['size']).most_common(25))
    guid2path={e['guid']:e['path'] for e in manifest}
    # shader names in pack
    shadernames={}
    for e in manifest:
        if ext(e['path'])=='.shader':
            p=os.path.join(files,e['path'])
            try:
                m=re.search(r'Shader\s+"([^"]+)"',open(p,errors='replace').read()); shadernames[e['guid']]=m.group(1) if m else e['path']
            except: shadernames[e['guid']]=e['path']
        elif ext(e['path']) in ('.shadergraph','.shadersubgraph'):
            shadernames[e['guid']]='ShaderGraph:'+os.path.basename(e['path'])
    f['custom_shaders']=sorted(set(shadernames.values()))[:40]
    f['custom_shader_count']=len(shadernames)
    mats=collections.Counter(); remap=collections.Counter()
    for e in manifest:
        if ext(e['path'])!='.mat': continue
        p=os.path.join(files,e['path'])
        if not os.path.exists(p): mats['(not extracted)']+=1; continue
        t=open(p,errors='replace').read()
        m=re.search(r'm_Shader:\s*\{fileID:\s*(-?\d+)(?:,\s*guid:\s*([0-9a-f]+))?',t)
        if not m: mats['(none)']+=1; continue
        fid,g=int(m.group(1)),m.group(2)
        if g=='0000000000000000f000000000000000': name='builtin:'+BUILTIN.get(fid,str(fid))
        elif g in URP: name=URP[g]
        elif g==HDRP_LIT: name='HDRP/Lit'
        elif g in shadernames: name='pack:'+shadernames[g]
        elif g in guid2path: name='pack-path:'+guid2path[g]
        else: name='external:'+str(g)
        mats[name]+=1
        if name.startswith('builtin:'): remap['builtin_remappable' if name[8:] in REMAPPABLE else 'builtin_not_remappable']+=1
        elif name.startswith('URP'): remap['already_urp']+=1
        else: remap['custom_or_external']+=1
    f['material_shaders']=dict(mats.most_common(20)); f['material_remap_summary']=dict(remap)
    # scripts
    cs=[e['path'] for e in manifest if ext(e['path'])=='.cs']
    ns=collections.Counter(); usings=collections.Counter(); flags=collections.Counter(); loc=0
    for p in cs:
        fp=os.path.join(files,p)
        if not os.path.exists(fp): continue
        t=open(fp,errors='replace').read(); loc+=t.count('\n')
        for m in re.findall(r'^\s*namespace\s+([\w\.]+)',t,re.M): ns[m]+=1
        if not re.search(r'^\s*namespace\s',t,re.M): flags['no_namespace']+=1
        for m in re.findall(r'^\s*using\s+([\w\.]+)\s*;',t,re.M):
            if not m.startswith(('System','UnityEngine','UnityEditor','Unity.')): usings[m]+=1
        if re.search(r'\bInput\.(GetKey|GetAxis|GetButton|GetMouse)',t): flags['legacy_Input']+=1
        if 'UnityEngine.InputSystem' in t: flags['new_InputSystem']+=1
        if re.search(r'\bFindObjectOfType\b|GameObject\.Find\(',t): flags['Find_calls']+=1
        if 'PhotonNetwork' in t or 'Mirror' in t or 'FishNet' in t: flags['networking_refs']+=1
        if '/Editor/' in p: flags['in_Editor_folder']+=1
        if 'OnGUI' in t: flags['OnGUI']+=1
        if 'Obsolete' in t or 'FindObjectsOfType' in t: flags['deprecated_api']+=1
    f['scripts']={'count':len(cs),'loc':loc,'namespaces':dict(ns.most_common(12)),'third_party_usings':dict(usings.most_common(15)),'flags':dict(flags)}
    f['asmdefs']=[e['path'] for e in manifest if ext(e['path'])=='.asmdef'][:15]
    # prefabs
    pf=[e['path'] for e in manifest if ext(e['path'])=='.prefab']
    comp=collections.Counter(); variants=0; nested=0
    for p in pf:
        fp=os.path.join(files,p)
        if not os.path.exists(fp): comp['(too big)']+=1; continue
        t=open(fp,errors='replace').read()
        for c in ('LODGroup','MeshCollider','BoxCollider','CapsuleCollider','Rigidbody','Animator','ParticleSystem','Light','AudioSource','MonoBehaviour','SkinnedMeshRenderer','NavMeshObstacle'):
            if re.search(r'^'+c+r':',t,re.M): comp[c]+=1
        if 'm_SourcePrefab' in t and 'PrefabInstance:' in t: nested+=1
    f['prefabs']={'count':len(pf),'with_component':dict(comp),'contain_prefab_instances':nested,'sample_names':[os.path.basename(p) for p in pf[:25]]}
    # fbx metas
    fb=[e['path'] for e in manifest if ext(e['path']) in ('.fbx','.obj','.blend')]
    sc=collections.Counter(); anim=0; rig=collections.Counter()
    for p in fb:
        fp=os.path.join(files,p+'.meta')
        if not os.path.exists(fp): continue
        t=open(fp,errors='replace').read()
        m=re.search(r'globalScale:\s*([\d\.e-]+)',t); u=re.search(r'useFileScale:\s*(\d)',t)
        sc[(m.group(1) if m else '?')+('/fileScale' if u and u.group(1)=='1' else '')]+=1
        a=re.search(r'animationType:\s*(\d)',t); rig[{'0':'None','1':'Legacy','2':'Generic','3':'Humanoid'}.get(a.group(1) if a else '?','?')]+=1
        if re.search(r'clipAnimations:\s*\n\s*-',t): anim+=1
    f['models']={'count':len(fb),'import_scale':dict(sc.most_common(6)),'rig_types':dict(rig),'with_clip_splits':anim}
    f['anim_clips']=byext.get('.anim',0); f['controllers']=byext.get('.controller',0)
    f['scenes']=[e['path'] for e in manifest if ext(e['path'])=='.unity'][:10]
    f['textures']={k:byext.get(k,0) for k in ('.png','.tga','.psd','.jpg','.tif','.exr','.tiff')}
    f['audio']={k:byext.get(k,0) for k in ('.wav','.mp3','.ogg','.aif','.aiff')}
    f['nested_packages']=[e['path'] for e in manifest if ext(e['path'])=='.unitypackage']
    rd=[]
    for e in manifest:
        if ext(e['path']) in ('.txt','.md') and os.path.exists(os.path.join(files,e['path'])) and 'LICENSE' not in e['path'].upper()[-12:] and (e['size'] or 0)<20000:
            if re.search(r'read|doc|note|guide|install|urp|pipeline|change', e['path'], re.I):
                rd.append({'path':e['path'],'text':open(os.path.join(files,e['path']),errors='replace').read()[:1500]})
    f['readmes']=rd[:4]
    f['docs']=[e['path'] for e in manifest if ext(e['path']) in ('.pdf','.url','.html')][:8]
    pkgmani=[e['path'] for e in manifest if e['path'].startswith(('Packages/','ProjectSettings/'))]
    f['touches_project_settings_or_packages']=pkgmani[:10]
    return f

def serialization(root):
    c = collections.Counter(); vers = collections.Counter()
    for p in glob.glob(root + '/files/**/*', recursive=True):
        if not p.endswith(('.mat', '.prefab', '.asset', '.controller')) or not os.path.isfile(p): continue
        b = open(p, 'rb').read(64)
        if b.startswith(b'%YAML'): c['yaml'] += 1
        else:
            c['binary'] += 1
            m = re.search(rb'(\d{4}\.\d+\.\d+\w*)', b)
            if m: vers[m.group(1).decode()] += 1
    return dict(c), dict(vers.most_common(3))

if __name__ == '__main__':
    import sys
    out = sys.argv[1]  # the unpack.py out dir
    os.makedirs(os.path.join(out, 'facts'), exist_ok=True)
    for d in sorted(glob.glob(os.path.join(out, 'pkgs', '*', ''))):
        name = os.path.basename(d.rstrip('/'))
        f = analyze(d, json.load(open(d + 'manifest.json')))
        f['serialization'], f['binary_unity_versions'] = serialization(d)
        f['nested'] = {}
        for nd in sorted(glob.glob(d + 'nested/*/')):
            n = analyze(nd, json.load(open(nd + 'manifest.json')))
            n['serialization'], n['binary_unity_versions'] = serialization(nd)
            f['nested'][os.path.basename(nd.rstrip('/'))] = n
        json.dump(f, open(os.path.join(out, 'facts', name + '.json'), 'w'), indent=1)
        print(name, f['total_mb'], 'MB', f['material_remap_summary'], f['serialization'], 'scripts', f['scripts']['count'])
