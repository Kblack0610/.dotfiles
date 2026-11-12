# web-kit

The shared site shell for every kblab site: design tokens, the two fonts, and `<kb-shell>`, the top bar with tabs under group headings. It shows as a fixed sidebar from 900px, and as a menu button with a dropdown below that. There is no build step and no dependency: plain CSS and one ES module, in light DOM, so a site's own CSS and server-rendered links work inside it.

| File | What it is |
|---|---|
| `tokens.css` | `:root` palette, type scale, dark mode, the two `@font-face` rules, and the body base |
| `shell.css` | The bar, the sidebar, and the phone dropdown. 900px is the one nav breakpoint |
| `kb-shell.js` | The `<kb-shell>` custom element: adds the menu button and the open tab's name |
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
- `tokens.css` names the fonts relative to itself (`url(inter.woff2?v={{v}})`), so serve the fonts beside it. A site that versions its assets substitutes `{{v}}`; one that does not serves the literal query, which is ignored.

## Who uses it, and how a change reaches them

- **agent-web** (this repo) embeds the files with `include_bytes!` and serves them flat under `/static/`. A change here ships with the next agent-web build.
- **trader** (`freqtrade_trading_attempt`) pins a dotfiles commit and a sha256 per file in `web/kit.lock`. A change reaches it only when that lock is bumped.

A change that breaks the markup contract updates every site in the list above: agent-web in the same PR, and every pinned site's lock in its own PR.

## Checks

`tests/agent-web/phone/render.mjs` renders agent-web at 390px and 1280px and checks the nav: at 390px the menu shows and opens every group and tab, and Escape closes it; at 1280px the sidebar shows; at both widths there is no sideways scroll. `--no-kit` serves no `kb-shell.js`, and must fail on "no menu button".
