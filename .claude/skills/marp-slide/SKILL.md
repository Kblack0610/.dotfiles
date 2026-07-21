---
name: marp-slide
description: Create professional Marp presentation slides with 7 beautiful themes (default, minimal, colorful, dark, gradient, tech, business). Use when users request slide creation, presentations, or Marp documents. Supports custom themes, image layouts, and "make it look good" requests with automatic quality improvements.
---

# Marp Slide Creator

Create professional, visually appealing Marp presentation slides with 7 pre-designed themes and built-in best practices.

## When to Use This Skill

Use this skill when the user:
- Requests to create presentation slides or Marp documents
- Asks to "make slides look good" or "improve slide design"
- Provides vague instructions like "make it look good", "make it pop", or "make it cool"
- Wants to create lecture or seminar materials
- Needs bullet-point focused slides with occasional images

## Quick Start

### Step 1: Select Theme

First, determine the appropriate theme based on the user's request and content.

**Quick theme selection:**
- **Technical/Developer content** → tech theme
- **Business/Corporate** → business theme
- **Creative/Event** → colorful or gradient theme
- **Academic/Simple** → minimal theme
- **General/Unsure** → default theme
- **Dark background preferred** → dark or tech theme

For detailed theme selection guidance, read `references/theme-selection.md`.

### Step 2: Create Slides

1. **Read relevant references first**:
   - Always start by reading `references/marp-syntax.md` for basic syntax
   - For images: `references/image-patterns.md` (official Marpit image syntax)
   - For advanced features (math, emoji): `references/advanced-features.md`
   - For custom themes: `references/theme-css-guide.md`

2. Copy content from the appropriate template file:
   - `assets/template-basic.md` - Default theme (most common)
   - `assets/template-minimal.md` - Minimal theme
   - `assets/template-colorful.md` - Colorful theme
   - `assets/template-dark.md` - Dark mode theme
   - `assets/template-gradient.md` - Gradient theme
   - `assets/template-tech.md` - Tech/code theme
   - `assets/template-business.md` - Business theme

3. Read `references/best-practices.md` for quality guidelines

4. Structure content following best practices:
   - Title slide with `<!-- _class: lead -->`
   - Concise h2 titles (short noun phrase, ~2–6 words)
   - 3-5 bullet points per slide
   - Adequate whitespace
   - **Budget by section** — 3–7 content slides per section, one idea per slide. See the
     Section-Budget Standard in `references/best-practices.md` (the canonical rule).

5. Add images if needed using patterns from `references/image-patterns.md`

6. Save to the current working directory (or a path the user specifies) with `.md` extension. Default filename: `presentation.md`.

7. **Render & verify** (see the Render & verify step under "Creating Slides Process").

## Available Themes

### 1. Default Theme
**Colors**: Beige background, navy text, blue headings
**Style**: Clean, sophisticated with decorative lines
**Use for**: General seminars, lectures, presentations
**Template**: `template-basic.md`

### 2. Minimal Theme
**Colors**: White background, gray text, black headings
**Style**: Minimal decoration, wide margins, light fonts
**Use for**: Content-focused presentations, academic talks
**Template**: `template-minimal.md`

### 3. Colorful & Pop Theme
**Colors**: Pink gradient background, multi-color accents
**Style**: Vibrant gradients, bold fonts, rainbow accents
**Use for**: Youth-oriented events, creative projects
**Template**: `template-colorful.md`

### 4. Dark Mode Theme
**Colors**: Black background, cyan/purple accents
**Style**: Dark theme with glow effects, eye-friendly
**Use for**: Tech presentations, evening talks, modern look
**Template**: `template-dark.md`

### 5. Gradient Background Theme
**Colors**: Purple/pink/blue/green gradients (varies per slide)
**Style**: Different gradient per slide, white text, shadows
**Use for**: Visual-focused, creative presentations
**Template**: `template-gradient.md`

### 6. Tech/Code Theme
**Colors**: GitHub-style dark background, blue/green accents
**Style**: Code fonts, Markdown-style headers with # symbols
**Use for**: Programming tutorials, tech meetups, developer content
**Template**: `template-tech.md`

### 7. Business Theme
**Colors**: White background, navy headings, blue accents
**Style**: Corporate presentation style, top border, table support
**Use for**: Business presentations, proposals, reports
**Template**: `template-business.md`

## Creating Slides Process

### Basic Workflow

1. **Understand requirements**
   - Identify content: title, topics, key points
   - Determine target audience and the deck's single purpose
   - Assess formality level

2. **Outline by section**
   - Group the content into sections; each section = one audience attention span
   - Apply the **Section-Budget Standard** (`references/best-practices.md`): 3–7 content
     slides per section, one idea per slide; past ~7, split the section or cut
   - Purpose filter: drop anything that doesn't serve this audience's need

3. **Select theme**
   - Use quick selection rules above
   - If uncertain, consult `references/theme-selection.md`
   - Default to default theme if still unsure

