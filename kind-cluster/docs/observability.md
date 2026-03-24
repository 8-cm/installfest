# Observability Guide

How to observe every layer of communication in the environment using Hubble, tcpdump, tshark, and kubectl logs.

## Tools

| Tool | Purpose | Access |
|------|---------|--------|
| **Hubble UI** | L3/L4 flow graph, service map, drop reasons, egress-gw verdicts, DNS | `http://localhost:12000` (a-cluster), `http://localhost:12001` (b-cluster) |
| **k9s** | Real-time pod/event/log view, exec into pods | `KUBECONFIG=a-cluster.kubeconfig k9s --context kind-a-cluster` |
| **radar** | Web-based cluster resource browser | `radar -kubeconfig a-cluster.kubeconfig -port 9280` |
| **tcpdump** | Raw packet capture at any vantage point | `docker exec <node> tcpdump ...` |
| **tshark** | Wireshark CLI — decode HTTP, DNS, follow streams | `docker exec <node> tshark ...` |

---

## Vantage Points

### 1. Pod network namespace

Captures traffic as seen by the application — before any eBPF NAT. Shows real destination IP (ClusterIP, not pod IP after DNAT).

```bash
NS=team-alpha
POD=$(kubectl --kubeconfig a-cluster.kubeconfig -n $NS \
  get pod -l app=traffic-monitor -o jsonpath='{.items[0].metadata.name}')

# Exec directly into pod and capture
kubectl --kubeconfig a-cluster.kubeconfig exec -n $NS $POD \
  -c gen-external -- sh -c 'apk add tcpdump -q && tcpdump -i eth0 -n tcp'
```

**What you see**: DNS queries to kube-dns, TCP SYNs to ClusterIPs (before eBPF DNAT), RSTs from blackhole service (ClusterIP sends RST).

---

### 2. Worker node — after eBPF DNAT

Captures on the worker node show traffic after Cilium has applied DNAT. ClusterIPs are replaced by actual pod IPs.

```bash
# All TCP port 80 on a worker node
docker exec a-cluster-worker tcpdump -i any -n tcp port 80

# Filter for a specific pod (get IP first)
POD_IP=$(kubectl --kubeconfig a-cluster.kubeconfig -n team-alpha \
  get pod -l app=traffic-monitor -o jsonpath='{.items[0].status.podIP}')
docker exec a-cluster-worker tcpdump -i any -n host $POD_IP

# DNS traffic from all pods on this node
docker exec a-cluster-worker tcpdump -i any -n udp port 53
```

**What you see**: pod-to-pod TCP after DNAT, DNS queries, responses. ClusterIPs do not appear here — only pod IPs.

---

### 3. Network node — ingress path (shard-1 on worker5)

All inbound traffic for `team-alpha` and `traffic-alpha` enters through worker5's eth0.

```bash
# All port 80 traffic on the ingress node
docker exec a-cluster-worker5 tcpdump -i eth0 -n tcp port 80

# Decode HTTP with tshark (if installed)
docker exec a-cluster-worker5 sh -c \
  'tshark -i eth0 -f "tcp port 80" -Y "http.request" \
   -T fields -e frame.time_relative -e ip.src -e ip.dst \
   -e http.host -e http.request.uri -e http.request.method 2>/dev/null'

# Watch HAProxy access log
kubectl --kubeconfig a-cluster.kubeconfig logs -n haproxy-system \
  -l "app.kubernetes.io/name=kubernetes-ingress,app.kubernetes.io/instance=haproxy-shard-1" -f
```

**What you see**: incoming port-forward connections (src=127.0.0.x tunneled), HAProxy proxying to pod IPs, and outbound egress traffic from team-alpha pods SNATed to worker5 IP.

---

### 4. Network node — egress gateway (SNAT point)

The most informative capture for demonstrating CiliumEgressGateway. All external traffic from `team-alpha` leaves through worker5, regardless of which worker node the pod is scheduled on.

```bash
# Capture egress traffic on network-00 (team-alpha gateway)
docker exec a-cluster-worker5 tcpdump -i eth0 -n \
  'tcp and not dst net 10.0.0.0/8 and not dst net 192.168.0.0/16'

# Same for network-01 (team-beta gateway)
docker exec a-cluster-worker6 tcpdump -i eth0 -n \
  'tcp and not dst net 10.0.0.0/8 and not dst net 192.168.0.0/16'

# Capture on a regular worker (team-gamma traffic — non-deterministic source)
docker exec a-cluster-worker2 tcpdump -i eth0 -n \
  'tcp and not dst net 10.0.0.0/8'
```

**alpha/beta**: all cross-cluster TCP from those namespaces appears here with src=network node's Docker IP.
**gamma**: cross-cluster TCP appears on whichever worker the pod is running on — source IP changes on pod reschedule.

---

### 5. Docker bridge — cross-cluster traffic

The Docker bridge (`br-kind`) carries all traffic between the two clusters.

