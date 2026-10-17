# 08 — Ambient: an L7 policy on ztunnel fails CLOSED

| | |
|---|---|
| Break | `bash scenarios/08-ambient-l7-policy-without-waypoint/break.sh` |
| Layer | L7 (ambient) |
| User symptom | Even plain `GET /get` is rejected — the policy was meant to allow GETs. |

## Why
A policy with `selector:` is enforced by the **destination ztunnel**. ztunnel is L4: it cannot see methods,
paths or headers. Istio's documented behaviour is to *fail safe*: a policy with L7 conditions enforced by
ztunnel turns into a DENY.

```bash
istioctl ztunnel-config policy | grep ambient-lab        # what ztunnel actually enforces
kubectl get authorizationpolicy allow-get-only -n ambient-lab -o yaml | grep -A5 status
istioctl analyze -n ambient-lab
```

## Rule of thumb (ambient)
* L4 attributes (principals, namespaces, ports, IPs) → `selector:` → ztunnel.
* L7 attributes (paths, methods, headers, JWT) → `targetRefs:` (Service / Gateway) → **waypoint**.

## Fix
`bash scenarios/08-ambient-l7-policy-without-waypoint/fix.sh` (GET → 200, POST → 403).
