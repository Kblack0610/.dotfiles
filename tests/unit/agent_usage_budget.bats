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
  export PROM_LIB="$HOME/prom-stub.sh" FIX="$HOME/fix" BUDGET_JSON="$HOME/budget.json" PROJECT_MAP="$HOME/project-map.json"
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
aws    aws          -   project=playground lane=ci
do     digitalocean -
EOF
  echo '{"aliases":{"engine":"playground"}}' > "$PROJECT_MAP"
  for d in 01 02 03 04 05 06 07 08 09 10; do
    echo '{"fleet_cost":{"by_account":{"claude":{"usd":10},"claude-bnb":{"usd":30}},"other_harness":{"codex":{"usd":2}}}}' > "$TOKENS_DIR/2026-11-$d.json"
  done
  lazer 20 250 1796083200 60   # spend, budget, reset (2026-12-01), claude-acct textfile age
  echo '{"budgets":[{"budget_product_sku":"actions","budget_amount":220},{"budget_product_sku":"packages","budget_amount":0}]}' > "$FIX/gh-budgets"
  echo '{"usageItems":[{"product":"actions","netAmount":30},{"product":"git_lfs","netAmount":3}]}' > "$FIX/gh-usage"
  echo '[{"metric":{"kind":"actual"},"value":[0,"100"]},{"metric":{"kind":"limit"},"value":[0,"600"]},{"metric":{"kind":"forecast"},"value":[0,"350"]}]' > "$FIX/aws"
  echo '{"month_to_date_usage":"50.00"}' > "$FIX/do"
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
prom_q() {
  local f; case "$1" in ci_governor*) f=$FIX/aws ;; *claude_account_*) f=$FIX/lazer ;; *) return 1 ;; esac
  [ -s "$f" ] || return 1; printf '{"status":"success","data":{"result":%s}}' "$(cat "$f")"
}
EOF
  chmod +x "$HOME/bin/"*
}

# lazer <spend> <budget> <reset epoch> <textfile age>: the series claude-acct publishes for the team
lazer() {
  printf '[{"metric":{"__name__":"claude_account_usd_used","account":"lazer"},"value":[0,"%s"]},{"metric":{"__name__":"claude_account_usd_budget","account":"lazer"},"value":[0,"%s"]},{"metric":{"__name__":"claude_account_resets_timestamp_seconds","account":"lazer"},"value":[0,"%s"]},{"metric":{"__name__":"claude_account_textfile_age_seconds"},"value":[0,"%s"]}]' "$@" > "$FIX/lazer"
}

b() { "$AU" budget --json | jq -c "$1 | walk(if type == \"number\" then . + 0 else . end)"; }

@test "every bill is read from its own system, and the totals are the sum of the lines" {
  run b '[.lines[] | [.name, .cap, .spent, .projected, .status]]'
  assert_success
  assert_output '[["main",100,100,100,"ok"],["bnb",200,200,200,"ok"],["codex",20,20,20,"ok"],["lazer",250,20,60,"ok"],["gh",220,33,99,"ok"],["aws",600,100,350,"ok"],["do",null,50,150,"ok"]]'
  run b '[.total.spent, .total.projected, .total.caps, .partial]'
  assert_output '[523,979,1390,[]]'
}

@test "a subscription carries its account's list-price work from the month's finished days, a dot dir included, a bad snapshot skipped" {
  rm "$TOKENS_DIR/2026-11-04.json"
  echo 'not json' > "$TOKENS_DIR/2026-11-05.json"
  echo '[1]' > "$TOKENS_DIR/2026-11-06.json"
  echo '{"fleet_cost":{"by_account":{"claude":{"usd":99}}}}' > "$TOKENS_DIR/2026-11-11.json"   # today: not done yet
  run b '[(.lines[] | select(.kind == "subscription") | .list_usd), .list_days, .total.list_usd]'
  assert_success
  assert_output '[70,210,14,{"covered":7,"due":10,"split":0},294]'
}

@test "an unread bill is named and left out of the total, never \$0 (negative control)" {
  : > "$FIX/lazer"; : > "$FIX/aws"
  run b '[(.lines[] | select(.name == "lazer" or .name == "aws") | [.status, .spent]), .partial, .total.spent]'
  assert_success
  assert_output '[["unread",null],["unread",null],["lazer","aws"],403]'
  run "$AU" budget
  assert_success
  assert_output --partial 'partial, not counted: lazer, aws'
}

@test "a bill with no known price is unpriced, and a pool past its cap is over and ends the month at its spend" {
  sed -i 's/^codex  subscription 20 /codex  subscription ? /' "$BUDGET_LEDGER"
  lazer 228 50 1795132800 60
  run b '[(.lines[] | select(.name == "codex" or .name == "lazer") | [.status, .spent, .projected]), .partial]'
  assert_success
  assert_output '[["unpriced",null,null],["over",228,228],["codex"]]'
  run b '.lines[] | select(.name == "lazer") | .note'
  assert_output '"past its $50 cap; its budget window resets 2026-11-20, not on the 1st"'
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
  for v in 40 '?'; do
    sed -i '$d' "$BUDGET_LEDGER"; echo "x digitalocean $v" >> "$BUDGET_LEDGER"
    run "$AU" budget
    assert_failure
    assert_output --partial "a digitalocean bill's cap comes from its system"
  done
}

@test "a stale claude-acct textfile makes the pool unread, not a frozen number" {
  lazer 20 250 1796083200 7200
  run b '.lines[] | select(.name == "lazer") | [.status, .note]'
  assert_success
  assert_output "[\"unread\",\"claude-acct's textfile is 2.0h old (timer claude-acct-usage)\"]"
}

