# Style: option matrix (editorial comparison)

> One of four house styles in this skill. Use this **option matrix** style (warm paper
> palette, one big card per option, columns that hold the SAME question for every option,
> one red accent for the thing that bites) when the diagram's job is to help someone
> CHOOSE. For pipelines/data-flow see `style-process-flow.md`; for architecture altitude
> see `style-layered-c4.md`; for branch/release timelines see `style-lane-timeline.md`.
> Exemplar: `assets/example-option-matrix.svg`. Rendering/publish: `rendering.md`.

This is the only house style that is a **standalone explainer** rather than a figure: it
carries its own title, subtitle, and footer, and it is meant to be read on its own in a doc,
a ticket, or a Slack message. Do not embed it in a slide - a slide already has a heading,
and the warm palette fights a deck theme. (`style-layered-c4.md` is the slide style.)

## What it is for

A decision with two to four options where the reader keeps asking the same questions of each
one: how does it work, what does it cost, what happens when we want to change it later. The
matrix answers those questions in **fixed columns** so the reader compares down a column
instead of re-reading three paragraphs.

Use it when:

- You are presenting options and want a recommendation to become obvious rather than asserted.
- The trade-off is not "which is faster" but "who pays, and when" - build cost vs change cost,
  today's work vs the day you need to move.
- The reader is a decision-maker, not an implementer.

Do NOT use it for a single system's flow (that is process-flow), or when the options differ
so much that the columns stop asking the same question - at that point it is three diagrams.

## Anatomy

```
                    TITLE, ALL CAPS, CENTERED
        one subtitle sentence that frames the actual question

  THE OPTION          HOW IT WORKS                    WHAT IT COSTS LATER
  ------------------------------------------------------------------------
 +-------------------+-------------------------------+---------------------+
 | 1. Short name     |   [box] -> [box] -> [box]     | 2-3 short muted     |
 |                   |   micro-flow, 3 steps max     | paragraphs: the     |
 | 2-3 short muted   |                               | consequence         |
 | paragraphs        |                               |                     |
 +-------------------+-------------------------------+---------------------+
 | 2. ...            |   ...                         | ...                 |
 +-------------------+-------------------------------+---------------------+
  ------------------------------------------------------------------------
  Bold lead-in:   the concrete artifact (mono)   trailing clause
  two quiet follow-up lines
```

Five parts, in order:

1. **Title** - all caps, centered, bold, ~20px. States the subject, not the conclusion.
2. **Subtitle** - one centered sentence, muted, that names the real question. This line is
   doing the work: "The question is who puts it there, and what it costs to change it later."
3. **Column headers** - small caps, letter-spaced, grey, above a hairline rule. Each is a
   QUESTION asked of every row. Three columns is the sweet spot; four is the ceiling.
4. **Option rows** - one large rounded card per option, split by hairline vertical dividers
   into the columns. Left = the name + the plain-English gist. Middle = a micro-flow.
   Right = the consequence.
5. **Footer band** - below a second rule: what is the same across the options (the part the
   reader does not have to decide), and any literal artifact in mono.

## Palette (warm paper)

Deliberately warmer than the other house styles - it reads as a printed handout rather than
an engineering figure, which is the point when the audience is deciding rather than building.

| Token   | Hex       | Used for |
|---------|-----------|----------|
| INK     | `#1a1a1a` | title, option names, box titles, arrows |
| BODY    | `#55565a` | the muted paragraphs (never black body text) |
| SUB     | `#6a6b6f` | the small line inside a box |
| EYEBROW | `#8a8a8a` | column headers, letter-spaced small caps |
| EDGE    | `#d9cec2` | THE signature: warm tan card + box outlines, and the rules |
| SEAM    | `#e8e0d6` | the lighter vertical dividers inside a card |
| RED     | `#c8452c` | THE ACCENT: the catch, the caveat, the thing outside our control |

Canvas stays transparent (house rule); render `-b white`. There is no fill on the cards or
the boxes - the tan outline alone carries the structure, and that restraint is what makes it
read as editorial rather than as a dashboard.

## The red rule (the whole style in one line)

**At most one red phrase per row, and it is the sentence the reader would otherwise miss.**

Red is spent on the condition that makes the option expensive later - `on the first boot
only`, `players re-read them every minute`, `both up at that moment`. It is not for
emphasis, headings, or "important" generally. A row with two red phrases has not decided
what its catch is.

Red has exactly two forms:

- **Red bold text** as the last line inside a box: the condition attached to that step.
- **A dashed red outline** on a box (`stroke:#c8452c; stroke-dasharray:6 4`): this step
  depends on something we do not control. Use it at most once in the whole diagram; it is
  the strongest mark available and it should point at the single real risk.

## The micro-flow (middle column)

Three boxes maximum, left to right, short black arrows between them. Each box is:

```xml
<rect class="box" x="418" y="183" width="134" height="74" rx="8"/>
<text class="b-title" x="485" y="209">Written next to</text>   <!-- 11.5 bold ink -->
<text class="b-sub"   x="485" y="228">their page</text>        <!-- 10.5 muted -->
<text class="b-accent" x="485" y="246">on the first boot only</text>  <!-- 10.5 bold red -->
```

- The box title is a **verb phrase for what happens**, not a component name. "Written next
  to their page" beats "Provisioning step".
- The sub-line is the quiet clarifier; the optional third line is the red catch.
- **Fan-in** (two ways in, one result) is the one allowed departure from a straight chain:
  stack two boxes on the left, one on the right, two diagonal arrows converging. Put a
  lead-in line above it saying what the reader is looking at ("Two ways in, one result.").
- A **trailing note** under the flow carries a caveat that belongs to the whole row, not to
  one box.

Arrows are plain black (`#1a1a1a`, width 1.6) with a small solid triangle marker. Arrow
colour carries no meaning in this style - the boxes and the red do the semantic work.

## Writing the cells

The prose is most of the diagram, so it gets the same discipline as the shapes:

- **Left cell**: `N. Short imperative name` in bold, then two short paragraphs. First says
  what happens in plain words. Second says what is different about this one.
- **Right cell**: lead with the consequence, not the mechanism. Give a number or a unit of
  work where you have one ("about a minute", "per player", "field visit"). If there is a
  build cost, it gets its own final paragraph starting "Build cost:".
- Two to three sentences per paragraph, hard ceiling. Anything longer belongs in the doc
  this diagram links to.
- Plain ASCII throughout: `->`, not a Unicode arrow; a hyphen, not an em dash.

## Layout math

The exemplar uses `viewBox="0 0 1240 890"`:

- Card block `x=52 width=1136`. Column seams at `x=396` and `x=900` (so 344 / 504 / 288).
  The middle column is widest because it holds shapes; the right is narrowest because it
  holds the shortest prose.
- Text pad is 24 from a seam; box pad is 22.
- Row cards `rx=14`, `stroke-width=1.2`. Rows are as tall as their content needs - a row with
  a fan-in is taller than a row with a chain, and that is fine. Leave 20 between rows.
- Body line-height 15px; paragraph gap 10px on top of that.
- Micro-flow boxes `rx=8`, height 74, width ~134, gap 32.

## Anti-patterns

- **A fourth column.** By then the reader is doing a table's job; write a table.
- **Filling the boxes.** A tinted fill turns the handout into a dashboard and kills the
  editorial feel. Outline only.
- **Red as emphasis.** If everything worth reading is red, nothing is.
- **A conclusion in the title.** The subtitle frames the question; the rows earn the answer.
  If you already know the answer, you want a one-pager, not this.
- **Embedding it in a deck.** It has its own title and a warm palette; use the C4 style there.
