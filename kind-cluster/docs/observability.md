# Observability Guide

How to observe every layer of communication in the environment using Hubble, tcpdump, tshark, and kubectl logs.

## Tools

| Tool | Purpose | Access |
|------|---------|--------|
| **Hubble UI** | L3/L4 flow graph, service map, drop reasons, egress-gw verdicts, DNS | `http://localhost:12000` (a-cluster), `http://localhost:12001` (b-cluster) |
| **k9s** | Real-time pod/event/log view, exec into pods | `KUBECONFIG=a-cluster.kubeconfig k9s --context kind-a-cluster` |
| **radar** | Web-based cluster resource browser | `radar -kubeconfig a-cluster.kubeconfig -port 9280` |
| **tcpdump** | Raw packet capture at any vantage point | `oc debug node/<node> -- chroot /host tcpdump ...` |
| **tshark** | Wireshark CLI — decode HTTP, DNS, follow streams | `oc debug node/<node> -- chroot /host tshark ...` |
| **kube-dump** | Hromadné zachytávání napříč pody a nody | `KUBECONFIG=a-cluster.kubeconfig ./tools/kube-dump.sh -l app=... -e 'tcpdump ...'` |

---

## E2E Packet Walk

Full packet path diagrams with a capture command at every hop. `oc debug node` gives a privileged shell on the node; `nsenter -t <PID> -n` enters the pod's network namespace without requiring a privileged pod.

### Ingress: browser → hello pod

```
 [ Browser — macOS ]
     │  GET http://team-alpha.a-cluster/
     │  /etc/hosts: team-alpha.a-cluster → 127.0.0.2
     │
     ▼
 [ lo0 — loopback alias 127.0.0.2:80 ]
     │
     │  sudo tcpdump -i lo0 -n 'host 127.0.0.2 and port 80'
     │  vidíš: SYN, SYN-ACK, GET / HTTP/1.1, 200 OK
     │
     ▼
 [ kubectl port-forward (sudo) ]
     │  listener: 127.0.0.2:80
     │  tunel: kube-apiserver → kubelet na worker5 → haproxy pod :80
     │
     ▼
 [ a-cluster-worker5 eth0 ]  172.18.0.5
     │
     │  oc debug node/a-cluster-worker5 -- \
     │    chroot /host tcpdump -i eth0 -n port 80
     │  vidíš: src=172.18.0.1, dst=172.18.0.5:80
     │         příchozí HTTP od port-forward tunelu
     │
     ▼
 [ HAProxy pod — haproxy-system ]
     │  hostPort: worker5:80 → haproxy :80
     │  čte Ingress: host=team-alpha.a-cluster
     │  → backend: hello.team-alpha.svc.cluster.local:80
     │
     │  oc debug node/a-cluster-worker5 -- chroot /host bash -c '
     │    PID=$(crictl inspect \
     │      $(crictl ps -q --name haproxy) | jq .info.pid)
     │    nsenter -t $PID -n -- tcpdump -i eth0 -n port 80'
     │  vidíš: příchozí GET /, odchozí na ClusterIP hello svc
     │
     ▼
 [ Cilium eBPF — DNAT ]
     │  ClusterIP (10.96.x.x:80) → pod IP 10.244.3.7:8080
     │
     ▼
 [ vethXXXXXX na worker5 ]  ← node strana veth páru
     │
     │  # najdi veth přes nsenter (bez exec do podu):
     │  oc debug node/a-cluster-worker5 -- chroot /host bash -c '
     │    PID=$(crictl inspect \
     │      $(crictl ps -q --name hello) | jq .info.pid)
     │    IFIDX=$(nsenter -t $PID -n -- \
     │      cat /sys/class/net/eth0/iflink)
     │    VETH=$(ip link | awk -F": " "/^${IFIDX}:/{print \$2}")
     │    tcpdump -i $VETH -n'
     │  vidíš: DNAT proběhl, dst=10.244.3.7:8080
     │
     ▼
 [ hello pod eth0 ]  10.244.3.7:8080
     │
     │  oc debug node/a-cluster-worker5 -- chroot /host bash -c '
     │    PID=$(crictl inspect \
     │      $(crictl ps -q --name hello) | jq .info.pid)
     │    nsenter -t $PID -n -- tcpdump -i eth0 -n'
     │  vidíš: src=HAProxy pod IP, dst=10.244.3.7:8080
     │         čistý HTTP, žádný NAT
     │
     ▼
 [ nginx — HTTP 200 OK ]
```

