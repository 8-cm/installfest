#!/usr/bin/env bash
# Sets up two Kind clusters (a-cluster + b-cluster), wires them together for
# cross-cluster traffic, and optionally opens k9s panes and launches radar.
set -euo pipefail

SCRIPT_DIR="$(realpath "$(dirname "$0")")"
CLUSTER_A="a-cluster"
CLUSTER_B="b-cluster"
KC_A="${SCRIPT_DIR}/${CLUSTER_A}.kubeconfig"
KC_B="${SCRIPT_DIR}/${CLUSTER_B}.kubeconfig"
KUBECTL="$(command -v kubectl)"

# ──────────────────────────────────────────────────────
# Usage / help
# ──────────────────────────────────────────────────────
usage() {
  cat <<EOF

Usage: $(basename "$0") [OPTIONS] [wire]

Sets up Kind clusters with Cilium, HAProxy shards, demo apps, and cross-cluster
peer traffic (pods in each cluster target the other cluster's ingress via the
Docker bridge — visible as egress-gateway SNAT in Hubble/Wireshark).

Subcommand:
  wire           Re-wire peer IPs only (both clusters must already be running).
                 Run this after a node restart to refresh Docker bridge IPs.

Options (all optional):
  --create=<a|b|ab>   Cluster(s) to create             [default: ab]
  --delete=<a|b|ab>   Delete cluster(s) and exit
  --zellij            Open k9s (and radar if --radar) in dedicated Zellij tabs
                      Each tool gets its own tab; clusters split right within the tab
  --tmux              Open k9s (and radar if --radar) in tmux split panes
  --radar             Launch radar TUI for each created cluster
                      With --zellij: dedicated "radar" tab; --tmux: split; else background
  -h, --help          Show this help and exit

Examples:
  $(basename "$0")                            # create both clusters (default)
  $(basename "$0") --create=a                 # create only a-cluster
  $(basename "$0") --create=ab --zellij       # both clusters + k9s in Zellij
  $(basename "$0") --create=b --tmux --radar  # b-cluster + k9s in tmux + radar
  $(basename "$0") --delete=ab               # delete both clusters
  $(basename "$0") wire                       # re-wire peer IPs (no cluster creation)

After setup, port-forwards are started automatically. Use port-forward.sh to manage:
  $(basename "$(dirname "$0")")/port-forward.sh stop
  CLUSTER_NAME=b-cluster $(basename "$(dirname "$0")")/port-forward.sh

EOF
}

# ──────────────────────────────────────────────────────
# Arg parsing
# ──────────────────────────────────────────────────────
CREATE=""
DELETE=""
USE_ZELLIJ=false
USE_TMUX=false
USE_RADAR=false
WIRE_ONLY=false

for arg in "$@"; do
  case "$arg" in
    -h|--help)   usage; exit 0 ;;
    --create=*)  CREATE="${arg#--create=}" ;;
    --delete=*)  DELETE="${arg#--delete=}" ;;
    --zellij)    USE_ZELLIJ=true ;;
    --tmux)      USE_TMUX=true ;;
    --radar)     USE_RADAR=true ;;
    wire)        WIRE_ONLY=true ;;
    *)           echo "Unknown argument: $arg" >&2; usage; exit 1 ;;
  esac
done

# Default to ab if no create/delete/wire specified
[[ -z "$CREATE" && -z "$DELETE" && "$WIRE_ONLY" == false ]] && CREATE="ab"

# Name the current tab so we can return to it after opening tool tabs.
$USE_ZELLIJ && zellij action rename-tab "setup" 2>/dev/null || true

CREATE_A=false; CREATE_B=false
[[ "$CREATE" == *a* ]] && CREATE_A=true
[[ "$CREATE" == *b* ]] && CREATE_B=true

# ──────────────────────────────────────────────────────
# Delete
# ──────────────────────────────────────────────────────
if [[ -n "$DELETE" ]]; then
  echo "==> Deleting clusters: ${DELETE}"
  if [[ "$DELETE" == *a* ]]; then
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_A}$"; then
      kind delete cluster --name "${CLUSTER_A}"
      echo "    deleted ${CLUSTER_A}"
    else
      echo "    ${CLUSTER_A} not found, skipping"
    fi
  fi
  if [[ "$DELETE" == *b* ]]; then
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER_B}$"; then
      kind delete cluster --name "${CLUSTER_B}"
      echo "    deleted ${CLUSTER_B}"
    else
      echo "    ${CLUSTER_B} not found, skipping"
    fi
  fi
  exit 0
