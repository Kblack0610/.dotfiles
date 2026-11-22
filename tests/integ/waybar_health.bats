#!/usr/bin/env bats
# health.sh: the waybar health chip, every system at a glance. The bar is a pulse in the overall
# colour and one dot per system, worst first; the hover is one row per system with what is down or
# warning on it. What these pin: rows and levels come only from the cc:* rules, so a domain the
# script has never heard of still shows; a watch names the reason, and a failing component names
# it when no watch does; the head's counts are hub-core's published Infra figures, never a count of
# the rows; Prometheus down or empty reads ?, never a blank or a green chip.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MODULE="$REPO_ROOT/.config/waybar/health.sh"
  ICON=$'\uf21e' DOT=$'\u25cf' # nf-fa-heartbeat and a filled circle, as escapes so no editor can strip them
  G="#a6e34a" Y="#ffcc2f" R="#ef5734"
  export CC_PROM_URL=http://prom.test FX="$BATS_TEST_TMPDIR"
  cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ -n "${CURL_FAIL:-}" ] && exit 7
cat "$FX/prom.json"
STUB
  chmod +x "$SANDBOX/bin/curl"
}

# feed [d:<domain>=<level>] [w:<domain>:<item>=<level>] [c:<domain>:<component>=<level>] [o=<level>]
#      [f:<down|warn|up>[:<host>]=<n>]: f is an Infra card figure on a host's summary/cards topic.
feed() {
  python3 - "$FX/prom.json" "$@" <<'PY'
import json, sys
rows = []
for a in sys.argv[2:]:
    k, v = a.split("=")
    p = k.split(":")
    m = {"o": {"__name__": "cc:overall_status"}}.get(p[0]) or {
        "d": lambda: {"__name__": "cc:domain_status", "domain": p[1]},
        "w": lambda: {"__name__": "cc:watch_state", "domain": p[1], "item": p[2]},
        "c": lambda: {"__name__": "cc:component_status", "domain": p[1], "component": p[2]},
        "f": lambda: {"__name__": "mqtt_figures_infra_domains_" + p[1],
                      "topic": "agents_%s_summary_cards" % (p[2] if len(p) > 2 else "ws")},
    }[p[0]]()
    rows.append({"metric": m, "value": [0, v]})
json.dump({"status": "success", "data": {"resultType": "vector", "result": rows}}, open(sys.argv[1], "w"))
PY
}

text() { jq -r .text <<< "$output"; }
tip() { jq -r .tooltip <<< "$output"; }
class() { jq -r .class <<< "$output"; }
dot() { printf "<span color='%s'>%s</span>" "$1" "$DOT"; }
pulse() { printf "<span color='%s'>%s</span>" "$1" "$ICON"; }

@test "all up: a green heart alone on the bar, a green dot per system on the hover" {
  feed o=0 d:k3s=0 d:prod=0 c:k3s:nodes=0 f:down=0 f:warn=0 f:up=2
  run "$MODULE"
  assert_equal "$(text)" "$(pulse "$G")"
  assert_equal "$(class)" ok
  run bash -c 'jq -r .tooltip <<< "$1"' _ "$output"
  assert_line --index 0 "<b>System</b>  $(dot "$G")$(dot "$G")  2 up"
  assert_line --index 1 "<tt>k3s   <span color='$G'>up</span>"
  assert_line --index 2 "prod  <span color='$G'>up</span></tt>"
}

@test "worst systems lead, each names its watches worst first, and the head prints the published counts" {
  feed o=2 d:agents=0 d:spend=1 d:ci=2 d:queue=1 f:down=1 f:warn=2 f:up=1 \
    w:ci:playground_nightly=2 w:spend:claude_spend_daily=1 w:spend:claude_account_pace=1 w:queue:heal_flapping=1
  run "$MODULE"
  assert_equal "$(text)" "$(pulse "$R")"
  assert_equal "$(class)" critical
  run bash -c 'jq -r .tooltip <<< "$1"' _ "$output"
  assert_line --index 0 "<b>System</b>  $(dot "$R")$(dot "$Y")$(dot "$Y")$(dot "$G")  1 down, 2 warn, 1 up"
  assert_line --index 1 "<tt>ci      <span color='$R'>DOWN</span>  playground nightly"
  assert_line --index 2 "queue   <span color='$Y'>warn</span>  heal flapping"
  assert_line --index 3 "spend   <span color='$Y'>warn</span>  claude account pace, claude spend daily"
  assert_line --index 4 "agents  <span color='$G'>up</span></tt>"
}

