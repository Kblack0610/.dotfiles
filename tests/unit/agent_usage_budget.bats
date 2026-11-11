#!/usr/bin/env bats
# agent-usage budget: one line per ledger bill, each read from the system that bills it; a bill that
# cannot be read or priced is named and left out of the total, never counted as $0. Every reader is a stub.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  export AU="$REPO_ROOT/.local/bin/agent-usage"
  export BUDGET_LEDGER="$HOME/budget" TOKENS_DIR="$HOME/token-usage" CLAUDE_ACCT_CONFIG="$HOME/accounts"
  export PROM_LIB="$HOME/prom-stub.sh" FIX="$HOME/fix" BUDGET_LAZER_BIN="$HOME/bin/lazer-spend"
  export BUDGET_NOW="2026-11-11T00:00:00-08:00"   # day 10 done: a third of a 30-day month
  mkdir -p "$TOKENS_DIR" "$FIX" "$HOME/bin"
  export PATH="$HOME/bin:$PATH"
  printf 'main -\nbnb ~/.claude-bnb\n' > "$CLAUDE_ACCT_CONFIG"
  cat > "$BUDGET_LEDGER" <<'EOF'
# a comment line, and a trailing one below
main   subscription 100 ref=main   # fee
bnb    subscription 200 ref=bnb
codex  subscription 20  ref=codex
lazer  litellm      -
gh     github       -   ref=Org
aws    aws          -
do     digitalocean -
EOF
  for d in 01 02 03 04 05 06 07 08 09 10; do
    echo '{"fleet_cost":{"by_account":{"claude":{"usd":10},"claude-bnb":{"usd":30}},"other_harness":{"codex":{"usd":2}}}}' > "$TOKENS_DIR/2026-11-$d.json"
  done
  echo '{"spend": 20, "max_budget": 250}' > "$FIX/lazer"
  echo '{"budgets":[{"budget_product_sku":"actions","budget_amount":220},{"budget_product_sku":"packages","budget_amount":0}]}' > "$FIX/gh-budgets"
  echo '{"usageItems":[{"product":"actions","netAmount":30},{"product":"git_lfs","netAmount":3}]}' > "$FIX/gh-usage"
  echo '[{"metric":{"kind":"actual"},"value":[0,"100"]},{"metric":{"kind":"limit"},"value":[0,"600"]},{"metric":{"kind":"forecast"},"value":[0,"350"]}]' > "$FIX/aws"
  echo '{"month_to_date_usage":"50.00"}' > "$FIX/do"
  cat > "$HOME/bin/lazer-spend" <<'EOF'
#!/usr/bin/env bash
cat "$FIX/lazer"
EOF
  cat > "$HOME/bin/gh" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *budgets*) cat "$FIX/gh-budgets" ;;
  *"usage?year=2026&month=11"*) cat "$FIX/gh-usage" ;;
  *) exit 1 ;;
esac
EOF
  cat > "$HOME/bin/doctl" <<'EOF'
#!/usr/bin/env bash
cat "$FIX/do"
EOF
  cat > "$PROM_LIB" <<'EOF'
prom_q() { [ -s "$FIX/aws" ] || return 1; printf '{"status":"success","data":{"result":%s}}' "$(cat "$FIX/aws")"; }
EOF
  chmod +x "$HOME/bin/"*
}

b() { "$AU" budget --json | jq -c "$1 | walk(if type == \"number\" then . + 0 else . end)"; }

@test "every bill is read from its own system, and the totals are the sum of the lines" {
  run b '[.lines[] | [.name, .cap, .spent, .projected, .status]]'
  assert_success
  assert_output '[["main",100,100,100,"ok"],["bnb",200,200,200,"ok"],["codex",20,20,20,"ok"],["lazer",250,20,60,"ok"],["gh",220,33,99,"ok"],["aws",600,100,350,"ok"],["do",null,50,150,"ok"]]'
  run b '[.total.spent, .total.projected, .total.caps, .partial]'
  assert_output '[523,979,1390,[]]'
}

@test "a subscription carries its account's list-price work from the month's snapshots, a dot dir included" {
  rm "$TOKENS_DIR/2026-11-04.json"
  echo 'not json' > "$TOKENS_DIR/2026-11-05.json"
  run b '[(.lines[] | select(.kind == "subscription") | .list_usd), .list_days, .total.list_usd]'
  assert_success
  assert_output '[80,240,16,{"covered":8,"due":10},336]'
}

@test "an unread bill is named and left out of the total, never \$0 (negative control)" {
  echo 'gateway down' > "$FIX/lazer"; : > "$FIX/aws"
  run b '[(.lines[] | select(.name == "lazer" or .name == "aws") | [.status, .spent]), .partial, .total.spent]'
  assert_success
  assert_output '[["unread",null],["unread",null],["lazer","aws"],403]'
  run "$AU" budget
  assert_success
  assert_output --partial 'partial, not counted: lazer, aws'
}

@test "a bill with no known price is unpriced, and a pool past its cap is over and ends the month at its spend" {
  sed -i 's/^codex  subscription 20 /codex  subscription ? /' "$BUDGET_LEDGER"
  echo '{"spend": 228, "max_budget": 50}' > "$FIX/lazer"
  run b '[(.lines[] | select(.name == "codex" or .name == "lazer") | [.status, .spent, .projected]), .partial]'
  assert_success
  assert_output '[["unpriced",null,null],["over",228,228],["codex"]]'
}

@test "a ledger line of an unknown kind, a bad price or a copied cap is refused with its line number" {
  echo 'x cloud 5' >> "$BUDGET_LEDGER"
  run "$AU" budget
  assert_failure
  assert_output --partial ':9: want `name kind usd_month'
  sed -i '$d' "$BUDGET_LEDGER"; echo 'x digitalocean five' >> "$BUDGET_LEDGER"
  run "$AU" budget
  assert_failure
  assert_output --partial "usd_month 'five' is not a number"
  sed -i '$d' "$BUDGET_LEDGER"; echo 'x digitalocean 40' >> "$BUDGET_LEDGER"
  run "$AU" budget
  assert_failure
  assert_output --partial "a digitalocean bill's cap comes from its system"
}