fi

# ──────────────────────────────────────────────────────
# Helpers
# ──────────────────────────────────────────────────────
node_docker_ip() {
  docker inspect "$1" \
    --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' 2>/dev/null
}

run_setup() {
  local name="$1" config="$2" s1val="$3" s2val="$4"
  if kind get clusters 2>/dev/null | grep -q "^${name}$"; then
    echo "==> ${name} already running — skipping cluster creation"
  else
    echo "==> Setting up ${name}"
    CLUSTER_NAME="${name}" \
    CLUSTER_CONFIG="${config}" \
    SHARD1_VALUES="${s1val}" \
    SHARD2_VALUES="${s2val}" \
      "${SCRIPT_DIR}/setup.sh"
  fi
}

apply_peer_cm() {
  local KC="$1" SHARD1="$2" SHARD2="$3" PEER_DOMAIN="$4"
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
  PEER_DOMAIN: "${PEER_DOMAIN}"
EOF
  done
}

# Opens a named zellij tab and runs each command in a pane.
# The first command runs in the tab's default shell pane; subsequent ones split right.
open_zellij_tab() {
  local tab_name="$1"; shift
  local first=true
  zellij action new-tab --name "${tab_name}"
  sleep 0.5
  for cmd in "$@"; do
    if $first; then
      zellij action write-chars "${cmd}"$'\n'
      first=false
    else
      zellij action new-pane --direction right
      sleep 0.5
      zellij action write-chars "${cmd}"$'\n'
    fi
  done
}

open_k9s() {
  local kc="$1" name="$2" direction="${3:-right}"
  if ! command -v k9s &>/dev/null; then
    echo "  [skip] k9s not found in PATH"
    return
  fi
  if pgrep -qf "k9s.*--context kind-${name}" 2>/dev/null; then
    echo "  [skip] k9s for ${name} already running"
    return
  fi
  echo "==> Opening k9s for ${name}"
  if [[ "${direction}" == "right" ]]; then
    tmux split-window -h "KUBECONFIG=${kc} k9s --context kind-${name}"
  else
    tmux split-window -v "KUBECONFIG=${kc} k9s --context kind-${name}"
  fi
}

open_radar() {
  local kc="$1" name="$2" port="${3:-9280}"
  if ! command -v radar &>/dev/null; then
    echo "  [skip] radar not found in PATH"
    return
  fi
  if pgrep -qf "radar.*${name}" 2>/dev/null; then
    echo "  [skip] radar for ${name} already running"
    return
  fi
  echo "==> Opening radar for ${name} (port ${port})"
  local radar_cmd="radar -kubeconfig ${kc} -port ${port}"
  if $USE_TMUX; then
    tmux split-window -h "${radar_cmd}"
  else
    local pid_file="/tmp/kind-radar-${name}.pid"
    if [[ -f "${pid_file}" ]] && kill -0 "$(cat "${pid_file}")" 2>/dev/null; then
      echo "  [skip] radar for ${name} already running (PID $(cat "${pid_file}"))"
      return
    fi
    ${radar_cmd} &
    echo $! > "${pid_file}"
    echo "    radar launched in background (PID $!)"
  fi
}

