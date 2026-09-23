---
name: asset-store-audit
description: "Audit downloaded Unity Asset Store packs (.unitypackage files in the local download cache) and decide, per pack, whether to bring it into the BNB Unity stack (unity-core URP + FlatKit, the catalog contract, asset-ingest) - with a why and a why-not for every pack, judged from the actual files (material shader GUIDs, scripts, prefabs, FBX import settings, serialization, nested URP sub-packages), never store blurbs. Publishes a filterable Artifact report plus a cross-pack synthesis (style families, what pipeline gaps block which packs, suggested ingest order). Use when the user says \"analyze my downloaded assets\", \"which asset store packs should we use\", \"audit these packs\", \"is this pack worth bringing in\", or after downloading a new batch from My Assets. Read-only: it never imports into a project. Not for actually ingesting a pack into a library package (that is the com.blacknbrown.asset-ingest editor tool) and not for browsing the owned-but-not-downloaded list on the store site."
metadata:
  category: research
  tags: [unity, asset-store, audit, assets, catalog]
  reviewed: "2026-09-23"
---

# Asset Store Audit

Turns a folder of downloaded .unitypackage files into a per-pack verdict (Adopt / Adopt with work / Reference only / Skip) with concrete evidence, and a synthesis of what to bring in, in what order, and which of our own pipeline gaps are the real blocker. First run: 2026-09-22, 31 packs, 14 GB, report at https://claude.ai/code/artifact/3236616c-55b9-4748-8be8-f39a2885974c (saved under the unity-playground lab project, `research/asset-store-audit-2026-09-22/`).

## When to Use

- When the user has downloaded packs from Package Manager -> My Assets and asks which are worth using.
- When one new pack lands and needs a bring-in decision (run the same steps on one pack).

Not for importing or converting a pack - that is the asset-ingest tool in unity-core.

## Steps

Scripts are in `~/.claude/skills/asset-store-audit/scripts/`. Work in the session scratchpad (`$OUT`).

1. **Unpack without importing.** Cache on Linux: `~/.local/share/unity3d/Asset Store-5.x/<publisher>/<category>/`. Skip `*.tmp` (partial downloads) and tell the user which ones are still in progress.
   `python3 scripts/unpack.py "<cache>" "$OUT" -j 12` - streams every package, writes `pkgs/<Pack>/manifest.json` and text assets, and unpacks nested URP / effect sub-packages into `pkgs/<Pack>/nested/`. About 3 minutes for 14 GB.
2. **Fact sheets.** `python3 scripts/facts.py "$OUT"` -> `facts/<Pack>.json`: type counts and MB, material shaders by GUID with a remap summary, custom shaders, script namespaces and flags, asmdefs, prefab components, FBX scale and rig, serialization and authoring version.
3. **Refresh the rubric's view of the stack.** Read `references/rubric.md`, then re-check unity-core's `packages/` and `third-party/` and `packages/com.blacknbrown.asset-ingest/Editor/ShaderRemap.cs` + `PackIngestor.cs`. Copy the rubric to `$OUT/RUBRIC.md` with anything that changed.
4. **Judge in parallel.** Up to 3 general-purpose agents, grouped: environments / characters + animation / props + VFX + audio + tools. Each reads `$OUT/RUBRIC.md` and its packs' fact sheets, samples real files, writes `$OUT/verdicts/<Pack>.json` in the rubric's exact schema. Environment and prop packs get the most scrutiny (the user's priority).
5. **Spot check two claims by hand** (one material's `m_Shader` GUID, one prefab's structure) and fold them into the synthesis.
6. **Synthesis.** Write `$OUT/synth.html` (fragment, plain ASCII): the short answer with verdict counts, what unlocks what (pipeline gap -> packs it unblocks), suggested order, style families, gaps no pack fills, cache space reclaimable from skipped packs. Take the counts from step 7's output, never from memory.
7. **Build and publish.** `python3 scripts/build_report.py "$OUT" "$OUT/synth.html" "$OUT/report.html"` (fails if a pack lacks a verdict or a verdict has non-ASCII). Load `artifact-design`, then publish `report.html` with the Artifact tool. If the printed counts disagree with the synthesis, fix the synthesis and republish.
8. **Save.** Copy `report.html`, `verdicts/`, `facts/`, `RUBRIC.md` and a short `README.md` (link, counts, pipeline gaps) to the lab project the user names (default: unity-playground, `~/.notes/lab/bnb/projects/current/unity-playground/research/asset-store-audit-<date>/`), and log it on that project's agent board with `notes ptask <project> --agent add` / `done --proof <artifact url>`.

## Do NOT

- Do not import packs into a project to inspect them - the tarball has everything, and an import rewrites project settings (Synty's helper edits Packages/manifest.json).
- Do not judge a big env pack by its outer materials when it ships a URP sub-package - judge the nested one.
- Do not treat an asset-ingest limitation (FBX-only source, missing shader remap, no texture cap) as a pack defect; name it as a pipeline gap and list the packs it blocks.
- Do not quote verdict counts from memory - the 2026-09-22 run published wrong counts once. Use build_report's printed tally.
