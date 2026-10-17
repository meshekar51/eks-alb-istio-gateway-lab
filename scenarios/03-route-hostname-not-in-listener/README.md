# 03 — HTTPRoute hostname does not intersect the listener hostname

| | |
|---|---|
| Break | `bash scenarios/03-route-hostname-not-in-listener/break.sh` |
| Layer | L5 (route attachment) |
| User symptom | 404 from `istio-envoy`, *and* a TLS name mismatch (the ACM cert is `*.DOMAIN`, not `*.HOSTED_ZONE`). Two independent problems with one root cause: the hostname is outside the lab domain. |

## Investigate
```bash
kubectl get httproute promo -n lab-apps -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
kubectl get gateway edge -n lab-gateway -o jsonpath='{.spec.listeners[0].hostname}'
kubectl get gateway edge -n lab-gateway -o jsonpath='{.status.listeners[0].attachedRoutes}'   # did NOT increase
```
Expected: `Accepted=False` with reason **NoMatchingListenerHostname**.

## Rule
Route hostnames must *intersect* the listener hostname. `*.lab.example.com` matches `promo.lab.example.com`
but not `promo.example.com` and not `lab.example.com` (a wildcard needs at least one extra label).

## Fix
`bash scenarios/03-route-hostname-not-in-listener/fix.sh` then delete the route. To publish it via DNS, also add the
host to the Ingress `external-dns.alpha.kubernetes.io/hostname` annotation.
