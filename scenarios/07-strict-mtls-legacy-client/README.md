# 07 — STRICT mTLS breaks a non-mesh client (working as designed)

| | |
|---|---|
| Break | `bash scenarios/07-strict-mtls-legacy-client/break.sh` |
| Layer | L7 |
| User symptom | `curl: (56) Recv failure: Connection reset by peer` (no HTTP status at all — the TLS/HBONE handshake is refused before HTTP exists). |

## Who rejects it?
* **sidecar-lab**: the server pod's Envoy inbound listener only accepts Istio mTLS.
* **ambient-lab**: the destination node's **ztunnel** drops plaintext because of STRICT.

```bash
kubectl logs -n sidecar-lab deploy/httpbin -c istio-proxy --tail=5
kubectl logs -n istio-system -l app=ztunnel --tail=50 | grep -i -E 'ambient-lab|denied|plaintext'
istioctl x describe pod $(kubectl get pod -n sidecar-lab -l app=httpbin -o name | cut -d/ -f2).sidecar-lab
```

## Options
1. **Enroll the client** (fix.sh): label `legacy-lab` ambient. Pods are captured by ztunnel immediately — no restart.
   That is the killer feature of ambient for migrations.
2. Temporarily `PERMISSIVE` for that one workload (PeerAuthentication with a `selector`) while migrating.
3. Never: disable STRICT mesh-wide to fix one client.
