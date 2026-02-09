#!/bin/bash
# Collect status for Kubernetes deployments/pods
# Usage: k8s.sh <namespace> <resource>
# Example: k8s.sh default deployment/nginx
# Output: JSON with status, ready replicas, age, restarts

set -euo pipefail

NAMESPACE="${1:-default}"
RESOURCE="$2"
K8S_CONTEXT="${K8S_CONTEXT:-}"

# Build kubectl command with optional context
KUBECTL="kubectl"
if [ -n "$K8S_CONTEXT" ]; then
    KUBECTL="kubectl --context $K8S_CONTEXT"
fi

# Check if kubectl is available
if ! command -v kubectl &>/dev/null; then
    echo '{"status":"unknown","error":"kubectl not found"}'
    exit 0
fi

# Check if cluster is reachable (with timeout)
if ! $KUBECTL cluster-info --request-timeout=5s &>/dev/null; then
    echo '{"status":"unknown","error":"cluster unreachable"}'
    exit 0
fi

# Get resource type and name
RESOURCE_TYPE=$(echo "$RESOURCE" | cut -d/ -f1)
RESOURCE_NAME=$(echo "$RESOURCE" | cut -d/ -f2)

get_deployment_status() {
    local ns="$1"
    local name="$2"

    local json
    json=$($KUBECTL get deployment "$name" -n "$ns" -o json 2>/dev/null)

    if [ -z "$json" ]; then
        echo '{"status":"unknown","error":"deployment not found"}'
        return
    fi

    local replicas=$(echo "$json" | jq -r '.spec.replicas // 0')
    local ready=$(echo "$json" | jq -r '.status.readyReplicas // 0')
    local available=$(echo "$json" | jq -r '.status.availableReplicas // 0')
    local updated=$(echo "$json" | jq -r '.status.updatedReplicas // 0')
    local created=$(echo "$json" | jq -r '.metadata.creationTimestamp')

    # Calculate age
    local created_ts=$(date -d "$created" +%s 2>/dev/null || echo 0)
    local now=$(date +%s)
    local age_days=$(( (now - created_ts) / 86400 ))
    local age="${age_days}d"

    # Determine status
    local status="up"
    if [ "$ready" -eq 0 ]; then
        status="down"
    elif [ "$ready" -lt "$replicas" ]; then
        status="warning"
    fi

    # Get pod restarts (sum of all container restarts)
    local restarts=0
    local pod_restarts
    pod_restarts=$($KUBECTL get pods -n "$ns" -l "app=$name" -o json 2>/dev/null | \
        jq '[.items[].status.containerStatuses[]?.restartCount // 0] | add // 0')
    restarts=${pod_restarts:-0}

    cat <<EOF
{
  "status": "$status",
  "details": {
    "ready": "${ready}/${replicas}",
    "available": $available,
    "updated": $updated,
    "age": "$age",
    "restarts": $restarts
  }
}
EOF
}

get_statefulset_status() {
    local ns="$1"
    local name="$2"

    local json
    json=$($KUBECTL get statefulset "$name" -n "$ns" -o json 2>/dev/null)

    if [ -z "$json" ]; then
        echo '{"status":"unknown","error":"statefulset not found"}'
        return
    fi

    local replicas=$(echo "$json" | jq -r '.spec.replicas // 0')
    local ready=$(echo "$json" | jq -r '.status.readyReplicas // 0')
    local created=$(echo "$json" | jq -r '.metadata.creationTimestamp')

    local created_ts=$(date -d "$created" +%s 2>/dev/null || echo 0)
    local now=$(date +%s)
    local age_days=$(( (now - created_ts) / 86400 ))
    local age="${age_days}d"

    local status="up"
    if [ "$ready" -eq 0 ]; then
        status="down"
    elif [ "$ready" -lt "$replicas" ]; then
        status="warning"
    fi

    cat <<EOF
{
  "status": "$status",
  "details": {
    "ready": "${ready}/${replicas}",
    "age": "$age"
  }
}
EOF
}

get_pod_status() {
    local ns="$1"
    local name="$2"

    local json
    json=$($KUBECTL get pod "$name" -n "$ns" -o json 2>/dev/null)

    if [ -z "$json" ]; then
        echo '{"status":"unknown","error":"pod not found"}'
        return
    fi

    local phase=$(echo "$json" | jq -r '.status.phase')
    local restarts=$(echo "$json" | jq '[.status.containerStatuses[]?.restartCount // 0] | add // 0')

    local status="up"
    case "$phase" in
        Running) status="up" ;;
        Pending) status="warning" ;;
        *) status="down" ;;
    esac

    cat <<EOF
{
  "status": "$status",
  "details": {
    "phase": "$phase",
    "restarts": $restarts
  }
}
EOF
}

get_service_status() {
    local ns="$1"
    local name="$2"

    local json
    json=$($KUBECTL get service "$name" -n "$ns" -o json 2>/dev/null)

    if [ -z "$json" ]; then
        echo '{"status":"unknown","error":"service not found"}'
        return
    fi

    local svc_type=$(echo "$json" | jq -r '.spec.type')
    local cluster_ip=$(echo "$json" | jq -r '.spec.clusterIP')

    # Service exists = up
    cat <<EOF
{
  "status": "up",
  "details": {
    "type": "$svc_type",
    "cluster_ip": "$cluster_ip"
  }
}
EOF
}

# Dispatch based on resource type
case "$RESOURCE_TYPE" in
    deployment|deploy)
        get_deployment_status "$NAMESPACE" "$RESOURCE_NAME"
        ;;
    statefulset|sts)
        get_statefulset_status "$NAMESPACE" "$RESOURCE_NAME"
        ;;
    pod|po)
        get_pod_status "$NAMESPACE" "$RESOURCE_NAME"
        ;;
    service|svc)
        get_service_status "$NAMESPACE" "$RESOURCE_NAME"
        ;;
    *)
        echo "{\"status\":\"unknown\",\"error\":\"unsupported resource type: $RESOURCE_TYPE\"}"
        ;;
esac
