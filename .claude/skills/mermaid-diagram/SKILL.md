---
name: mermaid-diagram
description: Author clean, consistent Mermaid diagrams (flowchart, sequence, class, state, ER, architecture, gantt, mindmap, timeline, gitgraph) and render them to SVG/PNG/PDF with mmdc. Use when the user wants a diagram, a flowchart, an architecture/sequence/ER/state diagram, "diagram this", "draw this flow", or a clean diagram to embed in a Marp deck or docs. Ships a shared theme so every diagram reads as one system. Sibling of the marp-slide skill (Marp renders slides; this renders diagrams).
---

# Mermaid Diagram Creator

Author clean, legible Mermaid diagrams from a shared theme and render them to embed-ready SVG (or PNG/PDF). The goal is diagrams that read as one visual system: consistent palette, spacing, and typography, transparent canvas so they sit on any background.

Mermaid draws diagrams; it does not make slides. To assemble diagrams into a presentation, render them here and embed the SVGs with the `marp-slide` skill.

## When to Use This Skill

Use this skill when the user:
- Asks for a diagram: flowchart, sequence, class, state, ER, architecture, gantt, mindmap, timeline, gitgraph
- Says "diagram this", "draw the flow", "map out the architecture", "show the sequence"
- Wants a clean diagram to embed in a Marp deck, a README, or a doc
- Has messy or inconsistent Mermaid and wants it cleaned up to one look
- Needs the same diagram in light and dark contexts (transparent canvas)

## Quick Start

### Step 1: Pick the diagram type

Match the intent to a Mermaid diagram type:

- Process / decision flow -> `flowchart`
- Interaction over time (who calls whom) -> `sequenceDiagram`
- Data model / entities and relations -> `erDiagram`
- Object model / types -> `classDiagram`
- Lifecycle / status machine -> `stateDiagram-v2`
- System / service topology -> `architecture-beta` (or a grouped `flowchart` if the renderer is old)
- Schedule / plan over calendar time -> `gantt`
- Idea tree / brainstorm -> `mindmap`
- Chronology of events -> `timeline`
- Branch/commit history -> `gitGraph`

If unsure, read `references/mermaid-syntax.md` for the full syntax of each type.

### Step 2: Start from a template

Copy the matching starter from `assets/`:

- `assets/template-flowchart.mmd`
- `assets/template-sequence.mmd`
- `assets/template-class.mmd`
- `assets/template-state.mmd`
- `assets/template-er.mmd`
- `assets/template-architecture.mmd`
- `assets/template-gantt.mmd`

Each template already begins with the shared init block (see Step 3) so the look is consistent from the first line.

### Step 3: Apply the shared theme

Two ways to get the shared look, in order of preference:

1. Render with the shared config file: `mmdc -c assets/mermaid-config.json ...`. This keeps the source `.mmd` clean and lets one file drive every diagram.
2. Or prepend the inline init block from `assets/theme-init.mmd` to the diagram source (useful when the diagram is embedded in a markdown fence and cannot pass a config flag).

Do not do both at once. Read `references/styling.md` for the palette, theme variables, and the clean-look rules (spacing, labels, direction, when to split a diagram).

### Step 4: Save the source

Save the diagram as a `.mmd` file (one diagram per file) in the working directory or a path the user specifies. Default name: `diagram.mmd`. Keep the `.mmd` source in the repo next to its rendered output so it stays editable.

### Step 5: Render and verify (built-in quality gate)

If `mmdc` is on PATH, render to SVG and confirm it renders clean:

```
mmdc -c assets/mermaid-config.json -b transparent -i diagram.mmd -o diagram.svg
```

- Use `-b transparent` so the diagram reads on both light and dark backgrounds (this is what makes it embed-ready in Marp decks and docs).
- Watch mmdc output for parse errors and confirm no labels are clipped and no edges cross more than necessary. If the diagram is too dense, split it (see the clean-look rules) rather than shrinking everything.
- PNG for raster contexts: `-o diagram.png` (add `-s 2` for 2x scale). PDF: `-o diagram.pdf`.
- If `mmdc` is **not** installed, print the install hint (see Rendering) and skip rendering. Do not fail the task: the `.mmd` source is still valid and useful.

