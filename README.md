# Kind Dual-Cluster Network Observability POC

A two-cluster [Kind](https://kind.sigs.k8s.io/) environment built to demonstrate and capture every layer of Kubernetes network communication — from pod-to-pod within a namespace, through cross-namespace and cross-cluster traffic, to egress pinned via Cilium EgressGateway (visible as SNAT in Hubble and tcpdump).

Designed as a hands-on POC for network analysis with `tcpdump`, `tshark`, Hubble UI, k9s, and radar.

## What you can observe

| Communication type | Capture point | Příkaz |
|--------------------|---------------|--------|
| Pod to pod (same namespace, ClusterIP svc) | node — veth (node strana) | `oc debug node/<node> -- chroot /host tcpdump -i vethXXX -n` |
| Pod to pod (same namespace, ClusterIP svc) | pod — eth0 | `oc debug node/<node> -- chroot /host bash -c 'nsenter -t $PID -n -- tcpdump -i eth0 -n'` |
| Pod to pod (cross-namespace, ClusterIP svc) | worker node, Hubble flow graph | `oc debug node/<node> -- chroot /host tcpdump -i eth0 -n` |
| Ingress path (host to pod via HAProxy shard) | node — eth0 (network-00) | `oc debug node/a-cluster-worker5 -- chroot /host tcpdump -i eth0 -n port 80` |
| Ingress path (host to pod via HAProxy shard) | pod — HAProxy eth0 | `oc debug node/a-cluster-worker5 -- chroot /host bash -c 'nsenter -t $PID -n -- tcpdump -i eth0 -n'` |
| Egress pinned (alpha/beta) — deterministic SNAT | node — eth0 (network node) | `oc debug node/a-cluster-worker5 -- chroot /host tcpdump -i eth0 -n` |
| Egress unpinned (gamma) — non-deterministic | any worker node — source IP = pod's current node | `oc debug node/<gamma-node> -- chroot /host tcpdump -i eth0 -n` |
| TCP RST from blackhole service (no endpoints) | pod — eth0 | `oc debug node/<node> -- chroot /host bash -c 'nsenter -t $PID -n -- tcpdump -i eth0 -n'` |
| DNS queries (CoreDNS) | node — any | `oc debug node/<node> -- chroot /host tcpdump -i any -n udp port 53` |
| Cross-cluster TCP (Docker bridge) | host Docker bridge (Linux only) | `sudo tcpdump -i br-kind -n tcp port 80` |

See [docs/observability.md](kind-cluster/docs/observability.md) for exact tcpdump/tshark commands and vantage points.

## Architecture

Two identical Kind clusters (`a-cluster`, `b-cluster`), each with:
- 3 control-plane nodes (etcd HA)
- 4 worker nodes (application pods)
- 2 dedicated network nodes with HAProxy ingress (hostPort:80) and Cilium egress gateway
- Cilium 1.16.5: kube-proxy replacement, EgressGateway, Hubble relay + UI

The clusters communicate directly over the Docker bridge network — no overlay tunnel.

See [docs/architecture.md](kind-cluster/docs/architecture.md) for full diagrams.

## Quick start

```bash
# Prerequisites: kind, helm, kubectl, docker

# Create both clusters (default)
./setup-dual-cluster.sh

# With Zellij tabs for k9s + radar TUI
./setup-dual-cluster.sh --zellij --radar

# One cluster only
./setup-dual-cluster.sh --create=a

# Delete everything
./setup-dual-cluster.sh --delete=ab

# Re-run port-forwards after a restart (clusters already exist)
./port-forward.sh
CLUSTER_NAME=b-cluster ALIAS_SHARD1=127.0.0.4 ALIAS_SHARD2=127.0.0.5 HUBBLE_PORT=12001 ./port-forward.sh

# Re-wire cross-cluster peer IPs (after Docker restart when bridge IPs change)
./setup-dual-cluster.sh wire
```

## URLs after port-forward

**a-cluster**

| URL | What you will find |
|-----|--------------------|
| `http://team-alpha.a-cluster` | nginx hello; live inbound + outbound dashboard; shard-1 ingress; egress pinned to network-00 |
| `http://team-beta.a-cluster`  | nginx hello; live inbound + outbound dashboard; shard-2 ingress; egress pinned to network-01 |
| `http://team-gamma.a-cluster` | nginx hello; live inbound + outbound dashboard; shard-2 ingress; egress via any node |
| `http://traffic-alpha.a-cluster` | traffic-monitor dashboard; 4 generators: internal / cross-ns / peer-cluster / chaos |
| `http://traffic-beta.a-cluster`  | traffic-monitor dashboard; 4 generators: internal / cross-ns / peer-cluster / chaos |
| `http://traffic-gamma.a-cluster` | traffic-monitor dashboard; 4 generators: internal / cross-ns / peer-cluster / chaos |
| `http://localhost:12000` | Hubble UI: L3/L4 flow graph, service map, DNS, egress-gateway SNAT verdicts |

**b-cluster** — same URLs with `.b-cluster` domain; Hubble at `http://localhost:12001`

## Namespaces

| Namespace | Ingress shard | Egress gateway | Key observation |
|-----------|--------------|----------------|-----------------|
| `team-alpha` | shard-1 (worker5 / network-00) | `egress-team-alpha` pinned to network-00 | All alpha pod egress SNATs to worker5 Docker IP |
| `team-beta`  | shard-2 (worker6 / network-01) | `egress-team-beta` pinned to network-01 | All beta pod egress SNATs to worker6 Docker IP |
| `team-gamma` | shard-2 (worker6 / network-01) | none | Egress source IP is non-deterministic (pod's node) |

See [docs/namespaces.md](kind-cluster/docs/namespaces.md) for per-namespace workload detail.
See [docs/traffic-flows.md](kind-cluster/docs/traffic-flows.md) for every communication flow with Mermaid diagrams.

## Repo structure

```
kind-cluster/
├── setup-dual-cluster.sh        # orchestration: clusters + peer wiring + zellij tabs + port-forwards
├── setup.sh                     # single-cluster setup (idempotent)
├── port-forward.sh              # loopback aliases + kubectl port-forward + /etc/hosts
├── cluster.yaml                 # Kind cluster config: a-cluster (3 CP + 4 worker + 2 network)
├── cluster-b.yaml               # Same config for b-cluster
├── egress/
│   ├── setup-egress.sh          # Creates CiliumEgressGatewayPolicies (alpha + beta)
│   └── namespaces.yaml          # Namespace definitions with egress-group labels
├── haproxy/
│   ├── setup-haproxy.sh         # Installs HAProxy via Helm (2 shards)
│   ├── shard1-values.yaml       # Shard-1: node network-00, watches team-alpha
│   └── shard2-values.yaml       # Shard-2: node network-01, watches team-beta + team-gamma
├── apps/
│   ├── setup-apps.sh            # Applies all app manifests
│   ├── team-alpha.yaml          # hello deployment + svc + ingress (haproxy-shard-1)
│   ├── team-beta.yaml           # hello deployment + svc + ingress (haproxy-shard-2)
│   ├── team-gamma.yaml          # hello deployment + svc + ingress (haproxy-shard-2)
│   ├── hello-nginx-cm.yaml      # Nginx config + live traffic dashboard HTML (3 panels)
│   ├── traffic-monitor.yaml     # traffic-monitor pods (nginx + 4 curl generators)
│   ├── traffic-generators.yaml  # Standalone traffic-internal/cross/external pods
│   ├── traffic-dashboard-cm.yaml
│   └── blackhole-svc.yaml       # No-backend service — Cilium sends TCP RST immediately
└── docs/
    ├── architecture.md          # Node layout, Cilium, HAProxy, cross-cluster wiring
    ├── namespaces.md            # Per-namespace workloads and communication patterns
    ├── traffic-flows.md         # All communication flows with Mermaid sequence diagrams
    └── observability.md         # tcpdump/tshark commands, Hubble filters, vantage points
```
