---
name: quick-demo
description: >-
  Build a small single-file web game or page, check it in a scratch Firefox, publish it as a public binks demo link and hand the link over. Use for "make a quick demo", "build a little game and share it", "publish this html". Game perf or look: game-eval.
metadata:
  category: authoring
  tags: [binks, demo, html, game, publish]
  system: [gameplay, deploy]
  reviewed: "2026-11-18"
---

# quick-demo

Turns "make me a small game or page someone can open" into a link: one self-contained html file, run once in the same sandbox a published demo gets, then published through binks-api with `binks-demo`. The link (`https://<publish host>/p/<id>`) opens for anyone, expires after the server's TTL (30 days by default), and its owner can delete it.

## Scope and triggers

- A user or a plan wants a quick playable game, toy or page they can open or send on.
- An html file already exists and needs a shareable link.

Not for a real app or anything that needs a server, an account or the network: a demo has no network at all. Not for perf or art passes on a Unity game (`game-eval`), or screenshots of a live site (`web-capture`).

## Steps

1. **Build one file.** Write `<name>.html` in the working repo or the session's scratch dir. The rules are the sandbox's, so a page that breaks one fails the check:
   - Inline every script, style, font and image (`data:` URLs). Any outside URL is blocked, and so are `fetch`, XHR, WebSocket and forms.
   - Give it a `<title>`: it names the demo in `binks-demo list` and the owner's My demos.
   - The page runs on an opaque origin: `localStorage` and cookies throw, so wrap storage in try/catch and work without it.
   - A canvas game: a `requestAnimationFrame` loop, resize to the window, keyboard and touch input, pause on `blur`.
   - Keep it well under 1 MB (the server refuses more); aim for under about 100 KB.
2. **Check it.** `binks-demo check <name>.html --shot <name>.png`. It loads the page in a headless scratch Firefox over Marionette, inside the sandboxed wrapper and CSP that `/p/<id>` serves, and prints PASS or one `FAIL` line per JavaScript error, unhandled rejection, CSP violation, missing title, oversize or blank page. Read the screenshot to see that it looks right. Fix and re-run until it passes; never publish a FAIL.
3. **Publish it.** `binks-demo publish <name>.html` prints only the link. To replace a demo, publish again and delete the old one: a link never changes content.
4. **Hand it over.** Give the link in the answer, with one line on what the demo is and how to play it. Say it expires in the TTL the server reports and that `binks-demo delete <id>` takes it down.

`binks-demo list` shows the fleet account's live demos (id, expiry, link, title); `binks-demo delete <id>` removes one.

## Setup

`binks-demo` reads the API at `BINKS_API_URL` (default `https://binks.chat`) and a bearer token from `BINKS_DEMO_TOKEN`, or else the `BINKS_DEMO_TOKEN` key of the sops file named by `BINKS_DEMO_SECRET` in `~/.config/binks-demo/env` (private overlay), decrypted at each call and passed to curl on stdin.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `no token: set BINKS_DEMO_TOKEN, or BINKS_DEMO_SECRET in ...` | No env token and no env file: see Setup. |
| `no token could be read from <file>` | sops could not decrypt it (no age key, wrong path) or the value is not one token. |
| `the token was refused (401)` | Wrong, expired or revoked token; `/api/demos` takes a binks.chat session token or a `bk_pat_` API token. |
| `publish: not found (404)` | Publishing is off on that server (`PUBLISH_ENABLED=false`), or `BINKS_API_URL` is wrong. |
| `publish failed (403): Publishing demos needs Binks Plus` | The account is not on Plus and the server's `DEMO_PUBLISH_TIER` is `plus`. |
| `publish failed (429)` | The per-day or live-demo cap; delete old demos (`binks-demo list`, `delete`). Never retry in a loop. |
| `publish failed (413)` | Over the size cap: shrink the page, inline less. |
| check: `csp: ... blocked https://...` | An outside script, style, font or image: inline it or use a `data:` URL. |
| check: `SecurityError ... localStorage` | Storage on an opaque origin: wrap it in try/catch. |
| check: `the page drew nothing` | No text, image or svg, and every 2d canvas still transparent after two frames: the game never drew its first frame. |

## Do NOT

- Publish a page that failed the check, or one holding a secret, a token or personal data: the link is public and unlisted, not private.
- Point the check at the live Firefox profile, or start Firefox by hand for it: `binks-demo check` makes and removes its own scratch profile.
- Retry a refused publish in a loop: a 429 is a cap, and a repeated POST publishes twice.
