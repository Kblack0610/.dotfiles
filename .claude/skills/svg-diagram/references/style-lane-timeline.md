# Style: lane timeline (branch / release graph)

> One of four house styles in this skill. Use this **lane timeline** style (horizontal
> colour-coded lanes, commit dots, rounded branch-off and merge-back curves, dashed for a
> merge that runs against the normal flow) for anything where the payload is WHEN things
> happen and WHICH track they happen on: git branching strategies, release trains,
> environment promotion, migration phases, incident timelines. For pipelines see
> `style-process-flow.md`; for architecture see `style-layered-c4.md`; for a decision
> between options see `style-option-matrix.md`. Exemplar: `assets/example-lane-timeline.svg`.
> Rendering/publish: `rendering.md`.

Like the option matrix, this is a **standalone explainer**: it carries its own title and
sub-caption and is read on its own in a doc or a ticket. Unlike every other style here, the
X axis means something (time, left to right) and Y means something (proximity to the
customer, higher is closer). Nothing is placed for looks.

## The two axes (get these right and the diagram explains itself)

- **X is time.** Always left to right. There is no scale and no tick marks - only order and
  rough spacing. Do not put two things at the same x unless they truly happen together.
- **Y is proximity to the customer.** The topmost lane is what the customer runs
  (`main`, `production`); the bottom lane is the least finished work (`feature/*`,
  `short/*`). Every reader then knows, without a legend, that a curve going UP means work
  getting closer to shipping.

State those two sentences in the sub-caption. They are the entire legend.

## Panels: one philosophy per panel

The style earns its keep when you show **several approaches to the same thing** stacked as
panels, so a reader can compare them by eye. Each panel is a white card holding one
approach, with:

- **A numbered heading on one baseline**: `1 - Git Flow` in bold ink, then the one-sentence
  characterisation in the SAME `<text>` as a muted `<tspan>` (regular weight, grey). Keeping
  it on one line is what makes a stack of panels scan. Use a plain hyphen as the separator,
  never a middot.
- **The lanes**, gutter-labelled on the left.
- **Inline annotations** in the lane's own colour for anything a reader would otherwise have
  to infer (`feature work`, `stabilize / QA`, `back-merge`, `hotfix = an ordinary branch,
  just shorter`).

Hold the **same colour for the same role in every panel**. That is what makes the panels
comparable: the reader learns "purple = short-lived work" once and reads all four panels
with it. If one approach has no lane for a role, its absence is itself the finding.

## Palette (role, not decoration)

| Role | Hex | Lane |
|---|---|---|
| trunk / what ships | `#16181d` near-black | `main`, `trunk` |
| integration | `#2563eb` blue | `develop` |
| short-lived work | `#7c3aed` purple | `feature/*`, `topic/*`, `short/*` |
| stabilisation | `#15803d` green | `release/*` |
| **emergency** | `#c62828` red | `hotfix/*` AND every warning line in the diagram |
| deployed environment | `#b45309` amber | `production`, `pre-prod`, `staging` |
| quiet clarifier | `#6b7280` grey | gutter sub-labels, unannotated notes |

**Red is the emergency path and nothing else.** It is the one colour that means the same
thing in the graph, in the annotations, and in the bottom strip. Amber is for a lane that is
a deployed environment rather than a line of development - the distinction is the whole point
of environment-branch models, so it gets its own colour.

Panels are `fill:#ffffff; stroke:#e3e5e8; rx:8` on a transparent canvas (house rule). To
reproduce the printed look, render on a light grey page rather than baking one in:
`rsvg-convert -b '#f4f5f6' -z 2 diagram.svg -o diagram.png`.

## The gutter label

Two lines, right-aligned to a fixed `x` (the exemplar uses 182), sitting on the lane's y:

```xml
<text class="lane-name" x="182" y="274" style="fill:#2563eb">develop</text>
<text class="lane-note" x="182" y="287">the integration branch</text>
```

