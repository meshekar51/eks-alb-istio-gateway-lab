# 11 — istiod down: control plane vs data plane

| | |
|---|---|
| Break | `bash scenarios/11-istiod-down-control-vs-data-plane/break.sh` |
| Layer | L1 |

## Expected observations
1. **Existing traffic keeps working.** Envoys/ztunnels keep their last config and certificates (workload certs live ~24h).
2. **Config changes do nothing.** A new canary weight is accepted by the API server (HTTPRoute updated), but no proxy receives it.
   `istioctl proxy-status` cannot even connect.
3. **New pods in sidecar namespaces cannot be created**: the injection webhook (`failurePolicy: Fail`) is down →
   ReplicaSet events show `failed calling webhook "...sidecar-injector.istio.io"`.

```bash
kubectl get events -n lab-apps --sort-by=.lastTimestamp | tail
kubectl get mutatingwebhookconfigurations -l app=sidecar-injector -o jsonpath='{range .items[*].webhooks[*]}{.name}{" "}{.failurePolicy}{"\n"}{end}'
```

## Fix
`bash scenarios/11-istiod-down-control-vs-data-plane/fix.sh` — then confirm the 50/50 split finally applies.
