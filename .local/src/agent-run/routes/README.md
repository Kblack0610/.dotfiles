# routes -- the transport registry

A `.route` file answers *whose wire, whose money, whose data*, orthogonal to a
`.role`, which answers *what may this agent do*. They compose at invocation; a
`<role>-<route>` matrix file is a bug, not a feature.

## Search path (first hit wins)

    $AGENTCTL_ROUTES/<name>.route            test override, single dir
    ~/.config/agentctl/routes/<name>.route   PRIVATE overlay
    <this dir>/<name>.route                  PUBLIC, ships with the code

## Why anything is private

**A route that names a host, a payer relationship, or a client tier lives in the
private overlay.** This repo is public, and a pre-commit hook enforces it -- it
is what stopped `free-local.route` landing here with an internal address in it.

That split has a useful property beyond secrecy: a machine with no private
overlay resolves `subscription` and then refuses `client` or `free-local` **by
name**, rather than silently doing something else. An unknown route is a loud
failure; a wrong route is a quiet one.

## What ships here

| route | transport | notes |
|---|---|---|
| `subscription` | `anthropic-native` | the personal Max seat, OAuth, no host to name. The built-in default. |

Site-specific routes (`free-local`, `client`, ...) are in the overlay. Run
`agentctl run --explain --role <r>` to see which one resolves and from where --
it costs no tokens and prints the provenance, not just the value.

## Adding one

Every key is explicit; a forgotten one is a hard error rather than a silent `no`.
See `../lib/route.sh` for the five load-time invariants, each of which encodes a
past incident -- most importantly that a gateway route cannot claim
`PERSONAL_SAFE=yes` while sitting behind a failover edge, because failover fires
inside the router *after* the key check, so no scoped key can prevent the spill.
