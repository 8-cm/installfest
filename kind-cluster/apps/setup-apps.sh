#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(realpath "$(dirname "$0")")"
CLUSTER_NAME="${CLUSTER_NAME:-a-cluster}"
KUBECONFIG_PATH="${SCRIPT_DIR}/../${CLUSTER_NAME}.kubeconfig"
KUBECTL="$(command -v kubectl)"
K="${KUBECTL} --kubeconfig ${KUBECONFIG_PATH}"

# ──────────────────────────────────────────────
# 1. ConfigMaps (nginx config + universal dashboard HTML + cluster identity)
# ──────────────────────────────────────────────
echo "==> Applying nginx ConfigMaps (universal dashboard — incoming/outgoing/combined)"
$K apply -f "${SCRIPT_DIR}/hello-nginx-cm.yaml"
$K apply -f "${SCRIPT_DIR}/traffic-dashboard-cm.yaml"

echo "==> Creating cluster-config ConfigMap in each namespace"
for ns in team-alpha team-beta team-gamma; do
  $K apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-config
  namespace: ${ns}
data:
  CLUSTER_DOMAIN: "${CLUSTER_NAME}"
EOF
done

# ──────────────────────────────────────────────
# 2. Hello apps (nginx + gen-cross sidecar — both send and receive)
# ──────────────────────────────────────────────
echo "==> Deploying hello apps"
export INGRESS_DOMAIN="${CLUSTER_NAME}"
envsubst '${INGRESS_DOMAIN}' < "${SCRIPT_DIR}/team-alpha.yaml" | $K apply -f -
envsubst '${INGRESS_DOMAIN}' < "${SCRIPT_DIR}/team-beta.yaml"  | $K apply -f -
envsubst '${INGRESS_DOMAIN}' < "${SCRIPT_DIR}/team-gamma.yaml" | $K apply -f -

# ──────────────────────────────────────────────
# 3. Blackhole services (chaos: selector matches no pods → Cilium RST)
# ──────────────────────────────────────────────
echo "==> Deploying blackhole services"
$K apply -f "${SCRIPT_DIR}/blackhole-svc.yaml"

# ──────────────────────────────────────────────
# 4. Traffic generators (legacy per-type, stdout only)
# ──────────────────────────────────────────────
echo "==> Deploying traffic generators"
envsubst '${INGRESS_DOMAIN}' < "${SCRIPT_DIR}/traffic-generators.yaml" | $K apply -f -

# ──────────────────────────────────────────────
# 5. Traffic monitor (dashboard + all generator types + chaos)
# ──────────────────────────────────────────────
echo "==> Deploying traffic-monitor pods"
envsubst '${INGRESS_DOMAIN}' < "${SCRIPT_DIR}/traffic-monitor.yaml" | $K apply -f -

# ──────────────────────────────────────────────
# 6. Wait for rollouts
# ──────────────────────────────────────────────
echo "==> Waiting for deployments..."
for ns in team-alpha team-beta team-gamma; do
  $K rollout status deployment/hello            -n "${ns}" --timeout=120s
  $K rollout status deployment/traffic-internal -n "${ns}" --timeout=120s
  $K rollout status deployment/traffic-cross    -n "${ns}" --timeout=120s
  $K rollout status deployment/traffic-external -n "${ns}" --timeout=120s
  $K rollout status deployment/traffic-monitor  -n "${ns}" --timeout=120s
done

# ──────────────────────────────────────────────
# 7. Resolve shard node IPs
# ──────────────────────────────────────────────
SHARD1_IP=$($K get node -l 'network-index=0' \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')
SHARD2_IP=$($K get node -l 'network-index=1' \
  -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')

# ──────────────────────────────────────────────
# 8. Summary
# ──────────────────────────────────────────────
echo ""
echo "==> Pods:"
for ns in team-alpha team-beta team-gamma; do
  $K get pods -n "${ns}" -o wide
  echo ""
done

echo "==> Ingresses:"
$K get ingress -A

echo ""
echo "==> Browser URLs (run ./port-forward.sh first):"
echo ""
echo "  Hello apps (← incoming + → outgoing + ⇄ combined):"
echo "    http://team-alpha.${CLUSTER_NAME}    shard-1 / ${SHARD1_IP}"
echo "    http://team-beta.${CLUSTER_NAME}     shard-2 / ${SHARD2_IP}"
echo "    http://team-gamma.${CLUSTER_NAME}    shard-2 / ${SHARD2_IP}"
echo ""
echo "  Traffic monitors (→ outgoing + chaos + ⇄ combined):"
echo "    http://traffic-alpha.${CLUSTER_NAME} shard-1 / ${SHARD1_IP}"
echo "    http://traffic-beta.${CLUSTER_NAME}  shard-2 / ${SHARD2_IP}"
echo "    http://traffic-gamma.${CLUSTER_NAME} shard-2 / ${SHARD2_IP}"
echo ""
echo "==> Watch raw logs:"
echo "  kubectl logs -n team-alpha deploy/hello           -c gen-cross  -f"
echo "  kubectl logs -n team-alpha deploy/traffic-monitor -c gen-chaos  -f"
echo "  kubectl logs -n team-alpha deploy/traffic-monitor -c gen-internal -f"
