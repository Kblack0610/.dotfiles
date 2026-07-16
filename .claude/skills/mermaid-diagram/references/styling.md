# Styling: the clean-look doctrine

The point of this skill is diagrams that read as one visual system. That comes from a shared theme plus a small set of layout rules, not from per-diagram color tweaks.

## Where the look comes from

Two mechanisms, pick one per diagram:

1. **Config file (preferred).** Render with `mmdc -c assets/mermaid-config.json`. The `.mmd` source stays clean (no theme noise), and one file controls every diagram. Change the palette in one place and re-render everything.
2. **Inline init block.** Prepend the `%%{init: {...}}%%` block from `assets/theme-init.mmd` as the first line of the source. Use this only when the diagram lives in a fenced ` ```mermaid ` block that a native renderer (GitHub, docs site) handles, where you cannot pass `-c`.

Never apply both at once: the inline block overrides the config and you lose the single-source-of-truth benefit.

## The theme

Built on Mermaid's `base` theme with `themeVariables` overridden. `base` is the only theme that honors custom variables; `default`/`dark`/`forest`/`neutral` ignore most of them.

Palette philosophy (brand-neutral default, swap for a project brand):
- One primary accent for the main flow, one neutral for supporting nodes, one muted line color for edges. Not a rainbow.
- Text color must clear WCAG AA against the node fill. When in doubt, dark text on light fill.
- Background: none. Render with `-b transparent` so the diagram sits on any surface (light doc, dark deck). The theme sets node fills, not a canvas.

The concrete values live in `assets/mermaid-config.json` (and mirrored in `assets/theme-init.mmd`). To rebrand: edit those two files, keep them in sync, re-render.

Key `themeVariables` worth knowing:
- `primaryColor`, `primaryTextColor`, `primaryBorderColor` - the main node fill/text/border
- `lineColor` - edges
- `secondaryColor`, `tertiaryColor` - subgraph/alternate fills
- `fontFamily`, `fontSize` - typography (keep one family; a system sans is safest for portability)
- `clusterBkg`, `clusterBorder` - subgraph container

## Layout rules

- **One idea per diagram.** If it needs a legend to be understood, split it. Two clear diagrams beat one dense one.
- **Direction with intent.** `LR` for pipelines and step sequences (reads like a sentence). `TD` for hierarchies and decision trees (reads like an org chart). Do not mix within one diagram.
- **Short labels.** Node text is a noun phrase, not a sentence. Push detail to edge labels (`-->|does X|`) or a caption below the diagram.
- **One shape per concept type.** Decide the vocabulary up front (e.g. rounded = process, diamond = decision, cylinder = datastore, stadium = start/end) and hold it across every diagram in the set. Shape variance should carry meaning, never decoration.
- **Tame crossings.** Before accepting crossed edges, reorder nodes, flip an edge direction, or wrap a cluster in a `subgraph`. Crossings are the top readability killer.
- **Whitespace.** Fewer nodes per rank. If a rank has more than ~5 nodes, consider a subgraph or a split.

## When to split

Split a diagram when any of these is true:
- More than ~15-20 nodes, or edges you can no longer trace by eye.
- Two distinct audiences (e.g. "the happy path" vs "all error branches") - make one per audience.
- You reached for a legend to explain shapes or colors.

Name the split diagrams by the slice they show (e.g. `boot-happy-path.mmd`, `boot-recovery.mmd`), not `diagram-1`/`diagram-2`.

## Anti-patterns

- Hardcoding `style nodeId fill:#...` per node to fix one diagram. Fix the theme instead, or you get drift across the set.
- Long sentences inside nodes. They blow up node size and wreck the layout.
- Mixing diagram directions or shape vocabularies across a set that will be viewed together.
- A colored canvas background baked into the render. Keep it transparent; let the embedding surface set the background.
