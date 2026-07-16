# Mermaid syntax by diagram type

Minimal, correct syntax for each type this skill supports. Full spec: https://mermaid.js.org/. Keep one diagram per file; prefer the templates in `assets/` as starting points.

## Flowchart

Process and decision flow. Direction: `TD` (top-down) for hierarchy/decisions, `LR` (left-right) for pipelines.

```
flowchart LR
  A([Start]) --> B{Decision?}
  B -->|yes| C[Do the thing]
  B -->|no| D[Skip]
  C --> E[(Store)]
  D --> E
  E --> F([End])
```

Node shapes (use one shape per concept type, consistently):
- `[text]` rectangle - process/step
- `([text])` stadium - start/end
- `{text}` diamond - decision
- `[(text)]` cylinder - datastore
- `((text))` circle - connector/state
- `[[text]]` subroutine, `>text]` flag/note

Edges: `-->` arrow, `---` line, `-.->` dotted, `==>` thick, `-->|label|` labeled.

Grouping: use `subgraph name ... end` to cluster related nodes. Prefer a subgraph over a tangle of crossing edges.

## Sequence

Interactions over time between participants.

```
sequenceDiagram
  autonumber
  participant U as User
  participant API
  participant DB
  U->>API: request
  API->>DB: query
  DB-->>API: rows
  API-->>U: response
  Note over API,DB: same transaction
```

Arrows: `->>` solid call, `-->>` dashed return, `-x` lost message. Blocks: `alt/else/end`, `opt/end`, `loop/end`, `par/and/end`. `autonumber` numbers the messages.

## Class

Object/type model.

```
classDiagram
  class Player {
    +string serial
    +Firmware fw
    +boot() void
  }
  class Firmware
  Player "1" --> "1" Firmware : runs
  Player <|-- FleetPlayer : extends
```

Relations: `<|--` inheritance, `*--` composition, `o--` aggregation, `-->` association, `..>` dependency.

## State

Lifecycle / status machine.

```
stateDiagram-v2
  [*] --> Provisioning
  Provisioning --> Online : registered
  Online --> Offline : heartbeat lost
  Offline --> Online : reconnect
  Online --> [*] : decommission
```

`[*]` is the start/end pseudo-state. Composite states: `state Name { ... }`. Notes: `note right of Name : text`.

## ER (entity-relationship)

Data model.

```
erDiagram
  PLAYER ||--o{ MANIFEST : serves
  PLAYER {
    string serial PK
    string ip
  }
  MANIFEST {
    string id PK
    string player_serial FK
  }
```

Cardinality (left|right): `||` exactly one, `o{` zero-or-many, `|{` one-or-many, `o|` zero-or-one. Read `A ||--o{ B` as "one A relates to zero-or-many B".

## Architecture (service topology)

`architecture-beta` renders grouped services with typed icons (newer Mermaid). If the target renderer is old, fall back to a `flowchart` with `subgraph` groups.

```
architecture-beta
  group cloud(cloud)[Control Plane]
  service api(server)[API] in cloud
  service db(database)[Postgres] in cloud
  service s3(disk)[Content Bucket] in cloud
  api:R --> L:db
  api:B --> T:s3
```

Ports for edges: `T` top, `B` bottom, `L` left, `R` right (e.g. `api:R --> L:db`). Icon set is limited; keep labels short.

## Gantt

Schedule over calendar time.

```
gantt
  title Rollout
  dateFormat YYYY-MM-DD
  axisFormat %m-%d
  section Staging
  Validate      :a1, 2026-07-20, 3d
  section Prod
  Cut release   :after a1, 2d
  Bake window   :1d
```

Task syntax: `name :id, start, duration` or `:after <id>, <duration>`. Tags: `done`, `active`, `crit`, `milestone`.

## Mindmap

Idea tree / brainstorm.

```
mindmap
  root((Fleet))
    Runtime
      Boot chain
      Harness
    Control plane
      API
      Admin UI
```

Indentation defines hierarchy. Root shape via `((text))`, `[text]`, `(text)`.

## Timeline

Chronology of events.

```
timeline
  title Release history
  2026 Q2 : v0.1.0 cut
  2026 Q3 : Analytics service : Universal base card
```

## Git graph

Branch/commit history.

```
gitGraph
  commit
  branch staging
  checkout staging
  commit
  checkout main
  merge staging
```

## Notes that bite

- Reserved words and special characters in labels: wrap in quotes, e.g. `A["node (with parens)"]`.
- `end` is a keyword; a node literally named `end` must be quoted or capitalized.
- Comments: a line starting with `%%`. The `%%{init: ...}%%` directive must be the first non-empty line to take effect.
- One `flowchart`/`graph` keyword per file. Do not nest diagram types.
