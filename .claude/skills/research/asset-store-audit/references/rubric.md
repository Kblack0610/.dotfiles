# Per-pack audit rubric

Target stack (unity-core, ~/dev/bnb/games/engine/unity-core; re-read its packages/ and third-party/ before each run, this list drifts): Unity 6000.0, URP, FlatKit stylized toon shading (third-party/com.dustyroom.flatkit). Games pull props/weapons from a shared asset library built on `com.blacknbrown.catalog` (CatalogItem with traits Equippable/Weapon/Placeable/Throwable/Pickup, CatalogView root with named ItemSockets, Addressables). Vendor packs become library packages (com.blacknbrown.lib.*) via `com.blacknbrown.asset-ingest`: a PackProfile picks files, normalizes scale to metres / rotate to +Z, rebuilds materials as plain URP using ShaderRemap (packages/com.blacknbrown.asset-ingest/Editor/ShaderRemap.cs) which ONLY maps Standard, Standard (Specular setup), Autodesk Interactive, Legacy Diffuse/Bumped/Specular/Transparent/Cutout/VertexLit, Mobile/*, Unlit/Texture|Color|Transparent, Sprites/Default -> URP Lit/SimpleLit/Unlit/Sprite. Custom vendor shaders / shader graphs are NOT remapped (validator reports them); FlatKit material mode is not implemented yet. Ingest writes a canonical prefab per mesh, so prefabs with baked-in vendor scripts or nested scene junk are extra work.
unity-core already has: Animancer 8 (animation playback, no need for Mecanim controllers), Rewired (input), Heathen Steamworks, FlatKit, character-base (ability framework, state machine, movement/dash, 2D+3D, networked/predicted rigidbody movers, server input), feedback (flash/blink action feedback), spawn, catalog, bootstrap, data, diagnostics, networking-base, ui-base. So vendor character controllers / input / state-machine frameworks overlap and conflict with ours (networked, server-authoritative).

Evidence sources (paths relative to the audit out dir): facts/<Pack>.json (deterministic fact sheet: file-type counts + MB, material shader breakdown incl `material_remap_summary`, custom shaders, scripts namespaces/flags/third-party usings, asmdefs, prefab component counts, FBX import scale/rig type, serialization yaml vs binary + authoring Unity version, nested per-pipeline sub-packages under `nested`, readmes). Raw extracted text assets live in pkgs/<Pack>/files/ (and pkgs/<Pack>/nested/<sub>/files/), full path list in pkgs/<Pack>/manifest.json. Sample a few real files (a .mat, a .prefab, a .cs, an fbx .meta) to back claims. Do not use store blurbs or memory of the store page as evidence; you may use general knowledge of the vendor (e.g. Synty licensing, Malbers framework) but label it as such.

Notes: builtin shader fileIDs 103/106/205/202/10623/10723/47 etc are skybox/particle/UI builtins; say so if unsure. Binary-serialized assets (not YAML) mean an old authoring version and harder diffing/review, and Unity will upgrade them on import. Texture size is only known in MB, not resolution.

For EACH pack write verdicts/<Pack>.json (Pack = facts filename stem) with exactly:
{
 "pack": "<display name>", "publisher": "...", "category": "environment|props|character|animation|vfx|audio|tools|2d",
 "size_mb": n, "what_it_is": "1-2 sentences, from the files",
 "contents": "counts: meshes/prefabs/materials/textures/anims/scripts/audio, with MB",
 "fills_gap": "what unity-core/library lacks that this provides, or 'nothing' ",
 "why_bring_in": ["concrete reasons with evidence"],
 "why_not": ["concrete reasons with evidence"],
 "pipeline": "URP story: native URP / URP sub-package / remappable built-in / custom shaders needing rework, with counts",
 "standardization": "folder layout, naming, prefab-per-mesh, scale, LODs, colliders, serialization, code quality (namespaces, asmdef, legacy Input, Find calls) with evidence",
 "catalog_fit": "can asset-ingest take it with a PackProfile as-is? what breaks? which traits would items get",
 "style_fit": "low-poly/stylized vs realistic PBR; fit with FlatKit and with other packs",
 "effort": "S|M|L|XL + one line",
 "verdict": "Adopt|Adopt with work|Reference only|Skip",
 "verdict_reason": "one sentence",
 "confidence": "high|medium|low"
}
Write plain ASCII only (no em dashes, no unicode arrows). Be specific and honest; if a pack is great but irrelevant say so; if it is weak say so. Read-only everywhere except writing your verdict files.

## Things the 2026-09-22 run learned (re-verify, the ingest tool moves)
- asset-ingest (PackIngestor) builds each item from the FBX, not the vendor prefab. Check each FBX .meta `materialImportMode`: when it is 0/None (all Synty packs) materials only exist on the vendor prefabs, so items come out grey and lose LODGroups and colliders. Report this as an ingest gap, not a pack defect.
- Synty `Generic_Basic` shader graph is URP Lit with renamed properties; `_Enable_Emission` gates a stored HDR emission colour, so a remap that ignores it makes everything glow.
- Synty packs each ship an identical PolygonGeneric library and a `SyntyPackageHelper` editor script that edits Packages/manifest.json. Ingest the library once; exclude the helper.
- Big env packs often carry a URP sub-package under a pipeline-named .unitypackage; judge the URP one, not the outer built-in/HDRP materials.
- Binary-serialized .mat/.prefab (no %YAML) are old (2017-2020 authoring) and cannot be reviewed as text.
- Vendor character frameworks (Malbers AC, Invector, PlayMaker demos) overlap character-base; judge whether the art/clips stand alone without the code.
- Characters, creatures, animation sets and audio have no library path in unity-core yet (catalog is props/weapons only); say what they would need.
