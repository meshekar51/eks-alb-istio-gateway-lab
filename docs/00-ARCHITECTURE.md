# Architecture

## The 30-second analogy

Think of a request as a **parcel delivered to someone in a big office building**.

| Real thing | Analogy |
|---|---|
| Route 53 record (ExternalDNS) | the address in the phone book |
| ALB + ACM certificate | the city sorting centre: checks the parcel is genuine (TLS), then trucks it to the building |
| Istio edge Gateway (Envoy) | the building's reception desk |
| HTTPRoute | reception's routing sheet: "parcels for *shop*, marked *canary*, go to floor 2" |
| Service / EndpointSlice | the current staff list of a department |
| Pod | the person |
| Mesh mTLS (sidecar or ztunnel) | sealed internal envelopes with verified ID badges between floors |

Every hop is owned by a different component. **Troubleshooting = finding the first hop where the parcel stops.**

## Request path (Goal 1)

```
 Browser / curl
   │  DNS: shop.<DOMAIN>  ── Route 53 ALIAS ◄── ExternalDNS (watches the Ingress)
   ▼
 ┌──────────────────────── AWS ─────────────────────────┐
 │ ALB  (internet-facing, 2 public subnets / 2 AZs)      │ ◄── AWS Load Balancer Controller
 │   :80  → 301 redirect to :443                          │      (Ingress edge-alb, Pod Identity)
 │   :443 → TLS terminated with ACM *.<DOMAIN> cert       │
 │   target group, target-type ip, HC :15021/healthz/ready│
 └──────────────┬───────────────────────────────────────┘
                │ HTTP :80 straight to pod IPs (VPC CNI)
 ┌──────────────▼──────────── EKS ───────────────────────┐
 │ lab-gateway/edge-istio pods (Envoy) ◄── istiod deploys them from Gateway "edge"
 │   listener http:80, hostname *.<DOMAIN>, routes only from labelled namespaces
 │      │ HTTPRoute rules (lab-apps):                     │
 │      │  host  api.<DOMAIN>              → httpbin      │
 │      │  host  canary.<DOMAIN>           → podinfo-v2   │
 │      │  shop  /httpbin/* (rewrite)      → httpbin      │
 │      │  shop  /v2 (rewrite)             → podinfo-v2   │
 │      │  shop  header x-canary: true     → podinfo-v2   │
 │      │  shop  ?version=v2               → podinfo-v2   │
 │      │  shop  default  weights 90 / 10  → v1 / v2      │
 │      ▼  Istio mTLS (gateway → sidecar)                 │
 │ lab-apps: podinfo-v1, podinfo-v2, httpbin  (sidecars)  │
 └────────────────────────────────────────────────────────┘
```

**Three different encryption hops — validate each separately:**

| Hop | Protocol | Proven by |
|---|---|---|
| Browser → ALB | HTTPS, ACM cert | `openssl s_client -servername shop.<DOMAIN>` / browser padlock |
| ALB → edge gateway pod | plain HTTP inside the VPC | (by design; see "Hardening" below) |
| Gateway → app pod | Istio mTLS (SPIFFE identities) | `X-Forwarded-Client-Cert` at `https://shop.<DOMAIN>/httpbin/headers` |

## Mesh labs (Goal 2)

```
 sidecar-lab   istio-injection=enabled       curl ──(Envoy ⇄ Envoy mTLS)──► httpbin
 ambient-lab   istio.io/dataplane-mode=ambient
               istio.io/use-waypoint=waypoint curl ─► ztunnel ═HBONE═► waypoint ═HBONE═► ztunnel ─► httpbin
 legacy-lab    (no mesh)                      curl ──plaintext──► …  (rejected by STRICT servers)
```

| | Sidecar | Ambient |
|---|---|---|
| Where the proxy runs | an `istio-proxy` container in every pod | `ztunnel` DaemonSet (1 per node) + optional `waypoint` per namespace/service |
| Joining the mesh | label namespace, **restart pods** | label namespace, **no restart** |
| mTLS | Envoy ⇄ Envoy | ztunnel ⇄ ztunnel over HBONE (port 15008) |
| L7 (paths, headers, retries) | always (every sidecar is L7) | only through a waypoint |
| Who enforces STRICT | server's sidecar | destination node's ztunnel |
| Evidence | `istioctl proxy-config secret`, XFCC header | `istioctl ztunnel-config workload` (HBONE), ztunnel access logs |

## Components and versions (verified 2026-10-17)

| Component | Version | Why this one |
|---|---|---|
| EKS | 1.36 | standard support until Aug 2027; Istio 1.31 supports 1.32–1.37 |
| Istio | 1.31.2 (ambient profile) | latest; one control plane serves sidecar **and** ambient |
| Gateway API CRDs | v1.6.0 standard | the version Istio 1.31 is built and documented against |
| AWS Load Balancer Controller | v3.6.0 (chart 3.6.0) | latest; Pod Identity; explicit region + VPC |
| ExternalDNS | v0.23.0 (chart 1.23.0) | Route 53 ALIAS records from the Ingress |
| Terraform / AWS provider | 1.16.6 / ~> 6.0 | plan-tested offline against provider 6.69.1 |
| podinfo | 6.14.1 = v1 "stable", 6.15.0 = v2 "canary" | real releases of the canary demo app used by Flagger |
| go-httpbin / curl | v2.15.0 / 8.16.0 | same images as Istio's samples |

## Design decisions

1. **Gateway Service is `ClusterIP`.** Istio would otherwise create a `LoadBalancer` Service → a *second* AWS load
   balancer in front of the gateway. The `infrastructure.parametersRef` ConfigMap overlay sets `type: ClusterIP` and
   2 replicas.
2. **`target-type: ip`.** The ALB sends traffic straight to gateway pod IPs (VPC CNI makes them VPC-routable).
   No NodePort, no kube-proxy hop, and the LBC opens exactly the ports it needs on the cluster security group.
3. **Health check on 15021 `/healthz/ready`.** Port 80 answers 404 without a matching `Host`.
4. **Pod Identity, not IRSA.** No OIDC provider. The association is `(namespace, serviceaccount) → role`; the
   credentials env var is injected at **pod creation** (restart after fixing an association!).
5. **Region and VPC are pinned** in the LBC Helm values and the install script refuses to continue otherwise.
6. **ExternalDNS uses only the `ingress` source**, filtered to one hosted zone, `policy: sync` with a TXT owner id.
7. **Every HTTPRoute rule stamps `x-lab-rule`.** You can see which rule matched from the browser dev-tools.
8. **Access logs on** for all Envoys (gateway, sidecars, waypoint). The response-flags column is the fastest clue.

## Hardening you would add in production (out of scope for the lab)

* ALB → gateway over HTTPS (`backend-protocol: HTTPS` + a cert on the Gateway listener).
* `numTrustedProxies: 1` on the gateway so Envoy uses the real client IP from `X-Forwarded-For`.
* Node IMDS hop limit 1, private-only EKS endpoint, WAF on the ALB, PodDisruptionBudgets for gateway and controllers.
* `require-waypoint` AuthorizationPolicy so L7 policy cannot be bypassed (see docs/03).
