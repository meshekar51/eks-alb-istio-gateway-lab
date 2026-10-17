# EKS + AWS ALB + Istio Gateway API — routing, canary, mTLS and a messy-infra troubleshooting lab

A disposable, reproducible lab you build in one sitting from a Linux bastion:

* **Goal 1 — Edge & traffic:** Route 53 (ExternalDNS) → **AWS ALB** (ACM wildcard cert, HTTP→HTTPS) →
  **Istio Gateway API** gateway → `HTTPRoute`s doing **host, path (+rewrite), header, query-param and weighted
  canary** routing to **podinfo v1/v2** (two real releases of the canary demo app from GitHub) and httpbin.
  Optional `make reviews` adds the classic Bookinfo version of the same chain:
  ALB → Gateway pod → HTTPRoute 90/10 → `reviews-v1` / `reviews-v2` Services → Pods.
* **Goal 2 — Mesh security:** the same Istio control plane runs **sidecar** and **ambient** namespaces side by side;
  prove mTLS for each (identities, not just HTTP 200), STRICT vs PERMISSIVE, and ambient L7 policy via a **waypoint**.
* **Messy infra:** `make messy` plants **15 layered faults** (IAM, subnets, ACM, DNS, ALB, Gateway, routes,
  Services, sidecar/ambient enrollment, waypoint). Solve them with the
  **[Master troubleshooting guide](docs/MASTER-TROUBLESHOOTING.md)**, `make doctor` and `make messy-score`.
* **12 single-fault drills** in [`scenarios/`](scenarios/README.md) — including the LBC-in-the-wrong-region incident.

```
Browser ─DNS─► Route 53 ─► ALB :443 (ACM *.<DOMAIN>) ─► edge-istio pods (Gateway API, Envoy) ─► HTTPRoutes
                 ▲                ▲                         ▲                                    │
            ExternalDNS   AWS Load Balancer Ctrl         istiod                       podinfo v1/v2, httpbin
                                                                                     (sidecars, mTLS)
sidecar-lab (Envoy sidecars)  │  ambient-lab (ztunnel + waypoint, HBONE)  │  legacy-lab (no mesh)
```

## Quick start
```bash
# AWS CloudShell (us-east-1)
bash bootstrap/create-bastion.sh && aws ssm start-session --target <id>
# on the bastion
sudo su - ec2-user && git clone <this repo> && cd eks-alb-istio-gateway-lab
cp lab.env.example lab.env && vi lab.env     # DOMAIN + HOSTED_ZONE (an existing public Route 53 zone)
make tools && exec bash -l
make lab          # infra (~18 min) + platform (~5 min) + apps (~6 min)
make test         # all layers green?
make messy        # …then troubleshoot
make destroy      # end of day
```
Full walkthrough: **[docs/01-RUNBOOK.md](docs/01-RUNBOOK.md)**.

## Documentation
| Doc | What |
|---|---|
| [00-ARCHITECTURE](docs/00-ARCHITECTURE.md) | analogy, hops, versions, design decisions |
| [01-RUNBOOK](docs/01-RUNBOOK.md) | build day, checkpoints, teardown, cost |
| [02-ROUTING-AND-CANARY](docs/02-ROUTING-AND-CANARY.md) | routing matrix, precedence, browser/CLI tests, canary rollout |
| [03-MTLS-SIDECAR-VS-AMBIENT](docs/03-MTLS-SIDECAR-VS-AMBIENT.md) | how each mode works and how to *prove* mTLS |
| [MASTER-TROUBLESHOOTING](docs/MASTER-TROUBLESHOOTING.md) | the method, layer-by-layer decoders, cheat sheet |
| [MESSY-LAB](docs/MESSY-LAB.md) / [MESSY-ANSWER-KEY](docs/MESSY-ANSWER-KEY.md) | the exercise / spoilers |
| [04-FROM-YOUR-NOTES](docs/04-FROM-YOUR-NOTES.md) | your istio-guide + gateway-api tutorial mapped to this lab |
| [handbook.html](docs/handbook.html) | the visual handbook (open in a browser) |

## Make targets
| Target | |
|---|---|
| `make tools` / `infra` / `platform` / `apps` / `lab` | build |
| `make test` (`test-platform`, `-edge`, `-routing`, `-canary`, `-mtls`, `-waypoint`) | verify bottom-up |
| `make reviews` (`V1=50 V2=50`) | optional: Bookinfo reviews-v1/v2 at `reviews.<DOMAIN>`, 90/10 by default |
| `make doctor` | walk the request path hop by hop, print the lowest broken layer |
| `make evidence LABEL=x` | snapshot everything to `evidence/*.tar.gz` |
| `make canary-status` / `canary-set V1=50 V2=50` / `canary-rollout` / `canary-rollback` | canary |
| `make messy` / `messy-score` / `unmess` | messy lab |
| `make destroy` | ALB + DNS first, then Terraform |
| `make validate` | offline checks (CI) |

## Repository map
```
bootstrap/        CloudShell bastion create/delete, pinned tool installer
infra/terraform/  VPC, EKS 1.36, nodes, add-ons, Pod Identity (LBC, ExternalDNS), ACM + Route 53 validation, tests/
platform/         LBC + ExternalDNS Helm values, Istio ambient IstioOperator
k8s/              namespaces, apps, Gateway, Ingress, HTTPRoutes, mesh labs, addons/reviews (rendered with lab.env)
scripts/          10-infra, 20-platform, 30-apps, 40-reviews (optional), 90-destroy, lib.sh
tests/            layered test suite (00 platform … 50 waypoint)
tools/            doctor, canary, collect-evidence, validate-offline
messy/            fault injector (spoilers), scoreboard, restore-golden
scenarios/        12 break/fix drills
docs/             guides + visual handbook
```

## Versions (verified 2026-10-17)
EKS **1.36** · Istio **1.31.2** · Gateway API **v1.6.0** · AWS LBC **v3.6.0** · ExternalDNS **v0.23.0** ·
Terraform **1.16.6** / AWS provider **~> 6.0** · Helm **v3.22.1** · kubectl **v1.36.5** · podinfo **6.14.1 / 6.15.0**.

## How this was validated before your first run
* `terraform validate` + `terraform test` (mocked AWS provider 6.69.1): subnet math, tags, Pod Identity names,
  ACM validation records, and the input guards (placeholder domain, domain outside zone, `0.0.0.0/0` API).
* Every manifest — golden and messy — applied to a real Kubernetes 1.36 API server with the Gateway API v1.6.0,
  Istio 1.31.2 and LBC CRDs installed (schema + CEL validation), plus the messy patches and the golden restore.
* `kubeconform -strict`, `istioctl validate` (1.31.2), `shellcheck`.
* Not possible offline: the live AWS run. Expect to adjust small things on first contact — that is the lab.

## Safety
Disposable account only. The bastion gets `AdministratorAccess` by default (override `BASTION_POLICY_ARN`).
`lab.env`, `.state/`, `evidence/`, Terraform state and keys are git-ignored. Cost ≈ US$0.50/h while running.