```bash
# Find the bridge interface name
BRIDGE=$(docker network ls --filter name=kind --format '{{.ID}}' | head -1 | cut -c1-12)
echo "Bridge: br-$BRIDGE"

# Capture all cross-cluster HTTP
sudo tcpdump -i br-$BRIDGE -n tcp port 80

# Decode with tshark — show Host header to see which cluster is targeted
sudo tshark -i br-$BRIDGE -f 'tcp port 80' \
  -Y 'http.request' \
  -T fields \
  -e frame.time_relative \
  -e ip.src \
  -e ip.dst \
  -e http.host \
  -e http.request.method

# Watch both directions with tcpdump and timestamp
sudo tcpdump -i br-$BRIDGE -n -tttt 'tcp port 80 and (tcp[tcpflags] & tcp-syn != 0)'
```

**What you see**: TCP connections between cluster Docker IPs. Source IPs reveal which network node is acting as egress gateway — `172.18.A.5` for alpha, `172.18.A.6` for beta, variable for gamma.

---

## Side-by-side: alpha vs gamma egress comparison

Run these in three terminals simultaneously to see the SNAT difference live.

**Terminal 1** — worker5: only team-alpha egress appears here
```bash
docker exec a-cluster-worker5 tcpdump -i eth0 -n \
  'tcp dst port 80 and not src net 10.0.0.0/8' &
```

**Terminal 2** — find and watch gamma's worker
```bash
GAMMA_NODE=$(kubectl --kubeconfig a-cluster.kubeconfig \
  get pod -n team-gamma -l app=traffic-external \
  -o jsonpath='{.items[0].spec.nodeName}')
# Strip cluster prefix: a-cluster-worker3 -> worker3
NODE_SHORT="${GAMMA_NODE#a-cluster-}"
docker exec a-cluster-${NODE_SHORT} tcpdump -i eth0 -n \
  'tcp dst port 80 and not src net 10.0.0.0/8'
```

**Terminal 3** — Hubble UI: open `http://localhost:12000`, select service map.

In Hubble: team-alpha flows will show `worker5` as an intermediate hop (egress gateway verdict). team-gamma flows show no egress gateway — the packet exits directly from the pod's worker.

---

## Hubble UI filters

| What to observe | Filter |
|-----------------|--------|
| All team-alpha traffic | Namespace: `team-alpha` |
| Egress-gateway verdicts | Verdict: `FORWARDED`, filter by destination outside pod CIDR |
| TCP RST from blackhole | Verdict: `DROPPED`, or destination service: `blackhole` |
| Cross-cluster flows | Destination IP: b-cluster Docker subnet (`172.18.x.x`) |
| DNS queries | Destination port: `53` |
| Ingress from HAProxy | Source: HAProxy pod IP, Destination namespace: `team-alpha` |
| 404 chaos requests | Filter by HTTP response code if L7 policy is enabled |

---

## kubectl log streams

```bash
# team-alpha generators — raw output
kubectl --kubeconfig a-cluster.kubeconfig logs -n team-alpha \
  deploy/traffic-monitor -c gen-internal -f

kubectl --kubeconfig a-cluster.kubeconfig logs -n team-alpha \
  deploy/traffic-monitor -c gen-external -f

kubectl --kubeconfig a-cluster.kubeconfig logs -n team-alpha \
  deploy/traffic-monitor -c gen-chaos -f

# hello gen-cross sidecar
kubectl --kubeconfig a-cluster.kubeconfig logs -n team-alpha \
  deploy/hello -c gen-cross -f

# HAProxy access log (shard-1)
kubectl --kubeconfig a-cluster.kubeconfig logs -n haproxy-system \
  -l "app.kubernetes.io/instance=haproxy-shard-1" -f

# Cilium agent logs (egress-gw decisions)
kubectl --kubeconfig a-cluster.kubeconfig logs -n kube-system \
  -l k8s-app=cilium -c cilium-agent -f | grep -i egress
```

---

## Node-level TCP dump cheat sheet

```bash
# Cluster node names
kubectl --kubeconfig a-cluster.kubeconfig get nodes -o wide

# Quick access pattern
docker exec a-cluster-<nodename> tcpdump -i eth0 -n -c 100 tcp port 80

# With packet content (first 200 bytes)
docker exec a-cluster-worker5 tcpdump -i eth0 -n -s 200 -A tcp port 80

# Save pcap for Wireshark
docker exec a-cluster-worker5 tcpdump -i eth0 -n -w /tmp/cap.pcap tcp port 80 &
# ... wait ...
docker cp a-cluster-worker5:/tmp/cap.pcap ./capture.pcap
# open in Wireshark on host
```

---

## What changes when a team-gamma pod restarts

```bash
# Before restart: note current worker node and source IP seen on b-cluster
kubectl --kubeconfig a-cluster.kubeconfig get pod -n team-gamma \
  -l app=traffic-external -o wide

# Start capturing on b-cluster HAProxy
docker exec b-cluster-worker5 tcpdump -i eth0 -n tcp port 80 | grep SYN &

# Restart the pod
kubectl --kubeconfig a-cluster.kubeconfig rollout restart \
  -n team-gamma deploy/traffic-external

# Watch: source IP in b-cluster capture changes if pod lands on different worker
kubectl --kubeconfig a-cluster.kubeconfig get pod -n team-gamma \
  -l app=traffic-external -o wide -w
```

For team-alpha, repeat the same test — the source IP on b-cluster will NOT change regardless of which worker the pod is rescheduled to. This is the egress gateway guarantee.
