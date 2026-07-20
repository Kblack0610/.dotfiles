---
marp: true
theme: kb-tech
paginate: true
---

<!-- Worked example deck: a deck ABOUT the deck system, so it doubles as a
     few-shot reference. Theme by name (kb-tech, from assets/themes/); diagrams
     authored as editable text next to this file (pipeline.d2, flow.mmd) and
     embedded as rendered SVG. Build it:  deck build deck-system  -->

<!-- _class: lead -->

# The `deck` System

Author, preview, and render Marp decks from anywhere

---

## What it is

- One global `deck` CLI — no per-project repo needed
- Themes by name (`kb-tech`, `kb-business`, ...) from the shared theme-set
- Decks live in `~/.notes/lab/decks` and ride the notes sync
- Diagrams authored as **editable text**, rendered to SVG, embedded

---

## Pipeline

![w:1000](pipeline.svg)

---

## Authoring flow

![w:1000](flow.svg)

---

## Commands

```bash
deck new talk --theme tech   # scaffold into the deck home
deck watch talk              # live preview at localhost:8088
deck build talk              # diagrams -> SVG, then PDF
deck doctor                  # what's installed on this machine?
```

---

## Diagrams are text

- `pipeline.d2` (D2) and `flow.mmd` (Mermaid) sit next to this deck
- Edit the source, re-run `deck build` — the SVG and slide update
- D2 needs no browser; Mermaid + PDF export need Chrome/Chromium

---

<!-- _class: lead -->

# Your turn

`deck new <name> --theme tech`