---

### Egress: team-alpha pod → egress gateway (SNAT)

```
 [ team-alpha pod eth0 ]  10.244.3.7
     │  curl http://172.18.0.15:80
     │
     │  oc debug node/a-cluster-worker1 -- chroot /host bash -c '
     │    PID=$(crictl inspect \
     │      $(crictl ps -q --name hello) | jq .info.pid)
     │    nsenter -t $PID -n -- tcpdump -i eth0 -n'
     │  vidíš: SYN dst=172.18.0.15:80, src=10.244.3.7
     │         před SNAT — stále pod IP
     │
     ▼
 [ Cilium eBPF — EgressGatewayPolicy ]
     │  selector: namespace=team-alpha
     │  egressGateway: a-cluster-worker5 (network-00)
     │  pokud pod NENÍ na worker5 → VXLAN redirect
     │
     ▼
 (cross-node případ — pod běží na worker1)

 [ a-cluster-worker1 eth0 ]
     │
     │  oc debug node/a-cluster-worker1 -- \
     │    chroot /host tcpdump -i eth0 -n 'udp port 8472'
     │  vidíš: VXLAN enkapsulace
     │         outer: 172.18.0.11 → 172.18.0.5
     │         inner: 10.244.3.7 → 172.18.0.15
     │
     ▼
 [ a-cluster-worker5 eth0 ]  172.18.0.5   ← egress gateway / network-00
     │  Cilium SNAT: src 10.244.3.7 → 172.18.0.5
     │
     │  oc debug node/a-cluster-worker5 -- \
     │    chroot /host tcpdump -i eth0 -n 'dst 172.18.0.15'
     │  vidíš: SYN src=172.18.0.5 dst=172.18.0.15:80
     │         zdrojová IP je vždy worker5 (deterministic SNAT)
```

---

### E2E Cross-cluster: a-cluster team-alpha → b-cluster hello pod

Celá cesta od zdrojového podu v a-cluster až po cílový pod v b-cluster, včetně všech NAT operací.