4. **Apply template**
   - Load appropriate template from `assets/`
   - Each template sets `theme: kb-<name>` in frontmatter; the matching CSS lives in
     `assets/themes/theme-<name>.css` and is applied at render time by the `deck` CLI
     (or `marp --theme-set assets/themes`). Templates no longer embed a `<style>` block.
   - Maintain template structure

5. **Structure content**
   - Title slide: `<!-- _class: lead -->` + h1
   - Content slides: h2 title + bullet points
   - Keep titles to a short noun phrase (~2–6 words)
   - Use 3-5 bullet points per slide

6. **Refine quality**
   - Read `references/best-practices.md`
   - Ensure adequate whitespace
   - Maintain consistency
   - Keep each bullet to one line (~6–12 words)

7. **Add images**
   - If needed, consult `references/image-patterns.md`
   - Common: `![bg right:40%](image.png)` for side images
   - Use proper Marp image syntax

8. **Output file**
   - Save to the current working directory (or path the user specifies)
   - Use descriptive filename like `presentation.md`

9. **Render & verify** (built-in quality gate)
   - Prefer the global **`deck`** CLI — it auto-injects the kb-* theme-set so the deck
     renders styled from any directory: `deck build presentation.md` (PDF), or
     `deck watch presentation.md` for a live-reloading preview server. See the
     "Global `deck` CLI" section below.
   - Raw marp works too, but you MUST pass the theme-set for kb-* themes to resolve:
     `marp presentation.md -o presentation.pdf --theme-set ~/.claude/skills/marp-slide/assets/themes`
     (add `--html` for an HTML preview).
   - Watch marp-cli output for overflow / content-bleed warnings, and confirm no slide
     spills past its frame. If a slide overflows, split it — don't shrink the font.
   - If neither `deck` nor `marp` is installed, print the install hint and skip
     rendering — do not fail the task. Install, most to least portable: macOS
     `brew install marp-cli`; any OS with Node `npm install -g @marp-team/marp-cli`;
     one-off/CI `npx -y @marp-team/marp-cli@4 ...`; container/CI
     `docker run --rm -v "$PWD":/home/marp/app marpteam/marp-cli ...`.
     PDF/PPTX export needs Chrome/Chromium present (the Docker image bundles it).

## Global `deck` CLI

`deck` (on PATH via `~/.local/bin/deck`) is a thin, cross-machine wrapper around
marp-cli that auto-injects this skill's theme-set (`--theme-set assets/themes`), so
decks render fully styled from **any** directory — no per-project code repo needed. It
is the portable generalization of the fleet-platform `pnpm deck:build`/`deck:watch`.

```
deck new      <name> [--theme NAME] [--dir DIR]  Scaffold from a template into DECK_HOME
deck watch    [TARGET] [--port N]                 Live-reloading preview server (view it here)
deck build    [TARGET] [--format pdf|html|pptx]   Render deck(s) (renders diagrams first)
deck diagrams [TARGET]                            Render sibling .mmd/.d2 -> .svg
deck list     [DIR]                               List Marp decks in a directory
deck themes                                        List available kb-* themes
deck doctor                                        Check the toolchain on this machine
```

- **TARGET** may be empty (uses `DECK_HOME`), a file, a directory (renders every
  `marp: true` deck in it), or a bare deck name resolved under `DECK_HOME`.
- **Theme names** accept the bare or prefixed form (`tech` == `kb-tech`).
- **Deck home**: `DECK_HOME` (default `~/.notes/lab/decks`), so decks ride the notes
  vault sync across machines. Override with `--dir` or `$DECK_HOME`.
- **View it**: `deck watch <name>` starts a marp server at `http://localhost:8088/`
  (port via `--port`/`$PORT`) and serves the deck at `/<name>.md` with live reload.
- Renders with `marp` if present, else `npx --yes @marp-team/marp-cli@4`. PDF/PPTX/PNG
  export needs a system Chrome/Chromium (`CHROME_PATH` if not auto-detected); the HTML
  `deck watch` server needs no browser.
- **Diagrams**: the preferred method is a **hand-authored SVG** next to the deck -
  the `.svg` file is the source (plain `<rect>`/`<text>`/`<path>`), so there is NO
  render step and no `mmdc`/`d2` dependency. Embed it directly: `![w:900](arch.svg)`.
  Edit the slide text or the `.svg` and re-run `deck build`. See
  `references/handauthored-svg-diagrams.md` for the full convention and copy
  `assets/example/architecture-layers.svg` as your template.
- **`deck doctor`** reports what is present/missing on the current machine (marp, mmdc,
  d2, a browser, the theme-set, DECK_HOME) with an install hint per missing tool.

When authoring for a user who just wants slides fast, still write the `.md` (theme by
name), then offer `deck watch <name>` to preview and `deck build <name>` to export.

## Handling "Make It Look Good" Requests

When users give vague instructions like "make it look good", "make it pop", or "make it cool" (in any language):

1. **Infer theme from content**:
   - Business content → business theme
   - Technical content → tech or dark theme
   - Creative content → gradient or colorful theme
   - General → default theme

