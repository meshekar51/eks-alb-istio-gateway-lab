# Scenario drills (one fault at a time)

Run these **after** the messy lab is solved and `make test` is green. Each drill has
`break.sh` (inject), a README (symptom → investigation → root cause → fix → prevention) and `fix.sh`.
Rule: run `make evidence` (snapshot) before you fix anything, and `make test` after.

| # | Drill | Layer | What it teaches |
|---|---|---|---|
| 01 | [LBC wrong region](01-lbc-wrong-region/) | L1→L3 | your real ap-southeast-2 incident; IDs are regional |
| 02 | [ACM cert in another region](02-acm-cert-wrong-region/) | L3 | desired vs applied; ALB certs are regional |
| 03 | [Route hostname outside listener](03-route-hostname-not-in-listener/) | L5 | `NoMatchingListenerHostname`, wildcard rules |
| 04 | [Cross-namespace backend](04-cross-namespace-backend-no-referencegrant/) | L5/L6 | `RefNotPermitted`, ReferenceGrant lives at the target |
| 05 | [Health check broken, site still up](05-alb-health-check-fail-open/) | L3 | ALB fail-open; why 15021 |
| 06 | [Bad canary release](06-bad-canary-release-auto-rollback/) | L6 | canary analysis + automatic rollback |
| 07 | [STRICT vs legacy client](07-strict-mtls-legacy-client/) | L7 | who enforces STRICT (sidecar vs ztunnel); enrol without restart |
| 08 | [L7 policy on ztunnel](08-ambient-l7-policy-without-waypoint/) | L7 | fail-closed; selector vs targetRefs |
| 09 | [Both data-plane labels](09-namespace-with-both-dataplane-labels/) | L7 | sidecar wins; injection happens at pod creation |
| 10 | [LBC down blocks Services](10-lbc-down-blocks-service-creation/) | L1 | admission webhooks with failurePolicy Fail |
| 11 | [istiod down](11-istiod-down-control-vs-data-plane/) | L1 | control plane vs data plane |
| 12 | [Stale DNS after ALB re-create](12-stale-dns-after-alb-recreate/) | L2 | `--connect-to` isolation; authoritative vs cached DNS |
