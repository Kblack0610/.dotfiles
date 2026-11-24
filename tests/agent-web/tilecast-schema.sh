#!/usr/bin/env bash
# Checks what agent-web's /widget.json serves (hub_core::widget_doc) against the Tilecast widget
# document schema, with the format repo's own checker (spec/test/check.mjs) at the commit
# TILECAST_REV pins: the schema has one home, the tilecast repo, and this never copies it. Bump the
# pin when the format changes. The document is dumped by an ignored hub-core test that maps cards
# of every shape (a full card, one over every length cap, a failed reader, one still reading, an
# unknown card id). Needs cargo, node and npm; the CI rust job runs it when hub-core is picked.
# The repo is private (hc-914): CI reads it with the repo-reader token in TILECAST_READ_TOKEN, a
# workstation with forgejo-token.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

TILECAST_API=https://git.kennethblack.me/api/v1/repos/kblack0610/tilecast
TILECAST_REV=30b556339e5a1ad0062421218ac15ad528c2e0bd

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT

token=${TILECAST_READ_TOKEN:-$(forgejo-token)}
curl -fsSL --retry 3 -H "Authorization: token $token" "$TILECAST_API/archive/$TILECAST_REV.tar.gz" | tar -xz -C "$scratch"
npm ci --silent --no-audit --no-fund --prefix "$scratch/tilecast"

TILECAST_DOC_OUT="$scratch/doc.json" cargo test --quiet --manifest-path .local/src/hub-core/Cargo.toml \
  widget_doc::tests::dump_for_schema_check -- --ignored --exact
node "$scratch/tilecast/spec/test/check.mjs" "$scratch/doc.json"
