# Rendering with mmdc

`mmdc` is the Mermaid CLI. It turns a `.mmd` source into SVG, PNG, or PDF. SVG is the default choice: crisp at any size and embed-ready.

## Install matrix (most to least portable)

| Context | Command |
|---|---|
| macOS (this dotfiles setup) | `brew install mermaid-cli` (in the Brewfile; binary is `mmdc`) |
| Any OS with Node >= 18 | `npm install -g @mermaid-js/mermaid-cli` |
| One-off / CI, no install | `npx -y @mermaid-js/mermaid-cli -i in.mmd -o out.svg` |
| Container / locked-down CI | `docker run --rm -u $(id -u):$(id -g) -v "$PWD":/data minlag/mermaid-cli -i in.mmd -o out.svg` |

All four expose the same flags below (npx/docker just prefix the invocation). If `mmdc` is absent and you cannot install, the `.mmd` source is still valid: hand it to the user with the install hint and skip rendering rather than failing.

## Core invocation

```
mmdc -c mermaid-config.json -b transparent -i diagram.mmd -o diagram.svg
```

Flags that matter:
- `-i` input `.mmd`, `-o` output (extension picks the format: `.svg`, `.png`, `.pdf`).
- `-c <config.json>` the shared theme config (see `assets/mermaid-config.json`). This is how every diagram gets one look.
- `-b transparent` transparent background. Also accepts a color (`-b white`, `-b '#0d1117'`). Default to transparent for embed-ready output.
- `-s <n>` scale factor for raster output (PNG). `-s 2` or `-s 3` for crisp PNGs.
- `-w <px>` / `-H <px>` width/height hints.
- `-p <puppeteer-config.json>` puppeteer launch args (needed in Docker/CI, see below).
- `-t <theme>` built-in theme override, but prefer driving the theme via `-c` for consistency.

## Formats

- **SVG** (default): vector, scales cleanly, smallest, best for Marp decks and docs. Transparent by design with `-b transparent`.
- **PNG**: for surfaces that cannot render SVG. Always add `-s 2` (or higher) or it looks soft. PNG uses headless Chrome via puppeteer.
- **PDF**: single-diagram PDF; also puppeteer-backed.

## Puppeteer / headless Chrome (PNG, PDF, some CI)

mmdc renders via a bundled Chromium (puppeteer). SVG generally works out of the box; PNG/PDF always need the browser to launch. In Docker or restricted CI the sandbox must be disabled:

`assets/puppeteer-config.json`:
```
{ "args": ["--no-sandbox", "--disable-setuid-sandbox"] }
```

Then: `mmdc -p assets/puppeteer-config.json -i diagram.mmd -o diagram.png -s 2`.

If Chromium is missing entirely (some minimal images), either use the `minlag/mermaid-cli` Docker image (ships Chromium) or install a system Chromium and point puppeteer at it with `PUPPETEER_EXECUTABLE_PATH`.

## Batch rendering

Render a directory of sources with one config (keeps the whole set consistent):

```
for f in diagrams/*.mmd; do
  mmdc -c mermaid-config.json -b transparent -i "$f" -o "${f%.mmd}.svg"
done
```

## Embedding the output

- **Marp deck** (pair with the `marp-slide` skill): reference the transparent SVG with Marp image syntax, e.g. `![bg right:45%](diagram.svg)` (side) or `![w:640](diagram.svg)` (inline, sized). Transparent canvas lets the deck theme show through, so the same SVG works on a light and a dark theme.
- **Markdown / README**: commit the SVG and link it, or use a fenced ` ```mermaid ` block if the renderer supports native Mermaid (GitHub does). Fenced blocks cannot take `-c`, so prepend the init block from `assets/theme-init.mmd` to keep the look.
- Keep the `.mmd` source committed next to the rendered file so the diagram stays editable and re-renderable.

## Troubleshooting

- **Parse error / nothing renders**: run the source through https://mermaid.live/ to locate the bad line. Common cause: an unquoted label with parentheses or the word `end`.
- **Init block ignored**: the `%%{init: ...}%%` directive must be the first non-empty line. A comment or blank line above it is fine; a diagram keyword above it is not.
- **Clipped labels**: labels too long. Shorten them or move detail to edge labels; do not fix it by scaling down.
- **Soft/blurry PNG**: add `-s 2` (or `-s 3`). For print, prefer SVG or PDF.
- **CI hangs or "Failed to launch the browser process"**: pass `-p puppeteer-config.json` with `--no-sandbox`, or switch to the Docker image.
