# Traffic Flows

All communication flows present in the environment, their source, destination, frequency, and what to look for when capturing.

## Flow Inventory

| # | Flow type | Source | Destination | Protocol | Frequency |
|---|-----------|--------|-------------|----------|-----------|
| 1 | Intra-namespace pod → ClusterIP svc | `traffic-internal` / `gen-internal` | `hello.<ns>.svc.cluster.local` | TCP HTTP | 5s |
| 2 | Cross-namespace pod → ClusterIP svc | `traffic-cross` / `gen-cross` | `hello.<other-ns>.svc.cluster.local` | TCP HTTP | 10–25s |
| 3 | Ingress: host → pod (via HAProxy) | browser / port-forward | `hello` or `traffic-monitor` pod | TCP HTTP | on demand |
| 4 | Egress pinned (alpha/beta) → peer cluster | `traffic-external` / `gen-external` | peer cluster shard hostPort:80 | TCP HTTP | 20s |
| 5 | Egress unpinned (gamma) → peer cluster | `traffic-external` / `gen-external` | peer cluster shard hostPort:80 | TCP HTTP | 20s |
| 6 | TCP RST — blackhole service | `gen-chaos` / `gen-cross` | `blackhole.<ns>.svc.cluster.local` | TCP | ~42s |
| 7 | HTTP 404 chaos | `gen-chaos` / `gen-cross` | `<shard>/<ns>/chaos-not-found` via ClusterIP | HTTP | ~28s |
| 8 | DNS — service resolution | every pod, every request | CoreDNS (`kube-dns` svc `:53`) | UDP/TCP | per curl |
| 9 | Cross-cluster TCP (Docker bridge) | network node after egress-gw SNAT | peer cluster network node hostPort:80 | TCP | 20s |

---

## Flow 1: Intra-namespace pod to ClusterIP service

Same-namespace traffic. Cilium eBPF replaces kube-proxy: there are no iptables NAT rules — DNAT happens in eBPF at the socket layer.

```mermaid
sequenceDiagram
    participant P as traffic-internal pod
    participant eBPF as Cilium eBPF (socket level)
    participant HP as hello pod (:8080)

    P->>eBPF: TCP SYN dst=ClusterIP:80
    Note over eBPF: DNAT: ClusterIP -> selected pod IP<br/>load-balancing in eBPF (no iptables)
    eBPF->>HP: TCP SYN dst=pod_IP:8080
    HP-->>P: HTTP 200
    Note over P: logs: [HH:MM:SS] internal -> hello.<ns>.svc: 200
```

**Capture point**: worker node veth or pod netns — will see pod IP after DNAT, not ClusterIP.

---

## Flow 2: Cross-namespace pod to ClusterIP service

Traffic crossing the namespace boundary. No `NetworkPolicy` exists so Cilium allows all. DNS resolves a FQDN in another namespace.

```mermaid
sequenceDiagram
    participant GT as traffic-cross (team-alpha)
    participant DNS as CoreDNS
    participant eBPF2 as Cilium eBPF
    participant HP2 as hello pod (team-beta)

    GT->>DNS: UDP query: hello.team-beta.svc.cluster.local
    DNS-->>GT: A record: ClusterIP of team-beta/hello

    GT->>eBPF2: TCP SYN dst=team-beta ClusterIP:80
    Note over eBPF2: DNAT to team-beta pod IP<br/>crosses namespace boundary — allowed (no NetworkPolicy)
    eBPF2->>HP2: TCP to pod IP:8080
    HP2-->>GT: HTTP 200
```

**Capture point**: Hubble UI — filter `source namespace=team-alpha` to see outbound, or `destination namespace=team-beta` to see inbound. In Hubble the DNAT is transparent — flows show pod-to-pod.

---

## Flow 3: Ingress path (host browser to pod)

The full path from the developer's browser through port-forward and HAProxy into a pod.

