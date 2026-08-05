# shellcheck shell=bash
# harnesses/binks.sh - NOT IMPLEMENTED. Refuses by design.
#
# Contract rule 3: a harness that cannot enforce a role's denials must refuse to
# run, never degrade to unrestricted. Flipping HARNESS=claude to HARNESS=binks must
# not quietly drop the guarantee - prose asserting a restriction that nothing
# checks is the exact failure this design exists to kill.
#
# A stub that refuses is worth more than an adapter that pretends.
#
# To implement: prove binks can express ROLE_WRITE/ROLE_TASK/ROLE_BASH denials and
# pin an MCP set, make harness_supports return non-zero for anything it cannot,
# then document the mapping in docs/harnesses/binks.md.

harness_supports() {
  echo "harness 'binks' has no capability enforcement implemented yet." >&2
  echo "Refusing rather than running role '$ROLE_NAME' unrestricted (contract rule 3)." >&2
  return 1
}

harness_exec() { echo "agentctl-run: binks harness unimplemented" >&2; exit 78; }
