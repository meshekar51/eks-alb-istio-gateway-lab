# 06 — A bad canary release, caught and rolled back

| | |
|---|---|
| Break | `bash scenarios/06-bad-canary-release-auto-rollback/break.sh` |
| Then | `PAUSE=0 bash tools/canary.sh rollout` |
| Layer | L6 (application) — the *routing* is perfect, the *release* is bad |

## What you should see
At the 90/10 step roughly 3% of all requests fail (10% of traffic × ~1/3 errors). `tests/30-canary.sh` counts
non-200 responses → the rollout script restores **100/0** automatically. That is canary analysis in its simplest form
(Flagger / Argo Rollouts do the same with Prometheus queries).

## Investigate like production
```bash
kubectl logs -n lab-gateway deploy/edge-istio --tail=50 | awk '$9 >= 500'        # gateway access log: status field
kubectl logs -n lab-apps deploy/podinfo-v2 -c istio-proxy --tail=20               # server-side sidecar view
for i in $(seq 1 40); do curl -s -o /dev/null -w '%{http_code}\n' -H 'x-canary: true' https://SHOP_HOST/api/info; done | sort | uniq -c
```
Using the **header** route you can reproduce the bug on v2 deterministically without touching user traffic.

## Fix
`bash scenarios/06-bad-canary-release-auto-rollback/fix.sh`
