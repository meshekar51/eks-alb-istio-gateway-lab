# Runbook — build day, end to end

Total wall-clock ≈ 45–60 min to a green golden lab. Cost ≈ **US$0.50/hour** while it runs
(EKS $0.10 + 3× m6i.large ~$0.29 + NAT ~$0.05 + ALB ~$0.02 + bastion/EBS/IPv4 ~$0.04; data transfer extra).
Destroy at the end of the day.

## 0. Prerequisites (once)

| Need | Check |
|---|---|
| AWS account you may break (not shared/prod) | — |
| A **public Route 53 hosted zone** you control, e.g. `example.com` | `aws route53 list-hosted-zones` |
| The domain's registrar NS records point to that zone | `dig +short NS example.com` = the zone's 4 `awsdns` servers |
| This repo on GitHub | `git clone` works from the bastion |

> No domain yet? Register one in Route 53 (≈ US$15/yr for `.com`), or delegate a sub-domain of a domain you own:
> create a hosted zone `lab.yourdomain.com` and add its 4 NS records at your current DNS provider.

## 1. Bastion (AWS CloudShell, us-east-1) — 3 min

```bash
git clone https://github.com/<you>/eks-alb-istio-gateway-lab.git && cd eks-alb-istio-gateway-lab
bash bootstrap/create-bastion.sh
aws ssm start-session --target <instance-id-printed>
```
On the bastion:
```bash
sudo su - ec2-user
git clone https://github.com/<you>/eks-alb-istio-gateway-lab.git && cd eks-alb-istio-gateway-lab
cp lab.env.example lab.env && vi lab.env      # DOMAIN=lab.yourdomain.com  HOSTED_ZONE=yourdomain.com
make tools                                     # kubectl/helm/terraform/istioctl, checksum-verified
exec bash -l                                   # load completion + alias k
```
✔ Checkpoint: `aws sts get-caller-identity` shows `assumed-role/istio-lab-bastion-role/...`.

## 2. Infrastructure — 15–20 min

```bash
make infra
```
Creates: VPC (2 public + 2 private subnets, 1 NAT), EKS 1.36 (API allow-listed to the bastion EIP), 3 AL2023 nodes,
managed add-ons, Pod Identity roles for the LBC and ExternalDNS, ACM wildcard cert validated in Route 53.

✔ Checkpoint: `kubectl get nodes` → 3 `Ready`. `terraform -chdir=infra/terraform output acm_certificate_arn` → an ARN.

If ACM validation hangs > 10 min → your registrar does not delegate to the hosted zone (step 0).

## 3. Platform — 5 min

```bash
make platform
```
Gateway API CRDs v1.6.0 → AWS LBC (fails fast if region/VPC are not pinned) → Istio 1.31.2 ambient
(istiod + istio-cni + ztunnel) → ExternalDNS.

✔ Checkpoint: `make test-platform` all green.

## 4. Applications, edge, mesh labs — 5–8 min

```bash
make apps
```
✔ Checkpoint: the script prints the ALB name and an authoritative DNS answer for `shop.<DOMAIN>`.

## 5. Prove Goal 1 — routing + canary

```bash
make test-edge        # ALB, listeners, cert, target health, DNS, redirect
make test-routing     # host / path / header / query, which rule matched, which version answered
make test-canary      # 200 requests vs configured weights (4-sigma tolerance)
```
Browser (open dev-tools → Network → response headers → `x-lab-rule`):

| URL | Expect |
|---|---|
| `https://shop.<DOMAIN>/` | blue **STABLE v1** most of the time, green **CANARY v2** ≈ 1 in 10 |
| `https://canary.<DOMAIN>/` | always green v2 |
| `https://shop.<DOMAIN>/api/info?version=v2` | JSON `"version": "6.15.0"` |
| `https://shop.<DOMAIN>/v2` | v2 UI (path rule + rewrite) |
| `https://shop.<DOMAIN>/httpbin/headers` | httpbin JSON incl. `X-Forwarded-Client-Cert … URI=spiffe://cluster.local/ns/lab-gateway/sa/edge-istio` |
| `https://api.<DOMAIN>/headers` | httpbin (host-based) |
| `http://shop.<DOMAIN>/` | 301 → https |

Your "reviews" diagram, literally (optional add-on, ~2 min — Bookinfo's Java reviews pods start slowly):
```bash
make reviews                    # Bookinfo reviews-v1/v2 + ratings in ns bookinfo, HTTPRoute reviews.<DOMAIN> 90/10
make reviews V1=50 V2=50        # shift + re-sample
curl -s https://reviews.<DOMAIN>/reviews/0 | jq -r .podname        # reviews-v1-… or reviews-v2-…
curl -s -H 'end-user: jason' https://reviews.<DOMAIN>/reviews/0 | jq -r .podname   # always v2
```
```
User → ALB → edge-istio (Gateway pod) → HTTPRoute reviews ─ 90% → Service reviews-v1 → reviews-v1 Pod
                                                          └ 10% → Service reviews-v2 → reviews-v2 Pod → ratings
```

Canary progression:
```bash
make canary-set V1=50 V2=50     # or: bash tools/canary.sh set 75 25
make canary-rollout             # 90/10 → 75/25 → 50/50 → 25/75 → 0/100, auto-rollback on errors
make canary-rollback            # 100/0
```

## 6. Prove Goal 2 — mTLS, sidecar vs ambient

```bash
make test-mtls        # matrix under PERMISSIVE, then STRICT; identities from XFCC + ztunnel logs
make test-waypoint    # ambient L7: /forbidden → 403 only via the waypoint
```
Read docs/03-MTLS-SIDECAR-VS-AMBIENT.md alongside the output.

## 7. The messy lab (the main exercise)

```bash
make evidence LABEL=golden      # keep a snapshot of "good"
make messy                      # plants 15 faults across every layer
make test                       # see what users see
make doctor                     # hop-by-hop evidence
make messy-score                # how many faults remain per layer (no spoilers)
```
Work with docs/MASTER-TROUBLESHOOTING.md. Stuck → docs/MESSY-ANSWER-KEY.md. Give up → `make unmess`.

## 8. Single-fault drills

`scenarios/README.md` — 12 break/fix drills (including your old wrong-region LBC incident).

## 9. Teardown — 15 min

```bash
make destroy                    # on the bastion: ALB + DNS first, then terraform destroy
exit                            # back to CloudShell
bash bootstrap/delete-bastion.sh
```
Double-check in the console: EC2 → Load Balancers, NAT gateways, Elastic IPs; Route 53 records under `<DOMAIN>`;
ACM certificates tagged `Lab=messy`. The hosted zone itself is **not** deleted (it was there before).

## Re-run tomorrow

Everything is idempotent: `create-bastion.sh` → `make tools` → `make lab` → `make test`. Your canary weights are
kept in `.state/canary.env` (on the bastion) and are reset by a fresh bastion.