```
 A-CLUSTER
 ══════════════════════════════════════════════════════

 [ team-alpha pod eth0 ]  10.244.3.7   (running on a-cluster-worker1)
     │  gen-external: curl http://172.18.0.15:80
     │
     │  oc debug node/a-cluster-worker1 -- chroot /host bash -c '
     │    PID=$(crictl inspect \
     │      $(crictl ps -q --name gen-external) | jq .info.pid)
     │    nsenter -t $PID -n -- tcpdump -i eth0 -n'
     │  vidíš: SYN src=10.244.3.7 dst=172.18.0.15:80
     │         aplikace posílá na b-cluster přímo, bez vědomí o SNAT
     │
     ▼
 [ Cilium eBPF — EgressGatewayPolicy (team-alpha → network-00) ]
     │  paket zachycen v TC egress na veth podu
     │  → přesměrován na a-cluster-worker5 přes VXLAN
     │
     ▼
 [ a-cluster-worker1 eth0 ]  VXLAN enkapsulace
     │
     │  oc debug node/a-cluster-worker1 -- \
     │    chroot /host tcpdump -i eth0 -n 'udp port 8472'
     │  vidíš: UDP/VXLAN outer: 172.18.0.11 → 172.18.0.5
     │         inner (dekóduj -X): 10.244.3.7 → 172.18.0.15
     │
     ▼
 [ a-cluster-worker5 eth0 ]  172.18.0.5   ← egress gateway
     │  Cilium SNAT: src 10.244.3.7 → 172.18.0.5
     │  paket opouští a-cluster přes Docker bridge
     │
     │  oc debug node/a-cluster-worker5 -- \
     │    chroot /host tcpdump -i eth0 -n \
     │    'tcp and dst 172.18.0.15 and dst port 80'
     │  vidíš: SYN src=172.18.0.5 dst=172.18.0.15:80
     │         SNAT hotov — zdrojová IP je network-00

 DOCKER BRIDGE  (platforma / host)
 ══════════════════════════════════════════════════════

 [ br-kind ]  172.18.0.0/16
     │  L2 bridge spojující oba clustery
     │  !! přístupné pouze na Linux hostu
     │
     │  sudo tcpdump -i br-kind -n \
     │    'tcp and host 172.18.0.5 and host 172.18.0.15'
     │  vidíš: celou komunikaci mezi oběma clustery na L2
     │         src MAC = worker5 NIC, dst MAC = b-cluster-worker5 NIC

 B-CLUSTER
 ══════════════════════════════════════════════════════

 [ b-cluster-worker5 eth0 ]  172.18.0.15
     │  přijímá paket na hostPort:80 = HAProxy shard-1
     │
     │  oc debug node/b-cluster-worker5 -- \
     │    chroot /host tcpdump -i eth0 -n port 80
     │  vidíš: SYN src=172.18.0.5, dst=172.18.0.15:80
     │         b-cluster vidí vždy stejnou src IP (team-alpha)
     │         kdybys viděl různé src IPs → team-gamma (no policy)
     │
     ▼
 [ HAProxy shard-1 — b-cluster ]
     │  Ingress route: Host header → hello.team-alpha.svc
     │
     │  oc debug node/b-cluster-worker5 -- chroot /host bash -c '
     │    PID=$(crictl inspect \
     │      $(crictl ps -q --name haproxy) | jq .info.pid)
     │    nsenter -t $PID -n -- tcpdump -i eth0 -n port 80'
     │  vidíš: příchozí z 172.18.0.5, odchozí na ClusterIP hello svc
     │
     ▼
 [ Cilium eBPF — DNAT (b-cluster) ]
     │  ClusterIP hello svc → b-cluster hello pod IP
     │
     ▼
 [ vethXXXXXX na b-cluster-worker5 ]
     │
     │  oc debug node/b-cluster-worker5 -- chroot /host bash -c '
     │    PID=$(crictl inspect \
     │      $(crictl ps -q --name hello) | jq .info.pid)
     │    IFIDX=$(nsenter -t $PID -n -- \
     │      cat /sys/class/net/eth0/iflink)
     │    VETH=$(ip link | awk -F": " "/^${IFIDX}:/{print \$2}")
     │    tcpdump -i $VETH -n'
     │  vidíš: DNAT hotov, dst=b-cluster hello pod IP
     │
     ▼
 [ b-cluster hello pod eth0 ]
     │
     │  oc debug node/b-cluster-worker5 -- chroot /host bash -c '
     │    PID=$(crictl inspect \
     │      $(crictl ps -q --name hello) | jq .info.pid)
     │    nsenter -t $PID -n -- tcpdump -i eth0 -n'
     │  vidíš: src=172.18.0.5 (a-cluster network-00)
     │         HTTP GET /, odpověď 200 OK
     │
     ▼
 [ nginx — HTTP 200 OK → zpět po stejné cestě ]
```

---

### Přehled capture pointů

```
 INTERFACE          KDE                SMĚR     VIDÍŠ
 ─────────────────────────────────────────────────────────────────────────────
 eth0 (pod)         pod netns          ↕ obojí  odchozí: co app posílá, dst=ClusterIP/peer IP
                                                příchozí: po DNAT, dst=pod IP

 lo (pod)           pod netns          ↕ obojí  jen localhost: sidecar↔kontejner 127.0.0.1
                                                !! veth toto nevidí vůbec

 vethXXXXXX         node netns         ↕ obojí  identické co pod eth0 (druhý konec stejného kabelu)
 (node strana)                                  dostupné bez nsenter — jeden veth = jeden pod

 eth0 (node)        node netns         ↕ obojí  odchozí: SNAT provoz (egress-gw), VXLAN outer
                                                příchozí: z LB/port-forward, VXLAN od jiných nodů
                                                hostPort traffic v obou směrech

 lo (node)          node netns         ↕ obojí  jen localhost: kubelet↔apiserver, healthchecky
                                                pod-to-node přes 127.0.0.1

 cilium_host        node netns         ↕ obojí  odchozí: node stack → pod CIDR
                                                příchozí: pod CIDR → node stack

 cilium_vxlan       node netns         ↕ obojí  odchozí: inner pakety před zabalením do VXLAN
 nebo geneve0                                   příchozí: rozbalené inner pakety z jiných nodů
                                                bez outer VXLAN hlaviček — čisté pod IPs

 any (v node netns) node netns         ↕ obojí  eth0 + všechny veth* + lo + cilium_*
                                                = veškerý provoz nodu vč. všech podů
                                                pozor: pakety se duplikují (eth0 + veth + vxlan)

 any (v pod netns)  pod netns          ↕ obojí  eth0 + lo tohoto podu
                                                = jen provoz tohoto konkrétního podu
 ─────────────────────────────────────────────────────────────────────────────
 KIND SPECIFIC

 lo0 (macOS host)   host               ↕ obojí  port-forward traffic (127.0.0.2/3 → kubectl tunel)

 br-kind            host (Linux only)  ↕ obojí  L2 mezi všemi Kind nody, cross-cluster komunikace
 ─────────────────────────────────────────────────────────────────────────────
```