```mermaid
sequenceDiagram
    participant B as Browser (host)
    participant PF as kubectl port-forward<br/>127.0.0.2:80 -> svc
    participant HN as worker5 eth0<br/>HAProxy hostPort:80
    participant HA as HAProxy process
    participant SVC as hello svc ClusterIP
    participant POD as hello pod (:8080)

    B->>PF: HTTP GET http://team-alpha.a-cluster/
    Note over PF: port-forward to svc/haproxy-shard-1:80
    PF->>HN: TCP to ClusterIP
    Note over HN: HAProxy is bound to hostPort:80 on eth0
    HN->>HA: forwarded locally
    HA->>SVC: proxy_pass with preserved Host header
    Note over SVC: Cilium eBPF DNAT: ClusterIP -> pod IP
    SVC->>POD: TCP to pod IP:8080
    POD-->>B: HTTP 200 (nginx dashboard page)
    Note over POD: nginx logs src=HAProxy IP to /data/in.log
```

**What you'll see in nginx**: the source IP in `in.log` is the HAProxy pod's IP (not your browser IP). HAProxy adds `X-Forwarded-For` with the original client IP but nginx doesn't log it by default.

**Capture on worker5**: `docker exec a-cluster-worker5 tcpdump -i eth0 tcp port 80` — shows incoming TCP from the port-forward address and HAProxy's proxy connections to pod IPs.

---

## Flow 4 & 5: Egress to peer cluster (with and without egress gateway)

This is the key demonstration flow distinguishing the three namespaces.

```mermaid
sequenceDiagram
    participant PA as team-alpha pod (worker3)
    participant eBPF3 as Cilium eBPF (worker3)
    participant GW as worker5 (egress-gw)<br/>network-00
    participant DB as Docker bridge
    participant BHA as b-cluster worker5<br/>HAProxy shard-1 hostPort:80
    participant BP as b-cluster team-alpha pod

    PA->>eBPF3: TCP SYN dst=172.18.B.5:80
    Note over eBPF3: CiliumEgressGatewayPolicy matches<br/>packet redirected to worker5 (egress-gw node)
    eBPF3->>GW: packet forwarded to network-00
    Note over GW: masquerade: src = 172.18.A.5 (worker5 Docker IP)
    GW->>DB: TCP src=172.18.A.5 dst=172.18.B.5:80
    DB->>BHA: delivered to b-cluster worker5
    BHA->>BP: HAProxy routes to team-alpha pod
    BP-->>PA: HTTP 200
```

For **team-gamma** (no egress policy), step 3 is skipped — the packet exits from worker3 directly with src=worker3's Docker IP. If the pod is rescheduled to worker2, the source IP changes.

```mermaid
graph LR
    subgraph "What b-cluster HAProxy access log shows"
        A["team-alpha requests\nsrc always: 172.18.A.5\n(worker5 IP — fixed)"]
        B["team-beta requests\nsrc always: 172.18.A.6\n(worker6 IP — fixed)"]
        G["team-gamma requests\nsrc: 172.18.A.2 or .3 or .4\n(changes with pod scheduling)"]
    end
```

---

## Flow 6: TCP RST from blackhole service

Cilium detects a service with no ready endpoints and responds with TCP RST without forwarding to any backend. This happens in eBPF — no TCP handshake completes.

```mermaid
sequenceDiagram
    participant GCH as gen-chaos
    participant eBPF4 as Cilium eBPF
    participant BH as blackhole svc<br/>(ClusterIP, selector: blackhole-nonexistent)

    GCH->>eBPF4: TCP SYN dst=blackhole ClusterIP:80
    Note over eBPF4: Service lookup: 0 endpoints found<br/>Cilium sends TCP RST immediately
    eBPF4-->>GCH: TCP RST
    Note over GCH: curl returns code 000<br/>logged as "refused"
```

**What you'll see in tcpdump**:
```
# SYN
10:00:01.123 IP pod_IP.random_port > ClusterIP.80: Flags [S]
# Immediate RST (no SYN-ACK)
10:00:01.124 IP ClusterIP.80 > pod_IP.random_port: Flags [R.]
```

