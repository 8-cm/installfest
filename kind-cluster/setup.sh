#!/usr/bin/env bash
# Set up a single Kind cluster with Cilium, HAProxy ingress, egress gateway,
# metrics-server, and demo application workloads.
#
# Human-friendly: Run once per cluster. It is fully idempotent — safe to re-run
# if interrupted. Skips cluster creation when the cluster already exists and
# only applies the metrics-server patch when the flag is not already present.
#
# Technical: Executes 9 sequential steps with set -euo pipefail (aborts on any
# error). Delegates egress policy setup to egress/setup-egress.sh, HAProxy
# installation to haproxy/setup-haproxy.sh, and app deployment to
# apps/setup-apps.sh. wget is installed on all nodes in parallel (background &)
# as it is required by kube-dump tooling used in observability exercises.
#
# Steps:
#   1. kind create cluster (idempotent — skipped if cluster already exists)
#   2. Export kubeconfig to CLUSTER_NAME.kubeconfig
#   3. Label + taint network nodes (worker5: network-index=0, worker6: network-index=1)
#   4. Install Cilium via Helm (kube-proxy replacement, egressGateway, bpf.masquerade, Hubble)
#   5. Wait for Cilium daemonset + operator rollout
#   6. Install wget on all nodes in parallel (for kube-dump)
#   7. Install metrics-server; patch --kubelet-insecure-tls if not already present
#   8. Apply egress namespaces + CiliumEgressGatewayPolicies (alpha, beta)
#   9. Install HAProxy sharded ingress (shard-1 on network-00, shard-2 on network-01)
#  10. Deploy demo apps (hello nginx, traffic-monitor, traffic generators, blackhole svc)
#
# Env vars (set by setup-dual-cluster.sh or passed manually):
#   CLUSTER_NAME    Kind cluster name                     [default: a-cluster]
#   CLUSTER_CONFIG  Path to Kind cluster YAML             [default: ./cluster.yaml]
#   SHARD1_VALUES   Path to Helm values for HAProxy shard-1
#   SHARD2_VALUES   Path to Helm values for HAProxy shard-2
#
# Args:
#   --zellij   After setup, open k9s in a new Zellij pane (right split)
#
# Returns: non-zero on any step failure (set -euo pipefail propagates immediately)
# Requires: kind, helm, kubectl, docker
set -euo pipefail

CLUSTER_CONFIG="${CLUSTER_CONFIG:-$(dirname "$0")/cluster.yaml}"
CLUSTER_NAME="${CLUSTER_NAME:-a-cluster}"
CILIUM_VERSION="1.16.5"
KUBECONFIG_PATH="$(realpath "$(dirname "$0")")/${CLUSTER_NAME}.kubeconfig"
# Use the real binary to bypass any kubectl/oc aliases
KUBECTL="$(command -v kubectl)"

ZELLIJ_PANE=false
for arg in "$@"; do
  [[ "$arg" == "--zellij" ]] && ZELLIJ_PANE=true
done

# ──────────────────────────────────────────────
# 1. Create Kind cluster
# ──────────────────────────────────────────────
if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_NAME}$"; then
  echo "==> ${CLUSTER_NAME} already exists — skipping cluster creation"
else
  echo "==> Creating Kind cluster: ${CLUSTER_NAME} (config: ${CLUSTER_CONFIG})"
  kind create cluster --config "${CLUSTER_CONFIG}"
fi

echo "==> Exporting kubeconfig to ${KUBECONFIG_PATH}"
kind get kubeconfig --name "${CLUSTER_NAME}" > "${KUBECONFIG_PATH}"
export KUBECONFIG="${KUBECONFIG_PATH}"

echo "==> Waiting for all nodes to register..."
"${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" wait --for=condition=Ready nodes --all --timeout=180s || true

# ──────────────────────────────────────────────
# 2. Label network nodes (Kind auto-names them worker5 / worker6)
# ──────────────────────────────────────────────
echo "==> Labelling and tainting network nodes"
# worker5 = shard-1 (network-index=0), worker6 = shard-2 (network-index=1)
"${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" label node "${CLUSTER_NAME}-worker5" \
  node-role=network kubernetes.io/role=network network-index=0 --overwrite
"${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" taint node "${CLUSTER_NAME}-worker5" \
  role=network:NoSchedule --overwrite

"${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" label node "${CLUSTER_NAME}-worker6" \
  node-role=network kubernetes.io/role=network network-index=1 --overwrite
"${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" taint node "${CLUSTER_NAME}-worker6" \
  role=network:NoSchedule --overwrite