**`any` závisí na network namespace:**

```
 node netns (oc debug node)     →  any = eth0 + veth* (všechny pody) + cilium_* + lo
 pod netns  (nsenter -t PID -n) →  any = eth0 + lo tohoto podu pouze
```

**NAT a směr — co vidíš kde:**

```
 ODCHOZÍ (app → ven):
   pod eth0 / veth  →  src=pod IP,  dst=ClusterIP        před DNAT
   node eth0        →  src=pod IP,  dst=pod IP            po DNAT
                       src=node IP, dst=peer              po SNAT (egress-gw)

 PŘÍCHOZÍ (odpověď → app):
   node eth0        →  src=pod IP,  dst=pod IP            před reverse DNAT
   veth / pod eth0  →  src=pod IP,  dst=pod IP            po reverse DNAT
```

### Quick reference — příkazy

```
 LEVEL              PŘÍKAZ
 ──────────────────────────────────────────────────────────────────────────────
 macOS lo0          sudo tcpdump -i lo0 -n 'host 127.0.0.2 or host 127.0.0.3'

 node eth0          oc debug node/<node> -- \
                      chroot /host tcpdump -i eth0 -n [filter]

 node any           oc debug node/<node> -- \
                      chroot /host tcpdump -i any -n [filter]

 node veth          oc debug node/<node> -- chroot /host bash -c '
 (pod uplink)         PID=$(crictl inspect \
                        $(crictl ps -q --name <app>) | jq .info.pid)
                      IFIDX=$(nsenter -t $PID -n -- \
                        cat /sys/class/net/eth0/iflink)
                      VETH=$(ip link | awk -F": " "/^${IFIDX}:/{print \$2}")
                      tcpdump -i $VETH -n'

 pod eth0           oc debug node/<node> -- chroot /host bash -c '
 (bez exec do podu)   PID=$(crictl inspect \
                        $(crictl ps -q --name <app>) | jq .info.pid)
                      nsenter -t $PID -n -- tcpdump -i eth0 -n'

 pod lo             oc debug node/<node> -- chroot /host bash -c '
 (sidecar traffic)    PID=$(crictl inspect \
                        $(crictl ps -q --name <app>) | jq .info.pid)
                      nsenter -t $PID -n -- tcpdump -i lo -n'

 pod any            oc debug node/<node> -- chroot /host bash -c '
 (eth0 + lo podu)     PID=$(crictl inspect \
                        $(crictl ps -q --name <app>) | jq .info.pid)
                      nsenter -t $PID -n -- tcpdump -i any -n'

 VXLAN tunnel       oc debug node/<node> -- \
 (cross-node)         chroot /host tcpdump -i eth0 -n 'udp port 8472'

 cilium_vxlan       oc debug node/<node> -- \
 (inner pakety)       chroot /host tcpdump -i cilium_vxlan -n

 Docker bridge      sudo tcpdump -i br-kind -n            # Linux host only
```

**Proč `lo` nejde chytit přes veth:**

```
┌─ pod netns ──────────────────────────────────────────────┐
│                                                          │
│  gen-cross ──lo:127.0.0.1──> nginx                      │  ← veth NEVIDÍ
│                                                          │
│  gen-cross ──eth0────────────────────────────────────────┼──> vethXXX
│                                                          │  ← veth VIDÍ
└──────────────────────────────────────────────────────────┘
```