**Hubble**: shows `verdict=DROPPED` with `reason=policy-denied` or `no-endpoint` depending on Cilium version. The `blackhole` service name appears in the destination field.

---

## Flow 7: HTTP 404 chaos

gen-chaos sends a valid HTTP request to a real HAProxy shard but uses a path (`/chaos-not-found`) that doesn't match any Ingress rule. HAProxy returns 404.

```mermaid
sequenceDiagram
    participant GCH2 as gen-chaos
    participant SVC2 as haproxy-shard-2 ClusterIP
    participant HA2 as HAProxy pod
    participant POD2 as team-beta hello pod

    GCH2->>SVC2: GET /chaos-not-found HTTP/1.1\nHost: team-beta.a-cluster
    Note over SVC2: Cilium DNAT to HAProxy pod
    SVC2->>HA2: TCP proxy
    Note over HA2: path /chaos-not-found not in Ingress rules
    HA2-->>GCH2: HTTP 404
    Note over GCH2: logged as "chaos -> team-beta.a-cluster/not-found: 404"
```

**Observable at**: HAProxy access log — `kubectl logs -n haproxy-system -l app.kubernetes.io/name=kubernetes-ingress`

---

## Flow 8: DNS resolution

Every service-name curl call begins with a DNS query. CoreDNS runs as a deployment in `kube-system` and responds to `*.svc.cluster.local` queries.

```mermaid
sequenceDiagram
    participant P5 as any pod
    participant R as pod's resolv.conf<br/>nameserver = kube-dns ClusterIP
    participant eBPF5 as Cilium eBPF
    participant CD as CoreDNS pod

    P5->>R: glibc: resolve hello.team-beta.svc.cluster.local
    R->>eBPF5: UDP dst=kube-dns ClusterIP:53
    Note over eBPF5: DNAT to CoreDNS pod IP
    eBPF5->>CD: DNS query
    CD-->>P5: A record: hello ClusterIP (e.g. 10.96.x.x)
    Note over P5: opens TCP connection to ClusterIP:80
```

**High frequency**: every curl loop re-resolves unless glibc caches the record (TTL 5s in CoreDNS). With ~6 generators per namespace and 3 namespaces per cluster, expect 30+ DNS queries per minute.

**Capture**: `docker exec a-cluster-worker tcpdump -i any udp port 53` — shows all DNS queries from pods scheduled on that node.

---

## Flow 9: Cross-cluster TCP over Docker bridge

This flow is the combination of egress-gw SNAT (Flows 4/5) with the Docker bridge routing between cluster nodes.

```mermaid
graph LR
    subgraph "a-cluster"
        POD_A["team-alpha pod\n10.244.x.x\n(any worker)"]
        eBPF_A["Cilium eBPF\nworker3\n(pod's node)"]
        EGW_A["worker5 eth0\n172.18.A.5\negress-gw SNAT"]
    end

    subgraph "host"
        BR["Docker bridge\nbr-xxxx\n172.18.0.0/16\nTCP routing between containers"]
    end

    subgraph "b-cluster"
        W5B3["worker5 eth0\n172.18.B.5\nHAProxy hostPort:80"]
        POD_B3["team-alpha pod (b-cluster)\n10.244.y.y"]
    end

    POD_A -->|"TCP dst=172.18.B.5:80"| eBPF_A
    eBPF_A -->|"redirected to egress-gw"| EGW_A
    EGW_A -->|"src=172.18.A.5\ndst=172.18.B.5:80"| BR
    BR --> W5B3
    W5B3 -->|"HAProxy proxy\nCilium DNAT"| POD_B3
```

**Capture on host Docker bridge**:
```bash
BRIDGE=$(docker network ls --filter name=kind --format '{{.ID}}' | cut -c1-12)
sudo tcpdump -i br-$BRIDGE -n tcp port 80
```

You will see TCP between two Docker IPs (`172.18.x.x` → `172.18.y.y:80`). The source IP reveals which network node is acting as egress gateway for that namespace.
