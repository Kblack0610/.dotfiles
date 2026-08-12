# Marp Slide Creation Best Practices

Guidelines for creating "cool" high-quality slides.

## Slide Titles (h2)

### ✅ Good Examples
- **Concise**: A short noun phrase, ~2–6 words — label the idea, don't narrate it
- **Clear**: Content is immediately understandable
- **Consistent**: Use the same style at the same hierarchy level

```markdown
## Introduction
## Problem
## Solution
## Results
```

### ❌ Bad Examples
```markdown
## In this section we will explain the introduction
## What are the challenges we are facing
```

## Bullet Points

### ✅ Good Examples
- **3-5 items**: Not too many
- **Concise**: One line each, ~6–12 words — no wrapping to a second line
- **Parallel**: Same grammatical structure at the same level

```markdown
- Simple and easy to understand
- Unified design
- Effective information delivery
```

### ❌ Bad Examples
```markdown
- This is a very long explanation that doesn't fit on one line and becomes difficult to read
- Short
- The next item is in sentence format. This lack of uniformity makes it hard to read.
```

## Slide Structure

### Basic Structure

1. **Title Slide** (`<!-- _class: lead -->`)
   - Title
   - Presenter name
   - Date

2. **Agenda Slide**
   - Show overall flow
   - About 3-5 items

3. **Content Slides**
   - 1 slide = 1 message
   - Title summarizes content

4. **Summary Slide**
   - Reconfirm key points
   - Words of thanks

### Section-Budget Standard (the "critical window")

Size a deck by **section**, not by a single global cap. A deck is a sequence of sections,
each of which must land inside one audience attention span. This is the canonical sizing
rule — other docs link here rather than restating it.

- A deck = **title + N sections + summary**; each section opens with a divider (`---`
  slide or a section-header slide).
- **3–7 content slides per section** (sweet spot 4–5). Past ~7, the audience loses the
  thread — that's the signal to **split the section or cut**, never to shrink fonts to fit.
- **One idea per slide**: ≤ ~6 bullets, *or* a single table/diagram.
- **Purpose filter**: for each section ask *"what does this audience most need here?"* —
  cut anything that doesn't serve the deck's stated purpose and audience.
- **Totals fall out of the section math.** As a rough cross-check against talk length:
  ~5 min → 1 section (5–8 slides); ~10 min → 2 sections (10–15); ~20 min → 3–4 sections
  (15–25). If the math and the section count disagree, trust the section budget.

### Tables & ASCII diagrams as content

A single table or a fenced ASCII diagram counts as **one idea** and is often clearer than
a bullet list — e.g. a layer/stack view, a before/after comparison, or a small matrix.

- Reuse the theme's styling; **avoid inline `<style>`** so the slide stays consistent.
- One table or one diagram per slide — if it needs scrolling or a tiny font, split it.

```markdown
## What we add on top

| Layer     | Provided by  | We control |
|-----------|--------------|------------|
| Platform  | us           | ✅         |
| Seam      | the contract | ✅         |
| Base      | the vendor   | —          |
```

## Text Amount

### ✅ Good Balance

```markdown
## Product Features

- High-speed processing
- Intuitive UI
- Highly extensible design
```

### ❌ Too Crowded

```markdown
## About the Product

This product was developed using the latest technology.
The main features include the following 7 points:
- Feature 1: Detailed explanation continues at length...
- Feature 2: Even more detailed explanation...
(Continued)
```

## Using Whitespace

- **Adequate whitespace**: Don't cram too much information
- **Visual guidance**: Layout that naturally draws eyes to important information
- **Breathing room**: Appropriate "pauses" between slides

## Using Colors

Leverage colors defined in the theme:
- **Background color**: `#f8f8f4` (light beige)
- **Text color**: `#3a3b5a` (dark navy)
- **Heading color**: `#4f86c6` (blue)
- **Accent color**: `#000000` (black)

### When Using Additional Colors

```markdown
<span style="color: #c62828;">Important point</span>
```

Use sparingly and avoid excessive decoration.

## Using Images

### Effective Usage

- **Clear purpose**: To aid understanding, not just decoration
- **High quality**: Use high-resolution images
- **Appropriate size**: Neither too large nor too small

### Layout Tips

```markdown
# Text on left, image on right
![bg right:40%](image.png)

- Point 1
- Point 2
```

## Font Size Guidelines

Defined in the theme:
- h1: 56px (title slide only)
- h2: 40px (regular slide titles)
- h3: 28px (subheadings)
- Body text: 22px

## Animations and Transitions

Marp does not support animations by default.
Focus on simple slide transitions.

## Checklist

After completing slides, verify:

- [ ] Are titles concise (short noun phrase, ~2–6 words)?
- [ ] Are bullet points 3-5 items, one line each?
- [ ] Is it 1 slide = 1 message?
- [ ] Does every section stay within 3–7 content slides?
- [ ] Is there sufficient whitespace?
- [ ] Are images / tables / diagrams used effectively?
- [ ] Is there overall consistency?
- [ ] Did it render cleanly (no slide overflow)?