Příklad: v `hello` podu komunikuje `gen-cross` sidecar s nginx přes `127.0.0.1:8080` — tohle je viditelné **pouze** přes `nsenter ... tcpdump -i lo`.

---

## Vantage Points

### 1. Pod network namespace

Captures traffic as seen by the application — before any eBPF NAT. Shows the real destination IP the app used (ClusterIP, peer IP), not what the packet carries after DNAT.

```bash
NODE=$(kubectl --kubeconfig a-cluster.kubeconfig \
  get pod -n team-alpha -l app=traffic-monitor \
  -o jsonpath='{.items[0].spec.nodeName}')

oc debug node/$NODE -- chroot /host bash -c '
  PID=$(crictl inspect \
    $(crictl ps -q --name gen-external) | jq .info.pid)
  nsenter -t $PID -n -- tcpdump -i eth0 -n tcp'
```

**Co vidíš**: DNS queries na kube-dns, TCP SYN na ClusterIP (před DNAT), RST z blackhole service (ClusterIP bez endpointů).

---

### 2. Worker node — po eBPF DNAT

Po Cilium DNAT jsou ClusterIP adresy nahrazeny skutečnými pod IP. Toto je první místo kde vidíš reálné pod-to-pod flows.

```bash
# Veškerý TCP port 80 na nodu
oc debug node/a-cluster-worker1 -- \
  chroot /host tcpdump -i any -n tcp port 80

# Filtr na konkrétní pod (zjisti IP nejdřív)
POD_IP=$(kubectl --kubeconfig a-cluster.kubeconfig -n team-alpha \
  get pod -l app=traffic-monitor -o jsonpath='{.items[0].status.podIP}')
oc debug node/a-cluster-worker1 -- \
  chroot /host tcpdump -i any -n host $POD_IP

# DNS od všech podů na nodu
oc debug node/a-cluster-worker1 -- \
  chroot /host tcpdump -i any -n udp port 53
```

**Co vidíš**: pod-to-pod TCP po DNAT, DNS queries a odpovědi. ClusterIP se zde nevyskytují — jen pod IP.

---

### 3. Network node — ingress (shard-1 na worker5)

Veškerý příchozí provoz pro `team-alpha` a `traffic-alpha` vstupuje přes eth0 worker5.

```bash
# Veškerý port 80 na ingress nodu
oc debug node/a-cluster-worker5 -- \
  chroot /host tcpdump -i eth0 -n tcp port 80

# HTTP dekódování přes tshark
oc debug node/a-cluster-worker5 -- chroot /host bash -c '
  tshark -i eth0 -f "tcp port 80" -Y "http.request" \
    -T fields \
    -e frame.time_relative \
    -e ip.src \
    -e ip.dst \
    -e http.host \
    -e http.request.uri \
    -e http.request.method 2>/dev/null'

# HAProxy access log
kubectl --kubeconfig a-cluster.kubeconfig logs -n haproxy-system \
  -l "app.kubernetes.io/name=kubernetes-ingress,app.kubernetes.io/instance=haproxy-shard-1" -f
```

**Co vidíš**: příchozí port-forward spojení, HAProxy proxying na pod IP, odchozí egress provoz z team-alpha podů SNATovaný na IP worker5.

---

### 4. Network node — egress gateway (SNAT bod)

Nejinformativnější capture pro demonstraci CiliumEgressGateway. Veškerý external provoz z `team-alpha` opouští cluster přes worker5 bez ohledu na to, na kterém workeru pod běží.

```bash
# Egress provoz na network-00 (team-alpha gateway)
oc debug node/a-cluster-worker5 -- \
  chroot /host tcpdump -i eth0 -n \
  'tcp and not dst net 10.0.0.0/8 and not dst net 192.168.0.0/16'

# Na network-01 (team-beta gateway)
oc debug node/a-cluster-worker6 -- \
  chroot /host tcpdump -i eth0 -n \
  'tcp and not dst net 10.0.0.0/8 and not dst net 192.168.0.0/16'

# Na běžném workeru (team-gamma — nedeterministická zdrojová IP)
oc debug node/a-cluster-worker2 -- \
  chroot /host tcpdump -i eth0 -n \
  'tcp and not dst net 10.0.0.0/8'
```