`lane-name` is 12 bold in the lane colour; `lane-note` is 9.5 italic grey. The note is where
you say what this lane corresponds to in another model ("approx GitLab main", "the trunk",
"hours to 2 days"). Spell out `approx` - no `~` glyph games, no Unicode.

## Primitives

**Lane track** - a plain line from the gutter to the right edge, in the lane colour:

```xml
<line class="lane" x1="200" y1="274" x2="1120" y2="274" style="stroke:#2563eb"/>
```

**Commit** - a filled circle, `r=6`, lane colour, no stroke. Space them unevenly; even
spacing reads as a scale, which it is not.

**Branch off and merge back** - one path in the CHILD's colour, drawn as a flat-bottomed U
with rounded corners. Off the parent lane `yP` at `x0`, along the child lane `yC`, back up
to the parent at `x1`:

```xml
<path class="rail" style="stroke:#7c3aed"
      d="M 290,274 C 304,274 306,306 320,306 L 500,306 C 514,306 516,274 530,274"/>
```

The corner radius is the 14/16 in those control points - keep it constant everywhere or the
curves look hand-drawn. A branch that never merges back just stops: drop the trailing curve.

**Merge that runs against the normal flow** - dashed, in the colour of the thing being moved:

```xml
<path class="rail dashed" style="stroke:#c62828" d="..."/>   <!-- stroke-dasharray:6 5 -->
```

Solid means "work moving the normal direction" (up the lanes, toward the customer). Dashed
means back-merge, cherry-pick, or any correction that has to travel the other way - exactly
the step that gets forgotten, which is why it is the one that gets a distinct stroke.

**Tag** - small bold text ABOVE the lane at the commit's x (`v1.1`). A tag produced by the
emergency path is red (`v1.1.1`), which makes the hotfix story legible at a glance.

**Annotation** - 10.5px in the lane colour, placed just above or below its own segment. Not
grey unless it belongs to no lane.

## The bottom strip (the payoff)

The panels show the shapes; the strip says what actually differs. It is:

- A red section heading naming the ONE question you are comparing on
  ("Where the hotfix goes - what actually differs").
- One card per panel, same order and same width, each with the panel's name in bold, two or
  three muted sentences, and **a final sentence in red naming the failure mode** ("Miss one
  and the bug returns.", "Never patch the release alone.").

The red closing line is the reason to build this diagram at all. If you cannot write one per
card, the approaches you are comparing do not actually differ in a way that matters, and the
diagram should be a paragraph.

## Layout math

The exemplar uses `viewBox="0 0 1180 920"`:

- Title `x=40 y=42` at 25 bold; sub-caption `y=68` at 13 muted.
- Panels `x=32 width=1116`, `rx=8`, 16 of vertical gap between them. Height is per-panel:
  give each lane 32-44 of vertical room, plus ~28 above the top lane for the heading and
  tags, plus ~20 below the bottom lane.
- Gutter labels right-aligned at `x=182`; tracks run `x=200` to `x=1120`.
- Strip cards: 3 across at 361 wide with 16 gutters (or 4 across at 267).

If a panel needs more than five lanes, the model you are drawing is probably two models.

## Anti-patterns

- **Colour by branch name instead of by role.** `release/1.4` in one panel and `release/*` in
  another must be the same green, or the comparison silently breaks.
- **A time scale.** The moment you imply real durations, someone will read them.
- **Crossing rails.** Move a commit's x before you accept a crossing; a lane timeline with
  crossed rails is unreadable in a way a boxes-and-arrows diagram is not.
- **Solid strokes for back-merges.** The dashed/solid split is the only thing telling the
  reader which merges are the easy ones to forget.
- **Unicode in the labels.** Middot separators, `>=`, `~`, and arrow glyphs all show up in
  this style's headings and gutter notes. Plain ASCII: `-`, `approx`, `->`.