wire_peers() {
  echo "==> Resolving peer ingress endpoints (Docker bridge IPs — hostPort 80)"
  local A_N0 A_N1 B_N0 B_N1
  # Kind auto-names network nodes as worker5 (shard-1) and worker6 (shard-2)
  A_N0=$(node_docker_ip "${CLUSTER_A}-worker5")
  A_N1=$(node_docker_ip "${CLUSTER_A}-worker6")
  B_N0=$(node_docker_ip "${CLUSTER_B}-worker5")
  B_N1=$(node_docker_ip "${CLUSTER_B}-worker6")

  printf '  %-40s  %s\n' "a-cluster shard-1 (worker5/network-00)" "${A_N0}:80"
  printf '  %-40s  %s\n' "a-cluster shard-2 (worker6/network-01)" "${A_N1}:80"
  printf '  %-40s  %s\n' "b-cluster shard-1 (worker5/network-00)" "${B_N0}:80"
  printf '  %-40s  %s\n' "b-cluster shard-2 (worker6/network-01)" "${B_N1}:80"

  echo "==> Creating peer-ingress ConfigMaps"
  # a-cluster pods → b-cluster IPs + domain; b-cluster pods → a-cluster IPs + domain
  apply_peer_cm "${KC_A}" "${B_N0}" "${B_N1}" "${CLUSTER_B}"
  apply_peer_cm "${KC_B}" "${A_N0}" "${A_N1}" "${CLUSTER_A}"

  echo "==> Restarting hello + traffic deployments to pick up peer-ingress"
  for ns in team-alpha team-beta team-gamma; do
    "${KUBECTL}" --kubeconfig "${KC_A}" rollout restart \
      deployment/hello deployment/traffic-external -n "${ns}" 2>/dev/null || true
    "${KUBECTL}" --kubeconfig "${KC_B}" rollout restart \
      deployment/hello deployment/traffic-external -n "${ns}" 2>/dev/null || true
  done

  echo "==> Waiting for rollouts"
  for ns in team-alpha team-beta team-gamma; do
    "${KUBECTL}" --kubeconfig "${KC_A}" rollout status deployment/hello -n "${ns}" --timeout=120s
    "${KUBECTL}" --kubeconfig "${KC_B}" rollout status deployment/hello -n "${ns}" --timeout=120s
  done
}

# ──────────────────────────────────────────────────────
# Wire-only mode
# ──────────────────────────────────────────────────────
if $WIRE_ONLY; then
  wire_peers
  echo "==> Done."
  exit 0
fi

# ──────────────────────────────────────────────────────
# 1. Cluster setup
# ──────────────────────────────────────────────────────
$CREATE_A && run_setup "${CLUSTER_A}" \
  "${SCRIPT_DIR}/cluster.yaml" \
  "${SCRIPT_DIR}/haproxy/shard1-values.yaml" \
  "${SCRIPT_DIR}/haproxy/shard2-values.yaml"

$CREATE_B && run_setup "${CLUSTER_B}" \
  "${SCRIPT_DIR}/cluster-b.yaml" \
  "${SCRIPT_DIR}/haproxy/shard1-values-b.yaml" \
  "${SCRIPT_DIR}/haproxy/shard2-values-b.yaml"

# ──────────────────────────────────────────────────────
# 2. Peer wiring (only when both clusters exist)
# ──────────────────────────────────────────────────────
if $CREATE_A && $CREATE_B; then
  wire_peers
fi

