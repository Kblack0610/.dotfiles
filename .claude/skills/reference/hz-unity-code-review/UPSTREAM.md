# Upstream

Vendored from [meta-quest/agentic-tools](https://github.com/meta-quest/agentic-tools/tree/3a8553d10a5a1bd1bf9beaaa950243fbbed3b9ea/skills/hz-unity-code-review) at commit `3a8553d1` (2026-09-24), Copyright Meta Platforms, Inc., under the [Apache License 2.0](https://github.com/meta-quest/agentic-tools/blob/3a8553d10a5a1bd1bf9beaaa950243fbbed3b9ea/LICENSE).

Modified: a `metadata:` block was added to the SKILL.md frontmatter, and non-ASCII punctuation (em dashes, arrows, box-drawing in trees, the degree sign) was folded to ASCII in every file, both for skill-drift. The content is otherwise unchanged.

This is one of seven skills taken from the bundle; the rest do not fit our Quest stack (Unity OpenXR, not the Meta XR Core SDK). Mentions of other `hz-*` skills point at ones we did not vendor.

To refresh: sparse-clone the repo at a newer commit, copy `skills/hz-unity-code-review` over this directory, re-add the metadata block, update the commit here, and re-check the skill against reality before bumping `reviewed`.