**alpha/beta**: veškerý cross-cluster TCP se vždy objeví zde se src=IP network nodu.
**gamma**: cross-cluster TCP se objeví na tom workeru, kde pod právě běží — src IP se mění s každým reschedulingem.

---

### 5. Docker bridge — cross-cluster provoz

Docker bridge `br-kind` přenáší veškerou komunikaci mezi oběma clustery.

```bash
# Najdi název bridge interface
BRIDGE=$(docker network ls --filter name=kind --format '{{.ID}}' | head -1 | cut -c1-12)
echo "Bridge: br-$BRIDGE"

# Veškerý cross-cluster HTTP (pouze Linux host)
sudo tcpdump -i br-$BRIDGE -n tcp port 80

# Dekódování přes tshark — zobraz Host header
sudo tshark -i br-$BRIDGE -f 'tcp port 80' \
  -Y 'http.request' \
  -T fields \
  -e frame.time_relative \
  -e ip.src \
  -e ip.dst \
  -e http.host \
  -e http.request.method

# Jen SYN pakety — sleduj navazování spojení
sudo tcpdump -i br-$BRIDGE -n -tttt \
  'tcp port 80 and (tcp[tcpflags] & tcp-syn != 0)'
```

**Co vidíš**: TCP spojení mezi cluster Docker IP. Zdrojová IP prozrazuje, který network node slouží jako egress gateway — `172.18.A.5` pro alpha, `172.18.A.6` pro beta, variabilní pro gamma.

---

## Side-by-side: alpha vs gamma egress

Spusť ve třech terminálech současně — vidíš SNAT rozdíl živě.

**Terminál 1** — worker5: jen team-alpha egress se objeví zde
```bash
oc debug node/a-cluster-worker5 -- \
  chroot /host tcpdump -i eth0 -n \
  'tcp dst port 80 and not src net 10.0.0.0/8'
```

**Terminál 2** — najdi a sleduj gamma worker
```bash
GAMMA_NODE=$(kubectl --kubeconfig a-cluster.kubeconfig \
  get pod -n team-gamma -l app=traffic-external \
  -o jsonpath='{.items[0].spec.nodeName}')
oc debug node/$GAMMA_NODE -- \
  chroot /host tcpdump -i eth0 -n \
  'tcp dst port 80 and not src net 10.0.0.0/8'
```

**Terminál 3** — Hubble UI: `http://localhost:12000`, záložka Service Map.

V Hubble: team-alpha flows zobrazí `worker5` jako intermediate hop (egress gateway verdict). team-gamma flows nemají egress gateway — paket odchází přímo z workeru podu.

---

## Hubble UI filters

| Co sledovat | Filtr |
|-------------|-------|
| Veškerý team-alpha provoz | Namespace: `team-alpha` |
| Egress-gateway verdicts | Verdict: `FORWARDED`, destination mimo pod CIDR |
| TCP RST z blackhole | Verdict: `DROPPED`, destination service: `blackhole` |
| Cross-cluster flows | Destination IP: b-cluster Docker subnet (`172.18.x.x`) |
| DNS queries | Destination port: `53` |
| Ingress z HAProxy | Source: HAProxy pod IP, Destination namespace: `team-alpha` |
| 404 chaos requests | HTTP response code (pokud je L7 policy povolena) |

---

## kubectl log streams

```bash
# team-alpha generátory — raw output
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

# Cilium agent logs (egress-gw rozhodnutí)
kubectl --kubeconfig a-cluster.kubeconfig logs -n kube-system \
  -l k8s-app=cilium -c cilium-agent -f | grep -i egress
```

---

## Uložení pcap pro Wireshark

```bash
# Zachyť na nodu a ulož do souboru
oc debug node/a-cluster-worker5 -- chroot /host bash -c '
  tcpdump -i eth0 -n -w /tmp/cap.pcap tcp port 80 &
  sleep 30
  kill %1'

# Zkopíruj z node debug podu na host
# (oc debug pod zůstane aktivní — otevři druhý terminál)
kubectl cp <debug-pod>:/host/tmp/cap.pcap ./capture.pcap
# Otevři v Wireshark na hostu
open ./capture.pcap
```

---

## Co se změní po restartu team-gamma podu