# ──────────────────────────────────────────────────────
# 3. Radar  (zellij: dedicated tab with one pane per cluster)
# ──────────────────────────────────────────────────────
if $USE_RADAR; then
  if $USE_ZELLIJ && command -v radar &>/dev/null; then
    RADAR_CMDS=()
    if $CREATE_A && ! pgrep -qf "radar.*a-cluster" 2>/dev/null; then
      RADAR_CMDS+=("radar -kubeconfig ${KC_A} -port 9280")
    elif $CREATE_A; then echo "  [skip] radar for ${CLUSTER_A} already running"; fi
    if $CREATE_B && ! pgrep -qf "radar.*b-cluster" 2>/dev/null; then
      RADAR_CMDS+=("radar -kubeconfig ${KC_B} -port 9281")
    elif $CREATE_B; then echo "  [skip] radar for ${CLUSTER_B} already running"; fi
    [[ ${#RADAR_CMDS[@]} -gt 0 ]] && open_zellij_tab "radar" "${RADAR_CMDS[@]}"
  else
    $CREATE_A && open_radar "${KC_A}" "${CLUSTER_A}" 9280
    $CREATE_B && open_radar "${KC_B}" "${CLUSTER_B}" 9281
  fi
fi

# ──────────────────────────────────────────────────────
# 4. k9s  (zellij: dedicated tab with one pane per cluster)
# ──────────────────────────────────────────────────────
if $USE_ZELLIJ || $USE_TMUX; then
  if $USE_ZELLIJ && command -v k9s &>/dev/null; then
    K9S_CMDS=()
    if $CREATE_A && ! pgrep -qf "k9s.*--context kind-${CLUSTER_A}" 2>/dev/null; then
      K9S_CMDS+=("KUBECONFIG=${KC_A} k9s --context kind-${CLUSTER_A}")
    elif $CREATE_A; then echo "  [skip] k9s for ${CLUSTER_A} already running"; fi
    if $CREATE_B && ! pgrep -qf "k9s.*--context kind-${CLUSTER_B}" 2>/dev/null; then
      K9S_CMDS+=("KUBECONFIG=${KC_B} k9s --context kind-${CLUSTER_B}")
    elif $CREATE_B; then echo "  [skip] k9s for ${CLUSTER_B} already running"; fi
    [[ ${#K9S_CMDS[@]} -gt 0 ]] && open_zellij_tab "k9s" "${K9S_CMDS[@]}"
  elif $USE_TMUX; then
    if $CREATE_A && $CREATE_B; then
      open_k9s "${KC_A}" "${CLUSTER_A}" right
      sleep 1
      open_k9s "${KC_B}" "${CLUSTER_B}" right
    elif $CREATE_A; then
      open_k9s "${KC_A}" "${CLUSTER_A}" right
    elif $CREATE_B; then
      open_k9s "${KC_B}" "${CLUSTER_B}" right
    fi
  fi
fi

# ──────────────────────────────────────────────────────
# 5. Port-forwards  (both clusters in parallel)
# ──────────────────────────────────────────────────────
# Return to the setup tab so sudo prompts are visible.
$USE_ZELLIJ && zellij action go-to-tab-name "setup" 2>/dev/null || true

# Collect table output to a file; displayed in a "urls" tab after port-forwards start.
TABLE_FILE=""
if $USE_ZELLIJ; then
  TABLE_FILE="/tmp/kind-tables-$$.txt"
  rm -f "${TABLE_FILE}"
fi
export ZELLIJ_TABLE_FILE="${TABLE_FILE}"

echo ""
echo "==> Starting port-forwards (sudo required for port 80)"
# Pre-cache sudo so both clusters can start in parallel without double-prompting.
sudo -v

if $CREATE_A; then
  CLUSTER_NAME="${CLUSTER_A}" "${SCRIPT_DIR}/port-forward.sh" &
fi
if $CREATE_B; then
  CLUSTER_NAME="${CLUSTER_B}" \
  ALIAS_SHARD1="127.0.0.4" \
  ALIAS_SHARD2="127.0.0.5" \
  HUBBLE_PORT="12001" \
    "${SCRIPT_DIR}/port-forward.sh" &
fi
wait

# Open all cluster ingress URLs in a single browser window.
if [[ "$(uname)" == "Darwin" ]]; then
  echo ""
  echo "==> Opening browser"
  ALL_URLS=()
  if $CREATE_A; then
    ALL_URLS+=(
      "http://team-alpha.${CLUSTER_A}"
      "http://team-beta.${CLUSTER_A}"
      "http://team-gamma.${CLUSTER_A}"
      "http://traffic-alpha.${CLUSTER_A}"
      "http://traffic-beta.${CLUSTER_A}"
      "http://traffic-gamma.${CLUSTER_A}"
      "http://localhost:12000"
    )
  fi
  if $CREATE_B; then
    ALL_URLS+=(
      "http://team-alpha.${CLUSTER_B}"
      "http://team-beta.${CLUSTER_B}"
      "http://team-gamma.${CLUSTER_B}"
      "http://traffic-alpha.${CLUSTER_B}"
      "http://traffic-beta.${CLUSTER_B}"
      "http://traffic-gamma.${CLUSTER_B}"
      "http://localhost:12001"
    )
  fi
  [[ ${#ALL_URLS[@]} -gt 0 ]] && open "${ALL_URLS[@]}"
fi

# Open combined URL table as a read-only "urls" tab (last tab opened).
if $USE_ZELLIJ && [[ -s "${TABLE_FILE}" ]]; then
  open_zellij_tab "urls" "less -S '${TABLE_FILE}'"
fi
