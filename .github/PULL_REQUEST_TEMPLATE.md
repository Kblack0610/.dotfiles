# Summary

<!-- What changed and WHY. The why is the part nobody can reconstruct later. -->

## Verification

<!-- What you actually ran, and what it said. Not what you believe is true.
     "Would a staff engineer approve this?" is the bar.

     If you added a test, say you watched it FAIL before it passed - a test that
     cannot fail is not a test. If something could not be verified, say so
     explicitly rather than leaving it implied. -->

- [ ] CI `gate` green: it is red unless `fast` (what `tests/pick.sh` picks), `ui`, `rust`, `notes`, `skills` and `lint` all ran and passed, so a `.local/src/tmux/` change gets the ui tier without asking (an agent session runs no test on the workstation)
- [ ] A new test's negative control: the CI run that went red on the commit breaking its subject

## Skills

<!-- Delete this section if no SKILL.md changed. -->

- [ ] `.local/bin/skill-drift --lint .` passes
- [ ] The change meets `.local/src/docs/skills.md`, including the rules no check can read