```bash
# Před restartem: zaznamenej aktuální worker a src IP na b-clusteru
kubectl --kubeconfig a-cluster.kubeconfig get pod -n team-gamma \
  -l app=traffic-external -o wide

# Sleduj SYN pakety na b-cluster-worker5
oc debug node/b-cluster-worker5 -- \
  chroot /host tcpdump -i eth0 -n \
  'tcp port 80 and tcp[tcpflags] & tcp-syn != 0' &

# Restartuj pod
kubectl --kubeconfig a-cluster.kubeconfig rollout restart \
  -n team-gamma deploy/traffic-external

# Sleduj: src IP v b-cluster capture se změní pokud pod přistane na jiném workeru
kubectl --kubeconfig a-cluster.kubeconfig get pod -n team-gamma \
  -l app=traffic-external -o wide -w
```

Pro team-alpha opakuj stejný test — src IP na b-clusteru se NEZMĚNÍ bez ohledu na to, na který worker pod přistane. To je garance egress gateway.

---

## kube-dump.sh — hromadné zachytávání

`tools/kube-dump.sh` spustí debug pod vedle každého vybraného podu a provede příkaz uvnitř jeho síťového namespace přes nsenter — bez nutnosti `kubectl exec` nebo privilegovaného kontejneru.

Defaultní image je `nicolaka/netshoot` (obsahuje tcpdump, tshark, strace, ss, ip, curl, …).

Zástupné znaky v příkazech:
- `%t` — název cílového podu nebo nodu
- `%n` — název nodu kde pod běží
- `%f` — cesta k nahranému souboru (po `--import-file`)

Vždy nastav kubeconfig před spuštěním:
```bash
export KUBECONFIG=$(pwd)/a-cluster.kubeconfig
```

---

### Příklad 1 — jeden label, všechny namespace

Zachytí provoz ze všech `traffic-external` podů najednou (team-alpha, team-beta, team-gamma):

```bash
export KUBECONFIG=$(pwd)/a-cluster.kubeconfig

./tools/kube-dump.sh \
  -l app=traffic-external \
  -e 'tcpdump -i any -nn -s 0 -w /tmp/%t.pcap' \
  -s 'ls /tmp/%t.pcap' \
  -o ./captures/external-all \
  --kill-switch-abs 50MB \
  --install-deps
```

Výstup v `captures/external-all/`:
```
traffic-external-xxx-team-alpha-command-0.log
traffic-external-xxx-team-beta-command-0.log
traffic-external-xxx-team-gamma-command-0.log
traffic-external-xxx-team-alpha.pcap
...
```

---

### Příklad 2 — více labelů z různých namespace (OR logika)

Zachytí provoz z `traffic-external` i `hello` podů zároveň — různé aplikace, různé namespace:

```bash
export KUBECONFIG=$(pwd)/a-cluster.kubeconfig

./tools/kube-dump.sh \
  -l app=traffic-external \
  -l app=hello \
  -e 'tcpdump -i any -nn -s 0 -c 200 -w /tmp/%t.pcap' \
  -s 'ls /tmp/%t.pcap' \
  -o ./captures/multi-label \
  --kill-switch-abs 100MB \
  --install-deps
```

Každý `-l` je OR — skript najde pody splňující ANY selektor. V tomto případě 6 podů (3× traffic-external + 3× hello).

---

### Příklad 3 — network nody + tshark (HTTP dekódování)

Worker5 a worker6 mají label `node-role=network` a hostují HAProxy. tshark na jejich `eth0` vidí veškerý ingress/egress:

```bash
export KUBECONFIG=$(pwd)/a-cluster.kubeconfig

./tools/kube-dump.sh \
  -L node-role=network \
  -E 'tshark -i eth0 -f "tcp port 80" -T fields \
    -e frame.time_relative \
    -e ip.src \
    -e ip.dst \
    -e http.request.method \
    -e http.request.uri \
    -e http.response.code \
    2>/dev/null | tee /tmp/%t-http.log' \
  -S 'ls /tmp/%t-http.log' \
  -o ./captures/network-nodes \
  --install-deps
```

Pro pcap místo live výpisu:
```bash
./tools/kube-dump.sh \
  -L node-role=network \
  -E 'tshark -i eth0 -f "tcp port 80" -w /tmp/%t.pcap' \
  -S 'ls /tmp/%t.pcap' \
  -o ./captures/network-nodes \
  --kill-switch-abs 200MB \
  --install-deps
```

