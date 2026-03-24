#!/usr/bin/env bash
# Exposes both HAProxy shards on port 80 via loopback aliases,
# so the browser URL is http://team-alpha.example.com with no port.
#
# Usage:
#   ./port-forward.sh          # start port-forwards
#   ./port-forward.sh stop     # kill port-forwards and remove aliases
set -euo pipefail

SCRIPT_DIR="$(realpath "$(dirname "$0")")"
CLUSTER_NAME="${CLUSTER_NAME:-a-cluster}"
KUBECONFIG_PATH="${SCRIPT_DIR}/${CLUSTER_NAME}.kubeconfig"
KUBECTL="$(command -v kubectl)"
K="${KUBECTL} --kubeconfig ${KUBECONFIG_PATH}"

ALIAS_SHARD1="127.0.0.2"   # haproxy-shard-1 → team-alpha
ALIAS_SHARD2="127.0.0.3"   # haproxy-shard-2 → team-beta, team-gamma
HUBBLE_PORT="12000"         # Hubble UI
PID_FILE="/tmp/kind-port-forward.pids"

HOSTS_BLOCK="# kind-multi-cp-cluster
${ALIAS_SHARD1} team-alpha.example.com
${ALIAS_SHARD2} team-beta.example.com
${ALIAS_SHARD2} team-gamma.example.com
${ALIAS_SHARD1} traffic-alpha.example.com
${ALIAS_SHARD2} traffic-beta.example.com
${ALIAS_SHARD2} traffic-gamma.example.com
# end kind-multi-cp-cluster"

# ──────────────────────────────────────────────
stop() {
  echo "==> Stopping port-forwards"
  if [[ -f "${PID_FILE}" ]]; then
    while read -r pid; do
      sudo kill "${pid}" 2>/dev/null || true
    done < "${PID_FILE}"
    rm -f "${PID_FILE}"
  fi

  echo "==> Removing loopback aliases (requires sudo)"
  sudo ifconfig lo0 -alias "${ALIAS_SHARD1}" 2>/dev/null || true
  sudo ifconfig lo0 -alias "${ALIAS_SHARD2}" 2>/dev/null || true
  # Hubble UI uses 127.0.0.1 directly, no alias needed

  echo "==> Removing /etc/hosts entries (requires sudo)"
  sed '/# kind-multi-cp-cluster/,/# end kind-multi-cp-cluster/d' /etc/hosts > /tmp/hosts.tmp \
    && sudo cp /tmp/hosts.tmp /etc/hosts && rm /tmp/hosts.tmp

  echo "Done."
}

# ──────────────────────────────────────────────
start() {
  # Add loopback aliases so both shards can bind port 80 on distinct IPs
  echo "==> Adding loopback aliases (requires sudo)"
  sudo ifconfig lo0 alias "${ALIAS_SHARD1}" 255.255.255.0
  sudo ifconfig lo0 alias "${ALIAS_SHARD2}" 255.255.255.0

  # /etc/hosts
  echo "==> Updating /etc/hosts (requires sudo)"
  # Remove stale block if present, then append fresh one
  sed '/# kind-multi-cp-cluster/,/# end kind-multi-cp-cluster/d' /etc/hosts > /tmp/hosts.tmp \
    && sudo cp /tmp/hosts.tmp /etc/hosts && rm /tmp/hosts.tmp
  echo "${HOSTS_BLOCK}" | sudo tee -a /etc/hosts > /dev/null

  # Start port-forwards in background
  echo "==> Starting port-forwards"
  > "${PID_FILE}"

  sudo KUBECONFIG="${KUBECONFIG_PATH}" "${KUBECTL}" port-forward \
    svc/haproxy-shard-1-kubernetes-ingress \
    --address "${ALIAS_SHARD1}" \
    80:80 \
    -n haproxy-system &>/tmp/pf-shard1.log &
  echo $! >> "${PID_FILE}"

  sudo KUBECONFIG="${KUBECONFIG_PATH}" "${KUBECTL}" port-forward \
    svc/haproxy-shard-2-kubernetes-ingress \
    --address "${ALIAS_SHARD2}" \
    80:80 \
    -n haproxy-system &>/tmp/pf-shard2.log &
  echo $! >> "${PID_FILE}"

  KUBECONFIG="${KUBECONFIG_PATH}" "${KUBECTL}" port-forward \
    svc/hubble-ui \
    --address 127.0.0.1 \
    "${HUBBLE_PORT}":80 \
    -n kube-system &>/tmp/pf-hubble.log &
  echo $! >> "${PID_FILE}"

  sleep 2

  echo ""
  echo "==> Ready! Open in your browser:"
  echo ""
  echo "  http://team-alpha.example.com    → shard-1 / team-alpha hello app"
  echo "  http://team-beta.example.com     → shard-2 / team-beta hello app"
  echo "  http://team-gamma.example.com    → shard-2 / team-gamma hello app"
  echo ""
  echo "  http://traffic-alpha.example.com → shard-1 / team-alpha traffic monitor"
  echo "  http://traffic-beta.example.com  → shard-2 / team-beta traffic monitor"
  echo "  http://traffic-gamma.example.com → shard-2 / team-gamma traffic monitor"
  echo ""
  echo "  http://localhost:${HUBBLE_PORT}          → Hubble UI (network flows)"
  echo ""
  echo "  Run './port-forward.sh stop' to clean up."
}

# ──────────────────────────────────────────────
case "${1:-start}" in
  stop) stop ;;
  *)    start ;;
esac
