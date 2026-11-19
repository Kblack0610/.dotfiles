# has_private: $PRIVATE is the top of a checkout (a clone or a worktree, whose .git is a file).
# A test that reads the private repo checks this first and says what it left unchecked.
has_private() { [ "$(git -C "$PRIVATE" rev-parse --show-toplevel 2>/dev/null)" = "$(realpath -q "$PRIVATE")" ]; }
