#!/usr/bin/env bash
# Sets up two Kind clusters (a-cluster + b-cluster) and wires them together
# so pods in each cluster send traffic to the other cluster's ingress.
#
# Usage:
#   ./setup-dual-cluster.sh          # full fresh setup
#   ./setup-dual-cluster.sh wire     # only re-wire peer IPs (both clusters already running)
set -euo pipefail

SCRIPT_DIR="$(realpath "$(dirname "$0")")"
CLUSTER_A="a-cluster"
CLUSTER_B="b-cluster"
KC_A="${SCRIPT_DIR}/${CLUSTER_A}.kubeconfig"
KC_B="${SCRIPT_DIR}/${CLUSTER_B}.kubeconfig"
KUBECTL="$(command -v kubectl)"
KA="${KUBECTL} --kubeconfig ${KC_A}"
KB="${KUBECTL} --kubeconfig ${KC_B}"

# ──────────────────────────────────────────────
# helpers
# ──────────────────────────────────────────────
node_docker_ip() {
  docker inspect "$1" \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null
}

apply_peer_cm() {
  local KC="$1" SHARD1="$2" SHARD2="$3"
  for ns in team-alpha team-beta team-gamma; do
    "${KUBECTL}" --kubeconfig "${KC}" apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: peer-ingress
  namespace: ${ns}
data:
  PEER_SHARD1: "${SHARD1}"
  PEER_SHARD2: "${SHARD2}"
EOF
  done
}

# ──────────────────────────────────────────────
# 1. Set up a-cluster (skip if running)
# ──────────────────────────────────────────────
setup_or_skip() {
  local name="$1" config="$2" s1val="$3" s2val="$4"
  if kind get clusters 2>/dev/null | grep -q "^${name}$"; then
    echo "==> ${name} already exists — skipping cluster setup"
  else
    echo "==> Setting up ${name}"
    CLUSTER_NAME="${name}" \
    CLUSTER_CONFIG="${config}" \
    SHARD1_VALUES="${s1val}" \
    SHARD2_VALUES="${s2val}" \
      "${SCRIPT_DIR}/setup.sh"
  fi
}

if [[ "${1:-full}" != "wire" ]]; then
  setup_or_skip "${CLUSTER_A}" \
    "${SCRIPT_DIR}/cluster.yaml" \
    "${SCRIPT_DIR}/haproxy/shard1-values.yaml" \
    "${SCRIPT_DIR}/haproxy/shard2-values.yaml"

  setup_or_skip "${CLUSTER_B}" \
    "${SCRIPT_DIR}/cluster-b.yaml" \
    "${SCRIPT_DIR}/haproxy/shard1-values-b.yaml" \
    "${SCRIPT_DIR}/haproxy/shard2-values-b.yaml"
fi

# ──────────────────────────────────────────────
# 2. Resolve Docker IPs of network nodes (hostPort 80 = ingress entry)
# ──────────────────────────────────────────────
echo "==> Resolving peer ingress endpoints via Docker bridge IPs"

A_N0=$(node_docker_ip "${CLUSTER_A}-network-00")
A_N1=$(node_docker_ip "${CLUSTER_A}-network-01")
B_N0=$(node_docker_ip "${CLUSTER_B}-network-00")
B_N1=$(node_docker_ip "${CLUSTER_B}-network-01")

echo "  a-cluster  shard-1 (network-00): ${A_N0}:80"
echo "  a-cluster  shard-2 (network-01): ${A_N1}:80"
echo "  b-cluster  shard-1 (network-00): ${B_N0}:80"
echo "  b-cluster  shard-2 (network-01): ${B_N1}:80"

# ──────────────────────────────────────────────
# 3. Create peer-ingress ConfigMaps
#    a-cluster pods → b-cluster IPs
#    b-cluster pods → a-cluster IPs
# ──────────────────────────────────────────────
echo "==> Creating peer-ingress ConfigMaps"
apply_peer_cm "${KC_A}" "${B_N0}" "${B_N1}"
apply_peer_cm "${KC_B}" "${A_N0}" "${A_N1}"

# ──────────────────────────────────────────────
# 4. Restart hello deployments to pick up peer-ingress env vars
# ──────────────────────────────────────────────
echo "==> Restarting hello deployments"
for ns in team-alpha team-beta team-gamma; do
  $KA rollout restart deployment/hello -n "${ns}"
  $KB rollout restart deployment/hello -n "${ns}"
done

echo "==> Waiting for rollouts"
for ns in team-alpha team-beta team-gamma; do
  $KA rollout status deployment/hello -n "${ns}" --timeout=120s
  $KB rollout status deployment/hello -n "${ns}" --timeout=120s
done

# ──────────────────────────────────────────────
# 5. Summary
# ──────────────────────────────────────────────
echo ""
echo "==> Dual cluster setup complete!"
echo ""
echo "  Kubeconfigs:"
echo "    ${KC_A}"
echo "    ${KC_B}"
echo ""
echo "  Cross-cluster traffic paths:"
echo "    a-cluster pods  →  b-cluster shard-1 ${B_N0}:80  (team-alpha.example.com)"
echo "    a-cluster pods  →  b-cluster shard-2 ${B_N1}:80  (team-beta/gamma.example.com)"
echo "    b-cluster pods  →  a-cluster shard-1 ${A_N0}:80  (team-alpha.example.com)"
echo "    b-cluster pods  →  a-cluster shard-2 ${A_N1}:80  (team-beta/gamma.example.com)"
echo ""
echo "  Port-forward a-cluster:  CLUSTER_NAME=a-cluster ./port-forward.sh"
echo "  Port-forward b-cluster:  CLUSTER_NAME=b-cluster ./port-forward.sh"
echo ""
echo "  To re-wire peer IPs only (e.g. after cluster restart):"
echo "    ./setup-dual-cluster.sh wire"
