# Goal 1 — Routing and canary with Gateway API on Istio

## Analogy
The Gateway is a receptionist with **one** routing sheet per hostname. For each parcel she looks for the
*most specific* instruction, not the first one on the page: an exact room number beats "2nd floor", a
parcel with two special labels beats one with one label.

## Where things live

| Object | Namespace | Owner | Purpose |
|---|---|---|---|
| `Gateway edge` | lab-gateway | platform | listener `http:80`, hostname `*.<DOMAIN>`, which namespaces may attach routes |
| `HTTPRoute shop / api / canary-preview` | lab-apps | app team | the routing sheets |
| `Service podinfo-v1 / podinfo-v2 / httpbin` | lab-apps | app team | one Service **per version** (weights split between Services) |

## The routing matrix (`k8s/routes/`)

| # | Host | Match | Filter | Backend | `x-lab-rule` |
|---|---|---|---|---|---|
| 1 | api.<DOMAIN> | anything | — | httpbin:8000 | `api-host` |
| 2 | canary.<DOMAIN> | anything | — | podinfo-v2:80 | `canary-host` |
| 3 | shop.<DOMAIN> | `PathPrefix /httpbin` | URLRewrite → `/` | httpbin:8000 | `path-httpbin` |
| 4 | shop.<DOMAIN> | `PathPrefix /v2` | URLRewrite → `/` | podinfo-v2:80 | `path-v2` |
| 5 | shop.<DOMAIN> | header `x-canary: true` (Exact) | — | podinfo-v2:80 | `header-canary` |
| 6 | shop.<DOMAIN> | query `version=v2` (Exact) | — | podinfo-v2:80 | `query-canary` |
| 7 | shop.<DOMAIN> | `PathPrefix /` | — | v1 **90** / v2 **10** | `weighted` |

Optional add-on `make reviews` (k8s/addons/reviews): `reviews.<DOMAIN>` → header `end-user: jason` → reviews-v2,
everything else → reviews-v1 **90** / reviews-v2 **10** — one Service per version, exactly the
ALB → Gateway pod → HTTPRoute → Service → Pod chain.

### Precedence (Gateway API spec, not file order)
1. Exact path > longest PathPrefix
2. then method match
3. then **most header matches**
4. then **most query-param matches**
5. tie across HTTPRoutes → **oldest** HTTPRoute (creationTimestamp); tie inside one route → first rule

So `curl -H 'x-canary: true' 'https://shop.<DOMAIN>/?version=v2'` matches rule 5 (header beats query), and
`/httpbin/anything` with `x-canary: true` still goes to httpbin (longer path beats headers).

### Matching gotchas you will meet
* Header **names** are case-insensitive; header **values** with `type: Exact` are case-sensitive (`True` ≠ `true`).
* `PathPrefix /v2` matches `/v2` and `/v2/x`, **not** `/v2x` (element-wise prefix).
* Without URLRewrite, the backend receives `/v2` and answers 404 itself — an *application* 404.
* `backendRefs.port` is the **Service** port (80 / 8000), never the container port (9898 / 8080).
* Route hostnames must intersect the listener hostname (`*.<DOMAIN>`), otherwise `Accepted=False NoMatchingListenerHostname`.
* A cross-namespace `backendRef` needs a `ReferenceGrant` **in the target namespace**.

## Testing from the CLI (with and without DNS)

```bash
H=shop.<DOMAIN>; ALB=$(kubectl get ingress edge-alb -n lab-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -s  https://$H/api/info | jq .version                               # via DNS
curl -s --connect-to $H:443:$ALB:443 https://$H/api/info | jq .version   # bypass DNS, SNI still correct
curl -sI https://$H/api/info | grep -i x-lab-rule                         # which rule matched
curl -s -H 'x-canary: true'  https://$H/api/info | jq -r .version         # header
curl -s 'https://'$H'/api/info?version=v2' | jq -r .version               # query
curl -s https://$H/v2 | jq -r .version                                    # path
curl -s https://$H/httpbin/headers | jq '.headers["X-Forwarded-Client-Cert"]'
curl -s https://api.<DOMAIN>/headers | jq .headers.Host                   # host
```
Never use `-H 'Host: …'` against `https://<alb-dns>`: TLS SNI would be the ALB name and the cert would not match.
`--connect-to` keeps SNI + Host = the real hostname.

## Browser notes
* `https://shop.<DOMAIN>/` → the podinfo UI loads, then calls `/api/info`. **Each** call is routed independently,
  so the page shell and the data can come from different versions. That is why the stable "preview" is a separate
  host (`canary.<DOMAIN>`): every follow-up request stays on v2. Real canaries pin a user with a cookie or header.
* To test the query rule in a browser use the JSON endpoint: `https://shop.<DOMAIN>/api/info?version=v2`.
* Dev-tools → Network → any request → Response Headers → `x-lab-rule`.

## Canary progression

```bash
bash tools/canary.sh status          # current weights + 100-request sample
bash tools/canary.sh set 75 25
bash tools/canary.sh rollout         # 90/10 → 75/25 → 50/50 → 25/75 → 0/100, sampled, auto-rollback
bash tools/canary.sh rollback        # 100/0
```
Rules of a safe canary:
1. Keep **both** backendRefs during the rollout; rollback = change two numbers.
2. Weights are relative: `9/1` == `90/10`. `0/0` → every request 500.
3. A backend with weight > 0 and no ready endpoints → that share of requests fails with 503 (`UH`).
4. Judge the split on ≥ 100 requests; 10 browser refreshes prove nothing.
5. **One** traffic-splitting owner per host: never an Istio `VirtualService` *and* an `HTTPRoute` for the same host.

## Same thing, VirtualService style (for comparison with your istio-guide notes)

| VirtualService / DestinationRule | Gateway API |
|---|---|
| `subset: v1` + DestinationRule `subsets` by label | a Service per version |
| `match: - headers: {end-user: {exact: jason}}` | `matches: - headers: [{name: end-user, value: jason}]` |
| `route: - destination … weight: 50` | `backendRefs: - {name: …, weight: 50}` |
| `rewrite: {uri: /}` | `filters: - type: URLRewrite` |
| `gateways: [bookinfo-gateway]` | `parentRefs: [{name: edge, namespace: lab-gateway}]` |
More in docs/04-FROM-YOUR-NOTES.md.