@test "the split puts each fee on its account's projects and lanes, metered cash on its ledger project, and sums to the total" {
  for d in 01 02 03 04 05 06 07 08 09 10; do
    echo '{"fleet_cost":{"by_account":{"claude":{"usd":10},"claude-bnb":{"usd":30}},"by_session":[
      {"usd":6,"account":"claude","project":"dotfiles","origin":"queue"},
      {"usd":4,"account":"claude","project":"_unscoped","origin":"hand"},
      {"usd":30,"account":"claude-bnb","project":"playground","origin":"runner"},
      {"usd":2,"harness":"codex","project":"trader","origin":"run"}]}}' > "$TOKENS_DIR/2026-11-$d.json"
  done
  echo '{"usageItems":[{"product":"actions","netAmount":30,"repositoryName":"engine"},{"product":"git_lfs","netAmount":3}]}' > "$FIX/gh-usage"
  run b '[.by_project, .by_lane, .total.spent]'
  assert_success
  # main 100: dotfiles 60, unattributed 40; bnb 200 + aws 100 + gh engine 30 -> playground; codex 20 -> trader; gh 3 + do 50 + lazer 20 -> unattributed
  assert_output '[[{"name":"playground","usd":330},{"name":"unattributed","usd":113},{"name":"dotfiles","usd":60},{"name":"trader","usd":20}],[{"name":"runner","usd":200},{"name":"ci","usd":100},{"name":"queue","usd":60},{"name":"digitalocean","usd":50},{"name":"hand","usd":40},{"name":"github","usd":33},{"name":"run","usd":20},{"name":"litellm","usd":20}],523]'
}

@test "a bill paid_by someone else is shown and left out of our total, the split and check" {
  sed -i 's/^lazer  litellm      -/lazer  litellm      -  paid_by=lazer/' "$BUDGET_LEDGER"
  lazer 228 50 1796083200 60
  run b '[(.lines[] | select(.name == "lazer") | [.status, .spent, .paid_by]), .total.spent, .total.caps, .others_pay, ([.by_project[].usd] | add)]'
  assert_success
  assert_output '[["over",228,"lazer"],503,1140,[{"name":"lazer","paid_by":"lazer","spent":228}],503]'
  "$AU" budget --json > "$BUDGET_JSON"
  run "$AU" budget check
  assert_success
  assert_output 'budget on pace'
  run "$AU" budget
  assert_output --partial 'lazer is paid by lazer: shown, not in our total'
}

@test "check trips on a product over pace, a forecast past its cap, a stale file and a reader unread for a day" {
  echo '{"usageItems":[{"product":"actions","netAmount":100}]}' > "$FIX/gh-usage"   # 220 * 1/3 + 15 = 88
  echo '[{"metric":{"kind":"actual"},"value":[0,"100"]},{"metric":{"kind":"limit"},"value":[0,"600"]},{"metric":{"kind":"forecast"},"value":[0,"650"]}]' > "$FIX/aws"
  "$AU" budget --json > "$BUDGET_JSON"
  run "$AU" budget check
  assert_failure
  assert_output 'gh actions $100 is ahead of pace: past $88 of its $220 cap on day 11
aws projects to $650 this month, past its $600 cap'
  BUDGET_NOW="2026-11-11T03:00:00-08:00" run "$AU" budget check
  assert_failure
  assert_output 'budget.json is 3.0h old (the fleet-bench budget step)'
  # the do reader fails: not a trip until it has failed for a day, its first failure carried from file to file
  : > "$FIX/do"; echo '{"usageItems":[]}' > "$FIX/gh-usage"; echo '[{"metric":{"kind":"actual"},"value":[0,"100"]}]' > "$FIX/aws"
  "$AU" budget --json > "$BUDGET_JSON.new" && mv "$BUDGET_JSON.new" "$BUDGET_JSON"
  run "$AU" budget check
  assert_success
  BUDGET_NOW="2026-11-12T01:00:00-08:00" "$AU" budget --json > "$BUDGET_JSON.new" && mv "$BUDGET_JSON.new" "$BUDGET_JSON"
  run jq -r '.lines[] | select(.name == "do") | .unread_since' "$BUDGET_JSON"
  assert_output '2026-11-11T00:00:00-08:00'
  BUDGET_NOW="2026-11-12T01:00:00-08:00" run "$AU" budget check
  assert_failure
  assert_output --partial 'do unread since 2026-11-11T00:00'
}

@test "check with no budget file says so and exits 1" {
  run "$AU" budget check
  assert_failure
  assert_output --partial "no readable $BUDGET_JSON"
}

@test "review fixes: a missing claude-acct age is unread, a dot repo joins its project, a bad ref is refused, an old file is a schema error" {
  printf '[{"metric":{"__name__":"claude_account_usd_used","account":"lazer"},"value":[0,"20"]}]' > "$FIX/lazer"
  run b '.lines[] | select(.name == "lazer") | .status'
  assert_output '"unread"'
  lazer 20 250 1796083200 60
  echo '{"usageItems":[{"product":"Actions","netAmount":30,"repositoryName":".dotfiles"}]}' > "$FIX/gh-usage"
  run b '[(.by_project[] | select(.name == "dotfiles") | .usd), (.lines[] | select(.name == "gh") | .products.actions.spent)]'
  assert_output '[30,30]'
  echo 'x digitalocean - ref=a"b' >> "$BUDGET_LEDGER"
  run "$AU" budget
  assert_failure
  assert_output --partial "letters, digits, _ . - only"
  sed -i '$d' "$BUDGET_LEDGER"
  echo '{"schema":1,"lines":[]}' > "$BUDGET_JSON"
  run "$AU" budget check
  assert_failure
  assert_output --partial "is not schema 2"
  run "$AU" budget check --json
  assert_failure
}
