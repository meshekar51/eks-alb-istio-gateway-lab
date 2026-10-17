# From your notes to this lab

You shared two repos: **istio-guide** (Bookinfo, VirtualService/DestinationRule, PeerAuthentication) and
**kubernetes-gateway-api** (Envoy Gateway tutorial: basic route, URL rewrite, traffic splitting, weighted 8/2).
Here is where each idea lives in this lab and what changed.

## kubernetes-gateway-api → this lab

| Your file | What it did | Here |
|---|---|---|
| `00-install` Envoy Gateway Helm (`gatewayClassName: eg`) | Envoy Gateway as the controller | **Istio** is the controller (`gatewayClassName: istio`); same Gateway API objects |
| `01-basic-deploy/gateway.yaml` | Gateway listener :80 | `k8s/gateway/edge-gateway.yaml` (+ hostname `*.<DOMAIN>`, `allowedRoutes` by namespace label, ClusterIP overlay) |
| `01-basic-deploy/httproute.yaml` `www.example.com → backend:3000` | host routing | `k8s/routes/api-and-canary-hosts.yaml` |
| `02-url-rewrite` `ReplacePrefixMatch: /replace` | URL rewrite | rules `path-httpbin` and `path-v2` in `k8s/routes/shop.yaml` |
| `03-traffic-spiltting` two backendRefs, no weights | equal split (default weight 1 each) | `tools/canary.sh set 50 50` |
| `04-weighted` weights 8 / 2 | 80/20 canary | `tools/canary.sh set 80 20` (weights are relative: 8/2 == 80/20) |
| `echo-basic` image (shows pod/namespace/headers) | debugging backend | podinfo (real v1/v2 releases + UI colours) and go-httpbin (`/headers` shows XFCC) |

Envoy Gateway vs Istio as the Gateway API implementation — what changes for troubleshooting:
* Controller logs: `envoy-gateway` → `istiod`. Data-plane: `envoy-*` pods → `<gateway>-istio` pods.
* Istio adds **mesh** features behind the gateway (mTLS to sidecars/ambient, AuthorizationPolicy, waypoints).
* `istioctl proxy-config route deploy/edge-istio -n lab-gateway` replaces `egctl config envoy-proxy route`.

## istio-guide → this lab

| Your file | What it did | Gateway API / this lab |
|---|---|---|
| `install-and-setup` (getting-started, demo profile) | sidecar install + Bookinfo | `platform/istio/istio-ambient.yaml` — **ambient** profile: sidecar *and* ambient in one mesh |
| `request-routing/01-basic.yaml` VirtualService → `subset: v1` | pin everything to v1 | `tools/canary.sh rollback` (100/0) |
| `request-routing/02-route-user-header.yaml` `end-user: jason → v2` | header routing | rule `header-canary` (`x-canary: true → v2`); add a 2nd header match the same way |
| `traffic-shifting/02-traffic-shifting.yaml` reviews v1/v3 50/50 | weighted shift | rule `weighted` + `tools/canary.sh` |
| `mTLS/tls-mode.yaml` PeerAuthentication STRICT (`v1beta1`, ns default) | STRICT | `k8s/mesh/peerauthentication-strict.yaml` (`security.istio.io/v1`) in sidecar-lab + ambient-lab |
| README: Gateways, Destination rules, Circuit breaking | concepts | Gateway API replaces Istio `Gateway`+`VirtualService` at the edge; DestinationRule still applies to traffic policy |

### Same intent, both APIs
Your header route:
```yaml
# VirtualService (istio-guide)
http:
- match: [{ headers: { end-user: { exact: jason } } }]
  route: [{ destination: { host: reviews, subset: v2 } }]
- route: [{ destination: { host: reviews, subset: v1 } }]
```
Gateway API equivalent:
```yaml
rules:
- matches: [{ headers: [{ name: end-user, value: jason }] }]   # type defaults to Exact
  backendRefs: [{ name: reviews-v2, port: 9080 }]            # a Service per version instead of subsets
- backendRefs: [{ name: reviews-v1, port: 9080 }]
```

### Things that bite when mixing the two
* **One owner per hostname.** A `VirtualService` bound to the same host as an `HTTPRoute` produces two competing
  configurations; troubleshooting becomes guesswork. In this lab only HTTPRoutes route traffic.
* `subset` needs a `DestinationRule` with labels; Gateway API needs **Services** per version.
* `apiVersion: networking.istio.io/v1alpha3` / `security.istio.io/v1beta1` still work, but `v1` is current.
* Admission controllers from your notes matter here too: the Istio sidecar injector and the AWS LBC are both
  **mutating webhooks** — when their pods are down, pod/Service creation fails (scenarios 10 and 11).
