# Investigační tickety

Ukázky reálných šetření zachycených na úrovni nodu pomocí `oc debug node` + `nsenter`. Každý ticket ukazuje jiný typ provozu a jiné capture místo.

---

## TICKET-4471 · team-gamma · Priorita: High

**Název:** Intermittentní connection refused na b-cluster — po restartu podu

**Nahlásil:** Martin K., backend developer, team-gamma

---

**Popis problému**

> Ahoj, máme problém s `traffic-external` v `team-gamma`. Aplikace občas přestane dosahovat na b-cluster a vrací connection refused. Stane se to vždy někdy po deploymentu nebo restartu podu. Pár minut to funguje, pak přestane. Team-alpha a team-beta tento problém nemají. Nerozumím proč — kód je identický.
>
> — Martin, 09:14

---

**Šetření**

Nejdřív jsem se podíval kde pod aktuálně běží a odkud posílá provoz ven:

```bash
kubectl get pod -n team-gamma -l app=traffic-external -o wide
# NAME                                READY   NODE
# traffic-external-64d44786db-wdf8x   1/1     a-cluster-worker3  (172.18.0.10)
```

Zachytil jsem egress provoz přímo na worker3:

```bash
oc debug node/a-cluster-worker3 -- \
  chroot /host tcpdump -i eth0 -n \
  'tcp and dst port 80'
# 09:21:03 IP 172.18.0.10.54821 > 172.18.0.15.80: Flags [S]   ← SYN odeslaný
# 09:21:03 IP 172.18.0.15.80 > 172.18.0.10.54821: Flags [R.]  ← RST od b-cluster
```

Zdrojová IP je `172.18.0.10` — IP worker3. Stejný příkaz na worker5 (team-alpha egress-gw):

```bash
oc debug node/a-cluster-worker5 -- \
  chroot /host tcpdump -i eth0 -n \
  'tcp and dst port 80'
# 09:21:05 IP 172.18.0.8.49302 > 172.18.0.15.80: Flags [S]
# 09:21:05 IP 172.18.0.15.80 > 172.18.0.8.49302: Flags [S.]  ← SYN-ACK, funguje
```

Team-alpha má vždy `172.18.0.8` (worker5). Team-gamma má IP toho workeru, na kterém zrovna pod běží.

Ověřil jsem v b-cluster HAProxy access logu co se děje na příjmu:

```bash
kubectl --kubeconfig b-cluster.kubeconfig logs -n haproxy-system \
  -l "app.kubernetes.io/instance=haproxy-shard-1" --tail=20
# 172.18.0.8  "GET / HTTP/1.1" 200   ← team-alpha, OK
# 172.18.0.10 "GET / HTTP/1.1" 403   ← team-gamma, zakázaná IP
```

**Root cause:** B-cluster má IP whitelist — povoluje pouze `172.18.0.8` (alpha egress-gw) a `172.18.0.4` (beta egress-gw). Team-gamma nemá `CiliumEgressGatewayPolicy`, takže egress jde přímo z workeru kde pod běží. Po každém restartu nebo reschedulingu pod přistane na jiném nodu → zdrojová IP se změní → b-cluster whitelist zahazuje spojení.

---

**Proč team-alpha a team-beta problém nemají**

| namespace | egress gateway | src IP na b-cluster | stabilní? |
|-----------|---------------|---------------------|-----------|
| team-alpha | worker5 (network-00) | `172.18.0.8` vždy | ano |
| team-beta | worker6 (network-01) | `172.18.0.4` vždy | ano |
| team-gamma | žádný | IP aktuálního workeru | ne |

---

**Řešení**

Přidat `CiliumEgressGatewayPolicy` pro team-gamma (stejný vzor jako alpha/beta) a přidat zvolenou network node IP do whitelistu na b-cluster straně.

Alternativa pokud nechceme fixovat na konkrétní node: nasadit Cilium Cluster Mesh s mTLS — pak záleží na identitě, ne na IP.

---

**Odpověď Martinovi**

> Našel jsem příčinu. Team-gamma nemá nastavenou egress gateway politiku, takže zdrojová IP se mění s každým restartem podu. B-cluster má IP whitelist který novou IP nezná a zahazuje spojení. Team-alpha a beta mají egress gateway fixovanou na konkrétní node, takže jejich IP je vždy stejná bez ohledu na to kde pod běží. Připravuju PR s egress policy pro team-gamma.

---

## TICKET-4489 · team-alpha · Priorita: Medium

**Název:** Aplikace hlásí chyby `connection refused` v logu — je to síťový problém?

**Nahlásil:** Jana P., SRE, team-alpha

---

**Popis problému**

> V logu `traffic-monitor` vidíme záznamy `chaos → blackhole: connection refused`. Nevíme jestli je to bug v aplikaci nebo nám někdo blokuje provoz. Může se podívat?
>
> — Jana, 14:02

---

**Šetření**

Zkontroloval jsem log:

```bash
kubectl logs -n team-alpha deploy/traffic-monitor -c gen-chaos --tail=10
# [14:01:49] chaos → blackhole.team-alpha: connection refused
# [14:01:56] chaos → http://haproxy-shard-1/chaos-not-found: 404
# [14:02:03] chaos → http://haproxy-shard-1/: 200
```

`connection refused` = curl dostal TCP RST — spojení odmítnuto před HTTP handshake. Zachytil jsem na nodu kde `traffic-monitor` běží (worker2):

```bash
oc debug node/a-cluster-worker2 -- \
  chroot /host tcpdump -i any -n \
  'host 10.244.9.43 and tcp[tcpflags] & tcp-rst != 0'
# 14:01:49 IP 10.244.9.43.39812 > 10.96.x.x.80: Flags [S]
# 14:01:49 IP 10.96.x.x.80    > 10.244.9.43.39812: Flags [R.]
```

SYN → RST bez SYN-ACK. Žádný třícestný handshake, žádný timeout — RST přišel okamžitě.

Ověřil jsem endpointy blackhole service:

```bash
kubectl get endpoints blackhole -n team-alpha
# NAME        ENDPOINTS   AGE
# blackhole   <none>      2d
```

**Root cause:** Záměrné chování. `blackhole` service nemá žádné endpointy — selektor `app=blackhole-nonexistent` záměrně neodpovídá žádnému podu. Cilium na to reaguje okamžitým TCP RST bez čekání na timeout. `connection refused` je správná odpověď curl na TCP RST. Nejde o síťový problém ani bug.

---

**Odpověď Janě**

> Není to bug ani blokování. Blackhole service je záměrně nasazená bez podů — slouží k demonstraci jak Cilium reaguje na provoz na service bez endpointů. Místo timeoutu posílá okamžitý TCP RST, proto curl hlásí `connection refused`. Gen-chaos to dělá každých ~42 sekund jako součást chaos traffic patternu. V Hubble UI to vidíš jako `DROPPED` flow s důvodem `no endpoints`.
