# shellcheck shell=bash
# Sourced, never executed (SC2148).
#
# fleet-kubeconfig.sh - the kubeconfig this machine's fleet tools read home-k3s with. On a fleet worker
# it is the scoped account's (home-config's fleet-worker role writes it and points the lane units at it;
# its grants are apps/github-runner-exporter/fleet-read-rbac.yaml there), never an admin one; elsewhere
# it is kubectl's own (KUBECONFIG, else ~/.kube/config). agent-web-record and `fleet-node ready` read it.

FLEET_KUBECONFIG_SCOPED="${FLEET_KUBECONFIG_SCOPED:-$HOME/.config/schedules-sync/kubeconfig}"

# fleet_kubeconfig -> that path.
fleet_kubeconfig() {
  if [ -r "$FLEET_KUBECONFIG_SCOPED" ]; then echo "$FLEET_KUBECONFIG_SCOPED"
  else echo "${KUBECONFIG:-$HOME/.kube/config}"
  fi
}