2. **Apply best practices automatically**:
   - Shorten titles to a short noun phrase (~2–6 words)
   - Limit bullet points to 3-5 items
   - Add adequate whitespace
   - Use consistent structure

3. **Enhance visual hierarchy**:
   - Use h3 for sub-sections when appropriate
   - Break up dense text into multiple slides
   - Ensure logical flow (intro → body → conclusion)

4. **Maintain professional tone**:
   - Match formality to content
   - Use parallel structure in lists
   - Keep technical terms consistent

## Image Integration

For slides with images, consult `references/image-patterns.md` for detailed syntax.

Common patterns:
- **Side image**: `![bg right:40%](image.png)` - Image on right, text on left
- **Centered**: `![w:600px](image.png)` - Centered with specific width
- **Full background**: `![bg](image.png)` - Full-screen background
- **Multiple images**: Multiple `![bg]` declarations

Example lecture pattern:
```markdown
## Slide Title

![bg right:40%](diagram.png)

- Explanation point 1
- Explanation point 2
- Explanation point 3
```

## File Output

Save the final Marp file to the current working directory (or a path the user specifies) with `.md` extension. Examples:
- `presentation.md`
- `seminar-slides.md`
- `lecture-materials.md`

To render or preview, prefer `deck build <name>` / `deck watch <name>` (see "Global
`deck` CLI"). Under the hood this needs `marp-cli` (macOS `brew install marp-cli`; any
OS with Node `npm install -g @marp-team/marp-cli`; no-install `npx -y
@marp-team/marp-cli@4`; container `docker run --rm -v "$PWD":/home/marp/app
marpteam/marp-cli`) or the Marp VS Code extension. PDF/PPTX export needs Chrome/Chromium
present. On a fresh machine, `marp-cli` is provisioned cross-OS (packages.conf
`NPM_PACKAGES`, or the Brewfile on macOS).

## Quality Checklist

Before delivering slides, verify:
- [ ] Theme selected appropriately for content
- [ ] Frontmatter sets `theme: kb-<name>` matching a theme in `assets/themes/`
- [ ] Title slide uses `<!-- _class: lead -->`
- [ ] All h2 titles are concise (short noun phrase, ~2–6 words)
- [ ] Bullet points are 3-5 items per slide, one line each
- [ ] Every section stays within the 3–7-slide budget (one idea per slide)
- [ ] Images / tables / diagrams use proper Marp syntax
- [ ] File saved to the working directory (or user-specified path)
- [ ] Rendered & verified — no slide overflow (or marp-cli absent and install hint shown)

## References

### Core Documentation
- **Marp syntax**: `references/marp-syntax.md` - Basic Marp/Marpit syntax (directives, frontmatter, pagination, etc.)
- **Image patterns**: `references/image-patterns.md` - Official image syntax (bg, filters, split backgrounds)
- **Theme CSS guide**: `references/theme-css-guide.md` - How to create custom themes based on Marpit specification
- **Advanced features**: `references/advanced-features.md` - Math, emoji, fragmented lists, Marp CLI, VS Code
- **Official themes**: `references/official-themes.md` - default, gaia, uncover themes documentation
- **Hand-authored SVG diagrams**: `references/handauthored-svg-diagrams.md` - the preferred diagram method: clean, diffable, theme-neutral SVGs authored by hand (layer bands, body cards, arrow semantics, palette, C4 altitude). Read before drawing any diagram.

### Quality & Selection Guides
- **Theme selection**: `references/theme-selection.md` - How to choose the right theme for content
- **Best practices**: `references/best-practices.md` - Quality guidelines for "cool" slides
- **Deck workflow**: `references/deck-workflow.md` - The `deck` CLI loop, our conventions (theme-by-name, notes deck home, hand-authored SVG diagrams), and the gotchas (chrome, stdin, stow). Read before authoring/rendering.

### Templates & Assets
- **Templates**: `assets/template-*.md` - Starting points for each theme (7 themes); each sets `theme: kb-<name>` in frontmatter (no embedded `<style>` block)
- **Theme-set**: `assets/themes/theme-*.css` - the standalone Marp themes (`/* @theme kb-<name> */`), the single source of truth for styling, applied via the `deck` CLI or `marp --theme-set assets/themes`
- **Worked example** (few-shot): `assets/example/` - a complete deck about the deck system (`deck-system.md`, `theme: kb-tech`) that embeds a **hand-authored SVG** (`architecture-layers.svg`, a clean three-tier layered diagram) directly, no render step. Copy its shape when a deck needs diagrams. Build it: `deck build assets/example/deck-system.md`

### Official External Links
- **Marp Official Site**: https://marp.app/
- **Marpit Directives**: https://marpit.marp.app/directives
- **Marpit Image Syntax**: https://marpit.marp.app/image-syntax
- **Marpit Theme CSS**: https://marpit.marp.app/theme-css
- **Marp Core GitHub**: https://github.com/marp-team/marp-core
- **Marp CLI GitHub**: https://github.com/marp-team/marp-cli