---

### Příklad 4 — include-nodes, více -e a -E, import skriptu

Zachytí síťový provoz v podu (nsenter → pod netns) a zároveň na nodu který pod hostuje — dvě různé vantage points najednou.

Nejprve vytvoř lokální skript pro node-side diagnostiku:

```bash
cat > /tmp/node-egress-check.sh << 'EOF'
#!/bin/sh
echo "=== $(hostname) ==="
echo "--- routing ---"
ip route show
echo "--- active TCP (dst :80) ---"
ss -tun dst :80
echo "--- last 30 SYN on eth0 ---"
tcpdump -i eth0 -nn -c 30 'tcp[tcpflags] & tcp-syn != 0 and dst port 80' 2>/dev/null
EOF
```

Spusť:
```bash
export KUBECONFIG=$(pwd)/a-cluster.kubeconfig

./tools/kube-dump.sh \
  -l app=traffic-external \
  -e 'tcpdump -i eth0 -nn -s 0 -w /tmp/%t-pod.pcap' \
  -e 'ss -tunap > /tmp/%t-sockets.txt' \
  --include-nodes \
  --import-file /tmp/node-egress-check.sh \
  -E 'bash %f | tee /tmp/%t-node-diag.log' \
  -E 'tcpdump -i eth0 -nn -s 0 -w /tmp/%t-node.pcap tcp port 80' \
  -s 'ls /tmp/%t-pod.pcap /tmp/%t-sockets.txt' \
  -S 'ls /tmp/%t-node-diag.log /tmp/%t-node.pcap' \
  -o ./captures/egress-debug \
  --kill-switch-abs 200MB \
  --install-deps
```

Co spouští:
- `-e` příkaz 0 — tcpdump uvnitř pod netns (nsenter → `eth0` podu)
- `-e` příkaz 1 — `ss` uvnitř pod netns (aktivní TCP spojení)
- `--include-nodes` — automaticky zahrne worker nody kde pody běží
- `-E` příkaz 0 — importovaný skript na nodu (routing + ss + SYN capture)
- `-E` příkaz 1 — tcpdump na `eth0` nodu (vidí SNAT/masquerade výstup)

---

### Příklad 5 — strace síťových syscallů (s import-file)

Vstoupí do PID i network namespace cílového podu a trasuje `connect`, `sendto`, `recvfrom` pro každý proces v kontejneru.

```bash
cat > /tmp/strace-net.sh << 'EOF'
#!/bin/sh
# Mount /proc aby strace viděl PIDs v cílovém PID namespace
mount -t proc none /proc 2>/dev/null
OUTDIR=/tmp/strace
mkdir -p $OUTDIR
# Spusť strace pro každý proces v kontejneru
for pid in $(ls /proc | grep -E '^[0-9]+$'); do
  [ -d /proc/$pid/fd ] || continue
  strace -f -p $pid \
    -e trace=network \
    -e signal=none \
    -o $OUTDIR/$pid.strace \
    2>/dev/null &
done
sleep 30
kill $(jobs -p) 2>/dev/null
wait
EOF
```

```bash
export KUBECONFIG=$(pwd)/a-cluster.kubeconfig

./tools/kube-dump.sh \
  -l app=traffic-external \
  -n team-gamma \
  --import-file /tmp/strace-net.sh \
  -e 'bash %f' \
  --nsenter-params n,p \
  -s 'ls /tmp/strace/*.strace' \
  -o ./captures/strace-gamma \
  --install-deps \
  --no-cleanup
```

`--nsenter-params n,p` — vstoupí do **network** i **PID** namespace podu. `--no-cleanup` nechá debug pod běžet pro případnou inspekci logů.

Výstup: soubory `NNN.strace` pro každý PID v kontejneru, obsahují volání jako:
```
connect(5, {sa_family=AF_INET, sin_port=htons(80), sin_addr=inet_addr("172.18.0.15")}, 16) = 0
sendto(5, "GET / HTTP/1.1\r\nHost: ...", ...)
recvfrom(5, "HTTP/1.1 200 OK\r\n...", ...)
```
