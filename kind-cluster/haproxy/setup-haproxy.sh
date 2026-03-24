#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(realpath "$(dirname "$0")")"
CLUSTER_NAME="${CLUSTER_NAME:-a-cluster}"
KUBECONFIG_PATH="${SCRIPT_DIR}/../${CLUSTER_NAME}.kubeconfig"
KUBECTL="$(command -v kubectl)"
K="${KUBECTL} --kubeconfig ${KUBECONFIG_PATH}"

HAPROXY_VERSION="1.43.0"
SHARD1_VALUES="${SHARD1_VALUES:-${SCRIPT_DIR}/shard1-values.yaml}"
SHARD2_VALUES="${SHARD2_VALUES:-${SCRIPT_DIR}/shard2-values.yaml}"

# ──────────────────────────────────────────────
# 1. Helm repo
# ──────────────────────────────────────────────
echo "==> Adding HAProxy Helm repo"
helm repo add haproxytech https://haproxytech.github.io/helm-charts --force-update
helm repo update haproxytech

# ──────────────────────────────────────────────
# 2. Install shards
#    Each shard is a DaemonSet locked to one
#    network node. hostPorts 80/443 expose it
#    directly on the node's IP (no LB needed).
#    Namespace watching is set via values files
#    to avoid Helm's comma-separator conflict.
# ──────────────────────────────────────────────
echo ""
echo "==> Installing haproxy-shard-1 (network-00 / team-alpha)"
helm upgrade --install haproxy-shard-1 haproxytech/kubernetes-ingress \
  --kubeconfig "${KUBECONFIG_PATH}" \
  --version "${HAPROXY_VERSION}" \
  --namespace haproxy-system \
  --create-namespace \
  -f "${SHARD1_VALUES}"

echo ""
echo "==> Installing haproxy-shard-2 (network-01 / team-beta + team-gamma)"
helm upgrade --install haproxy-shard-2 haproxytech/kubernetes-ingress \
  --kubeconfig "${KUBECONFIG_PATH}" \
  --version "${HAPROXY_VERSION}" \
  --namespace haproxy-system \
  -f "${SHARD2_VALUES}"

# ──────────────────────────────────────────────
# 3. Wait for rollout
# ──────────────────────────────────────────────
echo ""
echo "==> Waiting for shard DaemonSets..."
$K rollout status daemonset/haproxy-shard-1-kubernetes-ingress -n haproxy-system --timeout=120s
$K rollout status daemonset/haproxy-shard-2-kubernetes-ingress -n haproxy-system --timeout=120s

# ──────────────────────────────────────────────
# 4. Summary
# ──────────────────────────────────────────────
echo ""
echo "==> HAProxy pods:"
$K get pods -n haproxy-system -o wide

echo ""
echo "==> IngressClasses:"
$K get ingressclass

echo ""
echo "Shard routing table:"
printf "  %-20s  %-30s  %s\n" "IngressClass" "Node" "Namespaces"
printf "  %-20s  %-30s  %s\n" "haproxy-shard-1" "worker5 (network)" "team-alpha"
printf "  %-20s  %-30s  %s\n" "haproxy-shard-2" "worker6 (network)" "team-beta, team-gamma"
echo ""
echo "Example Ingress usage:"
echo "  spec:"
echo "    ingressClassName: haproxy-shard-1   # routes to worker5"
echo "  or"
echo "    ingressClassName: haproxy-shard-2   # routes to worker6"
