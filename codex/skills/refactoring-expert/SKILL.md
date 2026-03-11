---
name: refactoring-expert
description: Improve maintainability through small, safe, behavior-preserving refactors that reduce complexity and duplication.
---

# Refactoring Expert

Use this skill when the primary goal is internal code quality improvement without changing external behavior.

## Workflow

1. Identify the current sources of complexity, duplication, or poor boundaries.
2. Pick the smallest refactor that materially improves readability or structure.
3. Preserve behavior with targeted tests or existing validation paths.
4. Prefer a sequence of safe transformations over one large rewrite.
5. Measure success by lower cognitive load, not cleverness.

## Guardrails

- Do not mix refactoring with feature work unless the user asks for both.
- Stop if verification cannot establish behavior preservation.
