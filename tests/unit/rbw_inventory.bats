#!/usr/bin/env bats
# rbw-inventory: snapshot and diff a vault around a reorganisation. rbw is a stub over a fixture
# vault: list.tsv (id, folder, name) and raw/<id>.json; `get --raw <needle>` takes an id or a
# name, and a name shared by two entries fails as ambiguous, as real rbw does without --folder.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic

  INV="$REPO_ROOT/.local/bin/rbw-inventory"
  export SANDBOX XDG_RUNTIME_DIR="$SANDBOX/run"
  V="$SANDBOX/vault"
  mkdir -p "$XDG_RUNTIME_DIR" "$V/raw"
  cat > "$SANDBOX/bin/rbw" <<'STUB'
#!/usr/bin/env bash
V="$SANDBOX/vault"
case "$1" in
  sync) exit 0 ;;
  list) cat "$V/list.tsv" ;;
  get)
    n="${3:-}"
    [ -f "$V/raw/$n.json" ] && { cat "$V/raw/$n.json"; exit 0; }
    ids=$(awk -F'\t' -v n="$n" '$3==n {print $1}' "$V/list.tsv")
    c=$(printf '%s' "$ids" | grep -c .)
    [ "$c" = 1 ] && { cat "$V/raw/$ids.json"; exit 0; }
    [ "$c" -gt 1 ] && { echo "rbw get: multiple entries found: $n" >&2; exit 1; }
    echo "rbw get: couldn't find entry for '$n'" >&2; exit 1 ;;
  *) exit 1 ;;
esac
STUB
  chmod +x "$SANDBOX/bin/rbw"
  entry id1 "" svc_key s3cret-one
  entry id2 "" "dup token" s3cret-two
  entry id3 "" dup_token s3cret-two
}

# entry <id> <folder> <name> <password>: add one fixture entry
entry() {
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$V/list.tsv"
  printf '{"id":"%s","name":"%s","data":{"password":"%s"},"notes":null,"history":[]}\n' "$1" "$3" "$4" > "$V/raw/$1.json"
}

@test "a snapshot never writes a secret value and is private to the user" {
  run "$INV" snap base
  assert_success
  assert_output --partial "snap base: 3 entries"
  run grep -r s3cret "$XDG_RUNTIME_DIR/rbw-inventory"
  assert_failure
  [ "$(stat -c %a "$XDG_RUNTIME_DIR/rbw-inventory/base.json")" = 600 ]
  [ "$(stat -c %a "$XDG_RUNTIME_DIR/rbw-inventory/key")" = 600 ]
}

@test "moving an entry into a folder is clean when its name still resolves" {
  "$INV" snap a
  sed -i 's/^id1\t\t/id1\tagents\t/' "$V/list.tsv"
  "$INV" snap b
  run "$INV" diff a b
  assert_success
  assert_output --partial "moved: svc_key: '' -> 'agents'"
  assert_output --partial "ok (0 problems)"
}

@test "removing one of two identical duplicates loses nothing, and its own name must be allowed" {
  "$INV" snap a
  run "$INV" dups a
  assert_output --partial "same: data, fields, notes, history; differ: -"
  sed -i '/^id2\t/d' "$V/list.tsv"
  "$INV" snap b
  run "$INV" diff a b
  assert_failure
  refute_output --partial "LOST"
  assert_output --partial "BROKEN: rbw get 'dup token'"
  run "$INV" diff a b --allow "dup token"
  assert_success
  assert_output --partial "removed: dup token [id2]"
}

@test "negative control: removing an entry whose content has no copy is LOST" {
  "$INV" snap a
  sed -i '/^id1\t/d' "$V/list.tsv"
  "$INV" snap b
  run "$INV" diff a b
  assert_failure
  assert_output --partial "LOST: svc_key [id1]"
  assert_output --partial "BROKEN: rbw get 'svc_key' resolved before and is missing now"
  run "$INV" diff a b --allow svc_key
  assert_success
}

@test "a rename that a caller would miss is BROKEN even when the content survives" {
  "$INV" snap a
  sed -i 's/\tsvc_key$/\tsvc-key/' "$V/list.tsv"
  "$INV" snap b
  run "$INV" diff a b
  assert_failure
  assert_output --partial "renamed: svc_key -> svc-key"
  assert_output --partial "BROKEN: rbw get 'svc_key'"
}

@test "a folder that makes a name ambiguous is BROKEN" {
  entry id4 trading svc_key s3cret-other
  sed -i '/^id4\t/d' "$V/list.tsv"
  "$INV" snap a
  printf 'id4\ttrading\tsvc_key\n' >> "$V/list.tsv"
  "$INV" snap b
  run "$INV" diff a b
  assert_failure
  assert_output --partial "is ambiguous now"
}

@test "an edited secret is CHANGED" {
  "$INV" snap a
  sed -i 's/s3cret-one/s3cret-new/' "$V/raw/id1.json"
  "$INV" snap b
  run "$INV" diff a b
  assert_failure
  assert_output --partial "CHANGED: svc_key [id1]: data"
}

@test "clean deletes the snapshots and the key" {
  "$INV" snap a
  run "$INV" clean
  assert_success
  [ ! -e "$XDG_RUNTIME_DIR/rbw-inventory" ]
}

@test "any removal prints the permanent-delete note, history or not" {
  "$INV" snap a
  sed -i '/^id2\t/d' "$V/list.tsv"
  "$INV" snap b
  run "$INV" diff a b --allow "dup token"
  assert_success
  assert_output --partial "note: 1 removed."
  assert_output --partial "an rbw remove is permanent"
}
