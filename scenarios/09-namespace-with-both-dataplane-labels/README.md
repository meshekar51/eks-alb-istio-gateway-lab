# 09 — A namespace with BOTH data-plane labels

| | |
|---|---|
| Break | `bash scenarios/09-namespace-with-both-dataplane-labels/break.sh` |
| Layer | L7 |
| User symptom | Pods restart with an `istio-proxy` sidecar; memory/CPU per pod jump; ambient features (ztunnel capture) no longer apply to them. |

## Rule (Istio docs, "Pod selection logic")
A pod is ambient only if the namespace/pod has `istio.io/dataplane-mode=ambient`, it is not opted out with
`istio.io/dataplane-mode=none`, **and it has no `sidecar.istio.io/status` annotation**. If both modes are requested,
**sidecar wins**. Keep exactly one of `istio-injection=enabled` / `istio.io/dataplane-mode=ambient` per namespace.

```bash
kubectl get ns -L istio-injection -L istio.io/dataplane-mode -L istio.io/use-waypoint
kubectl get pod -n ambient-lab -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.metadata.annotations.sidecar\.istio\.io/status}{"\n"}{end}' | cut -c1-120
```
Compare the BEFORE/AFTER `istioctl ztunnel-config workload` output printed by break.sh.

## Fix
`bash scenarios/09-namespace-with-both-dataplane-labels/fix.sh` (remove the label **and** restart — injection is
decided at pod creation).