# Negative control for a chip that recounts: the head is the figures as sent, so figures that
# differ from the rows on screen (a snapshot a minute older) print as sent, not as the rows count.
@test "the head prints hub-core's figures, never a count of the rows" {
  feed o=1 d:k3s=0 d:prod=1 f:down=0 f:warn=3 f:up=9
  run "$MODULE"
  run bash -c 'jq -r .tooltip <<< "$1"' _ "$output"
  assert_line --index 0 "<b>System</b>  $(dot "$Y")$(dot "$G")  3 warn, 9 up"
}

@test "with no published figures the head says so in amber and the rows still show" {
  feed o=1 d:k3s=0 d:prod=1 f:down=0 f:up=1
  run "$MODULE"
  assert_equal "$(class)" warn
  run bash -c 'jq -r .tooltip <<< "$1"' _ "$output"
  assert_line --index 0 "<b>System</b>  $(dot "$Y")$(dot "$G")  <span color='$Y'>no published counts (summary/cards)</span>"
  assert_line --index 1 "<tt>prod  <span color='$Y'>warn</span>"
}

@test "two live summary/cards topics during a lease move: agreeing figures print, differing ones say so in amber" {
  feed o=2 d:ci=2 f:down=1 f:warn=0 f:up=0 f:down:old=1 f:warn:old=0 f:up:old=0
  run "$MODULE"
  run bash -c 'jq -r .tooltip <<< "$1"' _ "$output"
  assert_line --index 0 "<b>System</b>  $(dot "$R")  1 down"
  feed o=2 d:ci=2 f:down=1 f:warn=0 f:up=0 f:down:old=0 f:warn:old=0 f:up:old=4
  run "$MODULE"
  run bash -c 'jq -r .tooltip <<< "$1"' _ "$output"
  assert_line --index 0 "<b>System</b>  $(dot "$R")  <span color='$Y'>two machines publish different counts (summary/cards)</span>"
}

@test "a system no watch explains names its failing components" {
  feed o=1 d:agents=1 c:agents:feed=1 c:agents:sentinel=0
  run "$MODULE"
  run bash -c 'jq -r .tooltip <<< "$1"' _ "$output"
  assert_output --partial "<span color='$Y'>warn</span>  feed"
  refute_output --partial sentinel
}

@test "a watch answers for its system, so a component row does not repeat it" {
  feed o=2 d:home=2 w:home:voice_bedroom_puck=2 c:home:connectivity=2
  run "$MODULE"
  run bash -c 'jq -r .tooltip <<< "$1"' _ "$output"
  assert_output --partial "<span color='$R'>DOWN</span>  voice bedroom puck"
  refute_output --partial connectivity
}

@test "a system the script has never heard of still shows, and its name is escaped" {
  feed o=1 'd:a<b=1'
  run "$MODULE"
  run bash -c 'jq -r .tooltip <<< "$1"' _ "$output"
  assert_output --partial "<tt>a&lt;b  <span color='$Y'>warn</span>"
}

@test "Prometheus unreadable reads ? in amber, never blank" {
  feed o=0 d:k3s=0
  CURL_FAIL=1 run "$MODULE"
  assert_equal "$(text)" "<span color='$Y'>$ICON ?</span>"
  assert_equal "$(class)" warn
  assert_equal "$(tip)" $'<b>System</b>\ncannot read http://prom.test'
}

# Negative control: an answer with no rows is the rules gone, not a healthy system.
@test "no rows from Prometheus reads ?, not green" {
  feed
  run "$MODULE"
  assert_equal "$(text)" "<span color='$Y'>$ICON ?</span>"
  assert_equal "$(class)" warn
}
