# web-kit

The shared site shell for every kblab site: design tokens, the two fonts, and `<kb-shell>`, the top bar with tabs under group headings. It shows as a fixed sidebar from 900px, and as a menu button with a dropdown below that. There is no build step and no dependency: plain CSS and plain JS, in light DOM, so a site's own CSS and server-rendered links work inside it. Beside the shell it holds the renderers every page draws the same way: the section head, error block, fold, clamped record cell and record list.

What the tokens should look like, and how a site uses them, is `../docs/ui.md`; a token change follows it.

| File | What it is |
|---|---|
| `tokens.css` | `:root` surface, accent and status hues with their soft tints, radii, the content cap, type scale, dark mode, the two `@font-face` rules, and the body base |
| `shell.css` | The bar, the sidebar, and the phone dropdown. 900px is the one nav breakpoint |
| `kb-shell.js` | The `<kb-shell>` custom element: adds the menu button and the open tab's name |
| `ui.css` | The look of what `kb-ui.js` draws: `.sec` head, `.err` block, `details.cfold`, the clamped cells `.c2`, `.c1`, `.c12`, and `table.rec`. Needs `tokens.css` |
| `kb-ui.js` | A plain script (not a module) defining one global, `kbUi`: `secHead`, `errPanel`, `fold`, `tblRec`, `clamp2`, `clamp1`, `rec2`, `esc` |
| `inter.woff2`, `jetbrains-mono.woff2` | Latin-subset fonts, with their OFL licences beside them |

## Markup contract

The site renders the whole nav as HTML. The element only adds the phone menu, so without JS the nav still shows: as the sidebar on a wide screen, and as a wrapped strip on a phone.

```html
<link rel="stylesheet" href="/static/tokens.css">
<link rel="stylesheet" href="/static/shell.css">
<script type="module" src="/static/kb-shell.js"></script>

<kb-shell>
  <span class="kb-menu-badge">3</span>        <!-- optional: moved onto the menu button -->
  <a class="kb-brand" href="/">trader</a>
  <nav class="kb-nav" aria-label="Sections">
    <div class="kb-group">Now</div>
    <a href="/" aria-current="page">Overview</a>
    <a href="/suggestions">Suggestions</a>
    <div class="kb-group">Evidence</div>
    <a href="/strategies">Strategies</a>
    <div class="kb-foot">ken <form method="post" action="/logout"><button>Sign out</button></form></div>
  </nav>
</kb-shell>
<main class="kb-main">...</main>
```

- Items are the direct `<a>` or `<button>` children of `.kb-nav`. Use links for a multi-page site and buttons for a hash-routed one.
- The open tab is the item with `aria-current`. A page that switches tabs without a load moves the attribute, and the name on the bar follows it.
- The bar label is the item's `data-title`, else its first text node, so a count after the name is not read as part of it.
- Other children under `.kb-nav` (agent-web's section outline) are allowed. Style them in the site.
- `.kb-foot` sits at the bottom of the sidebar.
- From 900px `.kb-main` sits left, beside the sidebar, up to `--page-max` wide. A site does not centre its content again inside it.
- `tokens.css` names the fonts relative to itself (`url(inter.woff2?v={{v}})`), so serve the fonts beside it. A site that versions its assets substitutes `{{v}}`; one that does not serves the literal query, which is ignored.

## Renderers

A page draws these through `kbUi` and never hand-builds the markup (ui.md rules 9 and 16). Every argument named html is already escaped; every text argument is escaped inside.

| Call | Draws |
|---|---|
| `secHead(id, title, n, level, tag)` | `<h2 class="sec" id="sec-<id>">` with the title and its count; `level` `warn` or `bad` hues the title |
| `errPanel(msg, {card, tag, id, cls})` | `.err`, the error hue; an empty `msg` keeps a line's height as a live region |
| `fold(cls, summary, inner, {k, id, open, attrs, sum})` | the one `<details>`; class `cfold` takes `ui.css`'s quiet summary |
| `tblRec(rows, cls)` | a record list as `table.rec`: each row its cells (html), or `{cells, cls}`; cells are drawn as sent |
| `clamp2(html, full)`, `clamp1(html, full)` | a cell cut to two lines (`.c2`), or to one that opens to two on hover and in the selected row (`.c12`); `full` is the whole text in the title |
| `rec2(html, full, sub, subFull)` | the record cell of ui.md rule 9: the name on line one over a muted second line (`.c1`), so every row is the same two lines high |

```html
<link rel="stylesheet" href="/static/tokens.css">
<link rel="stylesheet" href="/static/ui.css">
<script src="/static/kb-ui.js"></script>
<script>main.innerHTML = kbUi.secHead("runs", "Runs", 12) + kbUi.tblRec([[kbUi.rec2("a", "a", "where", "where"), "3 min"]]);</script>
```

`ui.css` uses only `tokens.css` values, and a site overrides a rule in its own CSS, after this file. It defines `.muted`, `.sec`, `.err`, `.c1`, `.c2`, `.c12`, `table.rec` and `details.cfold`, so a site's own CSS gives those names no other meaning.

## Who uses it, and how a change reaches them

- **agent-web** (this repo) embeds the files with `include_bytes!` and serves them flat under `/static/`. A change here ships with the next agent-web build.
- **trader** (`freqtrade_trading_attempt`) pins a dotfiles commit and a sha256 per file in `web/kit.lock`. A change reaches it only when that lock is bumped.

A pinned site's `kit.lock` is JSON: `repo`, `commit`, `path` (this directory) and `files`, a sha256 per kit file it serves. Its image build fetches `fetch-kit.py` at the pinned commit and runs it, so a file whose hash is not the lock's fails the build before any file is written:

```dockerfile
ADD --checksum=sha256:<sha256 of fetch-kit.py> https://raw.githubusercontent.com/Kblack0610/.dotfiles/<commit>/.local/src/web-kit/fetch-kit.py /tmp/fetch-kit.py
RUN python3 /tmp/fetch-kit.py web/kit.lock web/static/kit
```

`kit-lock bump <site kit.lock> [<commit>]` moves a site to a kit commit (default `origin/main`): it rewrites the lock's commit and every hash, and the Dockerfile's `ADD` line, so the bump is one commit in the site's repo. To give a site a new kit file, add its name to `files` with any hash and bump. `kit-lock status` lists each site in `~/.config/web-kit/sites` with its pin, the kit commits since, and whether this README changed in between; it exits 1 when one did, since that site then needs a look before its bump. `tests/unit/kit_lock.bats` covers both and the fetch.

A change that breaks the markup contract updates every site in the list above: agent-web in the same PR, and every pinned site's lock in its own PR.

## Checks

`tests/agent-web/kit.test.mjs` runs the renderers in a vm, checks that each class they draw has a rule in `ui.css`, and that `ui.css` holds no colour or font of its own. `tests/agent-web/text.test.mjs` refuses a hand-built list, error block or fold in agent-web's scripts.

`tests/agent-web/phone/render.mjs` renders agent-web at 390px and 1280px and checks the nav: at 390px the menu shows and opens every group and tab, and Escape closes it; at 1280px the sidebar shows; at both widths there is no sideways scroll. `--wide` shoots every tab at 1280px and `--dark` in the dark scheme, for the before-and-after a token change carries. `--no-kit` serves no `kb-shell.js`, and must fail on "no menu button".
