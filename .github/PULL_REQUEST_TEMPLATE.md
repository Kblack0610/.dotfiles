# Summary

<!-- What changed and WHY. The why is the part nobody can reconstruct later. -->

## Verification

<!-- What you actually ran, and what it said. Not what you believe is true.
     "Would a staff engineer approve this?" is the bar.

     If you added a test, say you watched it FAIL before it passed - a test that
     cannot fail is not a test. If something could not be verified, say so
     explicitly rather than leaving it implied. -->

- [ ] `make -C tests test-fast` (the tier the Stop hook gates on)
- [ ] `tests/docker.sh lint` if any shell changed
- [ ] `tests/docker.sh test-ui` if anything under `.local/src/tmux/` changed
      (the ui tier starts real tmux servers and must NOT run on a dev box)

## Skills

<!-- Delete this section if no SKILL.md changed. -->

- [ ] `.local/bin/skill-drift --lint .` passes
- [ ] The change meets `.local/src/docs/skills.md`, including the rules no check can read