# ──────────────────────────────────────────────
# 3. Install Cilium via Helm
# ──────────────────────────────────────────────
echo "==> Adding Cilium Helm repo"
helm repo add cilium https://helm.cilium.io/ --force-update
helm repo update

echo "==> Installing Cilium ${CILIUM_VERSION}"
helm upgrade --install cilium cilium/cilium \
  --kubeconfig "${KUBECONFIG_PATH}" \
  --version "${CILIUM_VERSION}" \
  --namespace kube-system \
  --set ipam.mode=kubernetes \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="${CLUSTER_NAME}-control-plane" \
  --set k8sServicePort=6443 \
  --set image.pullPolicy=IfNotPresent \
  --set operator.replicas=2 \
  --set egressGateway.enabled=true \
  --set bpf.masquerade=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true

# ──────────────────────────────────────────────
# 4. Wait for Cilium
# ──────────────────────────────────────────────
echo "==> Waiting for Cilium pods..."
"${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" rollout status daemonset/cilium -n kube-system --timeout=300s
"${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" rollout status deployment/cilium-operator -n kube-system --timeout=120s

# ──────────────────────────────────────────────
# 5. Install wget on all nodes (required by kube-dump)
# ──────────────────────────────────────────────
echo "==> Installing wget on all cluster nodes"
for node in $(kind get nodes --name "${CLUSTER_NAME}" | grep -v 'external-load-balancer'); do
  docker exec "$node" sh -c 'apt-get update -q 2>/dev/null && apt-get install -y wget -q' &
done
wait
echo "    wget installed on all nodes"

# ──────────────────────────────────────────────
# 6. PriorityClass for oc debug node
# ──────────────────────────────────────────────
echo "==> Creating openshift-user-critical PriorityClass (required by oc debug node)"
"${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" apply -f - <<'EOF'
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: openshift-user-critical
value: 1000000000
globalDefault: false
description: "Required by oc debug node on non-OpenShift clusters"
EOF

# ──────────────────────────────────────────────
# 7. Metrics Server (kubelet-insecure-tls needed for Kind self-signed certs)
# ──────────────────────────────────────────────
echo "==> Installing metrics-server"
"${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" apply \
  -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

if ! "${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" get deployment metrics-server \
    -n kube-system -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null \
    | grep -q 'kubelet-insecure-tls'; then
  echo "==> Patching metrics-server: disabling kubelet TLS verification (Kind)"
  "${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" patch deployment metrics-server \
    -n kube-system \
    --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
fi

"${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" rollout status deployment/metrics-server \
  -n kube-system --timeout=120s

# ──────────────────────────────────────────────
# 7. Egress namespaces + CiliumEgressGatewayPolicies
# ──────────────────────────────────────────────
echo ""
echo "==> Setting up egress namespaces and policies"
"$(dirname "$0")/egress/setup-egress.sh"

# ──────────────────────────────────────────────
# 8. HAProxy sharded ingress controllers
# ──────────────────────────────────────────────
echo ""
echo "==> Installing HAProxy sharded ingress"
"$(dirname "$0")/haproxy/setup-haproxy.sh"

# ──────────────────────────────────────────────
# 9. Demo apps (hello-kubernetes in each namespace)
# ──────────────────────────────────────────────
echo ""
echo "==> Deploying demo apps"
"$(dirname "$0")/apps/setup-apps.sh"

# ──────────────────────────────────────────────
# 8. Summary
# ──────────────────────────────────────────────
echo ""
echo "==> Cluster ready. Node overview:"
"${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" get nodes -o wide

echo ""
echo "==> Cilium pods:"
"${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" get pods -n kube-system -l k8s-app=cilium -o wide

echo ""
echo "==> HAProxy shards:"
"${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" get pods -n haproxy-system -o wide

echo ""
echo "==> EgressGateway policies:"
"${KUBECTL}" --kubeconfig "${KUBECONFIG_PATH}" get ciliumegressgatewaypolicies

echo ""
echo "==> KUBECONFIG exported to: ${KUBECONFIG_PATH}"

# ──────────────────────────────────────────────
# 8. Optional: open k9s in a new Zellij pane
# ──────────────────────────────────────────────
if [[ "${ZELLIJ_PANE}" == "true" ]]; then
  if ! command -v zellij &>/dev/null; then
    echo "==> [--zellij] zellij not found, skipping pane"
  elif ! command -v k9s &>/dev/null; then
    echo "==> [--zellij] k9s not found, skipping pane"
  else
    echo "==> Opening k9s in a new Zellij pane (right)"
    zellij action new-pane --direction right -- \
      bash -c "KUBECONFIG=${KUBECONFIG_PATH} k9s --context kind-${CLUSTER_NAME}"
  fi
fi
