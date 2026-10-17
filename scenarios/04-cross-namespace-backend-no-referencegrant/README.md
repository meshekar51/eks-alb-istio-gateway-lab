# 04 — Cross-namespace backendRef without a ReferenceGrant

| | |
|---|---|
| Break | `bash scenarios/04-cross-namespace-backend-no-referencegrant/break.sh` |
| Layer | L5/L6 |
| User symptom | `https://shop.<DOMAIN>/mesh/get` → **500** (Gateway API mandates 500 for an invalid backend; the rest of the route keeps working). |

## Investigate
```bash
kubectl get httproute shop-mesh -n lab-apps -o jsonpath='{range .status.parents[*].conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}'
```
Expected: `ResolvedRefs=False` reason **RefNotPermitted** ("missing a ReferenceGrant?").

## Rule
The **owner of the target** must consent. The ReferenceGrant is created in `sidecar-lab` (where the Service lives),
never in the route's namespace.

## Fix
`bash scenarios/04-cross-namespace-backend-no-referencegrant/fix.sh`. Bonus: `/mesh/headers` now shows an XFCC
header — the edge gateway reached a sidecar in another namespace over mTLS.
