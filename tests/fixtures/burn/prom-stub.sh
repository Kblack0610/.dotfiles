# Prometheus for the burn fixture: s1 billed $4 and h1 $1 in the window, nothing before it, no fits,
# no gateway. Tests point PROM_LIB here.
prom_q() {
  local r='[]'
  case "$1" in
    *offset*) ;;
    *agentctl_runner*) r='[{"metric":{"session_id":"s1","model":"claude-opus-5-5"},"value":[0,"4"]},{"metric":{"session_id":"h1","model":"claude-opus-5-5"},"value":[0,"1"]}]' ;;
  esac
  printf '{"status":"success","data":{"result":%s}}' "$r"
}