## Rendering

`mmdc` is the Mermaid CLI. Install, in order of portability:

- macOS (this setup): `brew install mermaid-cli` (provisioned in the dotfiles Brewfile).
- Any OS with Node: `npm install -g @mermaid-js/mermaid-cli` (binary is `mmdc`).
- No install / CI: `npx -y @mermaid-js/mermaid-cli -i diagram.mmd -o diagram.svg`.
- Container / locked-down CI: `docker run --rm -u $(id -u):$(id -g) -v "$PWD":/data minlag/mermaid-cli -i diagram.mmd -o diagram.svg`.

Headless Chrome notes (PNG/PDF need a browser via puppeteer):
- mmdc bundles puppeteer; SVG output usually works without extra setup.
- In Docker/CI, pass `-p assets/puppeteer-config.json` to set the no-sandbox args. See `references/rendering.md` for the full matrix, scale/width flags, and troubleshooting.

## Embedding

- **In a Marp deck** (use with the `marp-slide` skill): render to SVG with `-b transparent`, then embed with Marp image syntax, e.g. `![bg right:45%](diagram.svg)` or `![w:640](diagram.svg)`. Transparent canvas means the deck theme shows through.
- **In markdown docs / READMEs**: either commit the rendered SVG and reference it, or use a fenced ` ```mermaid ` block if the renderer (GitHub, many static-site generators) renders Mermaid natively. For a fenced block you cannot pass `-c`, so prepend the init block from `assets/theme-init.mmd` to keep the look.
- **One diagram per file.** Do not pack multiple diagrams into one `.mmd`; it makes rendering and embedding brittle.

## Clean-look rules (summary)

Full rules in `references/styling.md`. The essentials:

- One idea per diagram. If it needs a legend to be understood, it is doing too much: split it.
- Left-to-right (`flowchart LR`) for pipelines and sequences of steps; top-to-bottom (`TD`) for hierarchies and decisions.
- Short node labels (a noun phrase, not a sentence). Put detail in edge labels or a caption, not inside the node.
- Consistent shapes: one shape per concept type (e.g. rounded = process, diamond = decision, cylinder = store). Do not vary shapes for decoration.
- Transparent background, shared palette. Never hardcode per-diagram colors that fight the shared theme; adjust the theme instead.
- Limit crossing edges. Reorder nodes or introduce a subgraph before you accept a tangle.

## Quality Checklist

Before delivering a diagram, verify:
- [ ] Diagram type fits the intent (flow vs sequence vs ER vs state vs architecture)
- [ ] Shared theme applied (config file `-c`, or inline init block, not both)
- [ ] Background is transparent (`-b transparent`) so it embeds on any surface
- [ ] Node labels are short noun phrases; detail lives on edges or a caption
- [ ] One shape per concept type, used consistently
- [ ] No unnecessary edge crossings; dense diagrams split rather than shrunk
- [ ] Source saved as `.mmd` (one diagram per file) next to its rendered output
- [ ] Rendered and verified clean (or mmdc absent and install hint shown)

## References

- **Syntax**: `references/mermaid-syntax.md` - syntax for every diagram type, with minimal examples
- **Styling**: `references/styling.md` - palette, theme variables, the clean-look doctrine, when to split
- **Rendering**: `references/rendering.md` - mmdc install matrix (brew/npm/npx/docker), SVG/PNG/PDF flags, transparent canvas, puppeteer/CI config, embedding, troubleshooting

### Assets
- `assets/mermaid-config.json` - shared theme config passed via `mmdc -c`
- `assets/theme-init.mmd` - inline `%%{init}%%` block for fenced/embedded diagrams
- `assets/puppeteer-config.json` - no-sandbox args for Docker/CI PNG/PDF renders
- `assets/template-*.mmd` - starter diagrams per type, pre-themed

### Official links
- Mermaid docs: https://mermaid.js.org/
- Mermaid live editor: https://mermaid.live/
- mermaid-cli (mmdc): https://github.com/mermaid-js/mermaid-cli
- Theming guide: https://mermaid.js.org/config/theming.html
