# Goal 2 — mTLS: sidecar mode vs ambient mode

## Analogy
* **Sidecar** = every employee has a personal bodyguard who seals and checks every envelope. Very capable
  (reads the letter: paths, headers, retries), but you pay for one bodyguard per person, and a new hire only gets
  one when they *start* (pod restart).
* **Ambient** = one security desk per floor (**ztunnel**, per node) that seals every envelope in an armoured tube
  (**HBONE** = mTLS tunnel on port 15008). It checks *who* sends (identity) but does not read the letter. If you need
  someone to read letters (L7 policy, header routing), you add a **waypoint** — a shared mail-room for a department.

## What the lab deploys

| Namespace | Label | Pods | Proxy |
|---|---|---|---|
| sidecar-lab | `istio-injection=enabled` | httpbin (server), curl (client) | `istio-proxy` in each pod |
| ambient-lab | `istio.io/dataplane-mode=ambient`, `istio.io/use-waypoint=waypoint` | httpbin, curl, waypoint | ztunnel on each node + `waypoint` Envoy |
| legacy-lab | none | httpbin, curl | none (plaintext) |

## Run it

```bash
make test-mtls       # Phase A PERMISSIVE matrix, Phase B STRICT matrix, identity proofs
make test-waypoint   # L7 DENY on /forbidden via waypoint
```

Expected matrix (cells: `200+XFCC` = HTTP 200 and the server saw a client certificate, `RESET` = connection refused
by the mesh before HTTP happened):

| client ↓ / server → | sidecar-lab | ambient-lab | legacy-lab |
|---|---|---|---|
| **PERMISSIVE** sidecar | 200+XFCC | 200 | 200 |
| ambient | 200 (HBONE) | 200 | 200 |
| legacy | 200 (plaintext, no XFCC) | 200 (plaintext) | 200 |
| **STRICT** sidecar | 200+XFCC | 200 | 200 |
| ambient | 200 | 200 | 200 |
| legacy | **RESET** | **RESET** | 200 |

Key lesson: **under PERMISSIVE an HTTP 200 proves nothing about encryption.** Prove mTLS with identities.

## Proving mTLS — sidecar

```bash
# 1. the server's sidecar adds the client identity it verified
kubectl exec -n sidecar-lab deploy/curl -c curl -- curl -s http://httpbin.sidecar-lab:8000/headers | jq '.headers["X-Forwarded-Client-Cert"]'
#    "By=spiffe://cluster.local/ns/sidecar-lab/sa/httpbin;Hash=…;Subject=\"\";URI=spiffe://cluster.local/ns/sidecar-lab/sa/curl"
# 2. the client's Envoy holds a valid workload certificate
istioctl proxy-config secret deploy/curl -n sidecar-lab
# 3. the client's Envoy uses ISTIO_MUTUAL towards the server
istioctl proxy-config cluster deploy/curl -n sidecar-lab --fqdn httpbin.sidecar-lab.svc.cluster.local -o json | jq '.[0].transportSocketMatches[0].name'
# 4. effective policy for the server
istioctl x describe pod $(kubectl get pod -n sidecar-lab -l app=httpbin -o jsonpath='{.items[0].metadata.name}').sidecar-lab
# 5. is everything synced?
istioctl proxy-status
```

## Proving mTLS — ambient

```bash
# 1. enrolled? PROTOCOL must be HBONE
istioctl ztunnel-config workload | awk 'NR==1 || $1=="ambient-lab"'
# 2. which waypoint serves the Service?
istioctl ztunnel-config service | awk 'NR==1 || $1=="ambient-lab"'
# 3. identities in ztunnel access logs
kubectl exec -n ambient-lab deploy/curl -- curl -s http://httpbin.ambient-lab:8000/get >/dev/null
kubectl logs -n istio-system -l app=ztunnel --since=1m | grep 'ns/ambient-lab/sa/curl'
#    … src.identity="spiffe://cluster.local/ns/ambient-lab/sa/curl" dst.identity="…/sa/waypoint" … dst.hbone_addr=…
# 4. ztunnel certificates
istioctl ztunnel-config certificate $(kubectl get pod -n istio-system -l app=ztunnel -o jsonpath='{.items[0].metadata.name}').istio-system
# 5. what policy ztunnel enforces (L4)
istioctl ztunnel-config policy
```
Optional wire proof: SSM into a worker node (`AmazonSSMManagedInstanceCore` is on the node role) and
`sudo tcpdump -nAi any port 15008` — you see TLS, never the HTTP text.

## Waypoint (ambient L7)

```bash
kubectl get gateway waypoint -n ambient-lab           # gatewayClassName istio-waypoint, Programmed=True
kubectl get ns ambient-lab -L istio.io/use-waypoint   # must NAME an existing waypoint
kubectl exec -n ambient-lab deploy/curl -- curl -s -o /dev/null -w '%{http_code}\n' http://httpbin.ambient-lab:8000/forbidden   # 403
kubectl logs -n ambient-lab deploy/waypoint --tail=5  # access log line with 403 + RBAC details
```
Rules:
* `targetRefs: Service` / `Gateway` → enforced by the **waypoint** (L7 allowed).
* `selector:` → enforced by **ztunnel** (L4 only). L7 conditions there **fail closed** (scenario 08).
* If `istio.io/use-waypoint` names a waypoint that does not exist, ztunnel sends traffic **directly** — L7 policy
  silently stops applying (messy fault). Make the waypoint mandatory with an L4 ALLOW policy:

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata: { name: require-waypoint, namespace: ambient-lab }
spec:
  selector: { matchLabels: { app: httpbin } }
  action: ALLOW
  rules:
    - from: [{ source: { principals: ["cluster.local/ns/ambient-lab/sa/waypoint"] } }]
```

## Interop facts (all exercised by the tests)
* Sidecar ⇄ ambient works in both directions in one mesh (sidecars speak HBONE when ambient is installed).
* The edge gateway (`lab-gateway`) is itself an Envoy: gateway → sidecar pods is mTLS (see the XFCC header on
  `https://shop.<DOMAIN>/httpbin/headers`).
* Ingress traffic to an ambient Service does **not** pass its waypoint unless the Service/namespace has
  `istio.io/ingress-use-waypoint=true`.
* A namespace must have **one** data-plane label. If both, sidecar wins (scenario 09).
