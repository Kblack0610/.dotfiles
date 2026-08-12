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
- [ ] Directory is `.claude/skills/<category>/<name>/`, and `metadata.category`
      agrees with the directory
- [ ] Frontmatter `name` matches the directory name
- [ ] `description` leads with the key use case and names the sibling skills it
      is *not* (the router chooses between 60 of these on description alone)
- [ ] `metadata.reviewed` bumped **only if the claims were actually re-verified**
      against reality - a date that lies is worse than a date that is old
- [ ] Plain ASCII: no em/en dash, arrows, ellipsis, `>=`/`<=` glyphs
- [ ] Right repo: anything matching `.githooks/sensitive-tokens.txt` belongs in
      `~/.dotfiles-private`, and a new public skill needs a `.gitignore`
      allowlist line
- [ ] Nothing references the skill by its **repo** path - consumers use
      `~/.claude/skills/<name>/`, which survives re-categorisation and a move
      between the two repos
