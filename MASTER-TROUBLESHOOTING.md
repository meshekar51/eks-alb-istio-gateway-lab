# Master troubleshooting guide

> **The parcel rule:** a request is a parcel crossing 8 checkpoints. Don't argue about the last checkpoint
> while the parcel never left the first. Find the **lowest broken layer**, prove it with evidence, change
> **one** thing, re-test.

```
  L0 access ─ L1 controllers ─ L2 DNS ─ L3 ALB/TLS ─ L4 Gateway ─ L5 HTTPRoute ─ L6 Service/Pods ─ L7 mesh
  (you)       (LBC, istiod,     (Route53)  (ALB, ACM,    (Envoy      (attach,       (ports,          (mTLS, waypoint,
               ExternalDNS,                 targets)      pods)       match)         endpoints)       policy)
               ztunnel)
```

## The 6-step method (use it every time)

1. **Capture** before touching anything: `make evidence LABEL=<what-you-see>`.
2. **Reproduce** precisely: one `curl -sv` command whose output you can compare later.
3. **Isolate** with bypasses, bottom-up:
   | Bypass | Skips | Command |
   |---|---|---|
   | ask the authoritative DNS | resolver caches | `dig +short @$(dig +short NS <ZONE> \| head -1) shop.<DOMAIN>` |
   | `--connect-to` the ALB | DNS | `curl -sv --connect-to shop.<DOMAIN>:443:<ALB>:443 https://shop.<DOMAIN>/` |
   | port-forward the gateway | ALB, TLS | `kubectl -n lab-gateway port-forward deploy/edge-istio 8080:80` then `curl -H 'Host: shop.<DOMAIN>' localhost:8080/api/info` |
   | curl the Service in-cluster | Gateway, routes | `kubectl exec -n sidecar-lab deploy/curl -- curl -s http://podinfo-v2.lab-apps/api/info` |
   | curl the pod IP | Service, kube-proxy | `kubectl exec … -- curl -s http://<podIP>:9898/api/info` |
4. **Read the status** the controllers wrote: `Ingress events`, `Gateway/HTTPRoute .status.conditions`, target health.
5. **Change one thing**, the smallest possible, in the source of truth (Terraform / git), not only live.
6. **Re-test** the same reproduction + `make test` (a fix in L5 can uncover an L6 fault).

`make doctor` automates steps 3–4 hop by hop and prints the lowest broken layer.

## Who returned this response? (read before anything else)

| You see | Most likely from | Next |
|---|---|---|
| `curl: (6) Could not resolve host` | DNS (L2) | authoritative `dig`; ExternalDNS logs |
| `curl: (28) … timed out` connecting | ALB SG / no ALB / wrong IP (L3) | `--connect-to` the ALB; `aws elbv2 describe-load-balancers` |
| `SSL certificate problem` / name mismatch | ALB listener cert (L3) | `openssl s_client -servername …` |
| `301` to https | ALB port-80 redirect | expected |
| `503`, `server: awselb/2.0` | ALB has **no registered** targets | TargetGroupBinding, gateway pods |
| `502`, `server: awselb/2.0` | target closed / bad response | gateway pods crashing, wrong target port |
| `504`, `server: awselb/2.0` | target timeout | security group / target port |
| `404` with **empty body** and **no** `x-envoy-upstream-service-time` | Envoy at the gateway: **no route** (`NR`) | L5 attachment / hostname / match |
| `404` with a body (`404 page not found`) **and** `x-envoy-upstream-service-time` | the **application** | path rewrite missing (L5) |
| `500`, empty | Gateway API invalid backend (`ResolvedRefs=False`) | L5/L6 |
| `503 no healthy upstream` | Envoy: backend has no ready endpoints (`UH`) | L6 selector/readiness |
| `503 upstream connect error … reset` | connection to pod failed (`UF`/`URX`) | L7 mTLS mismatch / port |
| `403 RBAC: access denied` | Istio AuthorizationPolicy (sidecar or waypoint) | L7 policy |
| `curl: (56) Connection reset by peer` (in-cluster) | STRICT mTLS refusing plaintext | L7 enrollment |

The `server:` header is **not** reliable for "gateway vs app" — Envoy may overwrite it. Use
`x-envoy-upstream-service-time` (present only if an upstream answered), the body, and the **access log**.

### Envoy access log — response flags (5th-ish field in the default TEXT format)
```bash
kubectl logs -n lab-gateway deploy/edge-istio --tail=20
# [time] "GET /api/info HTTP/1.1" 200 - via_upstream - "-" 0 412 3 2 "1.2.3.4,10.80.0.12" "curl/8" "…" "shop.lab…" "10.80.20.31:9898" outbound|80||podinfo-v1.lab-apps.svc.cluster.local …
#                                   ^code ^flags ^details
```
| Flag | Meaning | Usual cause in this lab |
|---|---|---|
| `-` | upstream answered | look at the app |
| `NR` | no route | host/path didn't match; route not attached |
| `NC` | cluster not found | backendRef port not a Service port |
| `UH` | no healthy upstream | Service selector matches no ready pods |
| `UF` | upstream connection failure | pod not listening / mTLS mismatch |
| `URX` | retries exhausted | repeated UF/5xx |
| `UC` | upstream connection terminated | app crash, mTLS reset |
| `UT` | upstream timeout | slow backend |
| `DC` | downstream (client) closed | client gave up |
Response code details like `rbac_access_denied_matched_policy[…]` explain 403s.

---

## L0 — Your access
| Symptom | Check | Fix |
|---|---|---|
| `kubectl` hangs / i/o timeout | `curl -4 https://checkip.amazonaws.com` vs `aws eks describe-cluster --query cluster.resourcesVpcConfig.publicAccessCidrs` | IP changed (bastion stop/start without EIP) → `make infra` |
| `You must be logged in` / `Unauthorized` | `aws sts get-caller-identity` ; `aws eks list-access-entries --cluster-name …` | access entry for your principal (`ADMIN_PRINCIPAL_ARNS`), `make kubeconfig` |
| wrong cluster | `kubectl config current-context` | `make kubeconfig` |

## L1 — Controllers
Everything above depends on four controllers. If one is unhealthy, fix it first.

```bash
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller
kubectl get pods -n external-dns ; kubectl get pods -n istio-system
```

### AWS Load Balancer Controller — error decoder
```bash
kubectl logs -n kube-system deploy/aws-load-balancer-controller --since=15m | grep -iE 'error|denied|subnet|cert'
kubectl get deploy aws-load-balancer-controller -n kube-system -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n'
```
| Message contains | Root cause | Fix |
|---|---|---|
| `AccessDenied … assumed-role/<cluster>-node/i-…` | the pod uses the **node** role: Pod Identity not applied | association `kube-system/aws-load-balancer-controller` must exist (`aws eks list-pod-identity-associations`), then **restart the pods** (credentials are injected at pod creation) |
| no `AWS_CONTAINER_CREDENTIALS_FULL_URI` env in the pod | same as above | same |
| `subnets count less than minimal required count: 1 < 2` | only one subnet qualifies (role tag missing in one AZ) | tag every public subnet `kubernetes.io/role/elb=1` (Terraform) |
| `unable to resolve at least one subnet` | no candidate subnets: wrong region/VPC, other cluster's tag, < 8 free IPs | check `--aws-region`, `--aws-vpc-id`, subnet tags |
| `InvalidSubnetID.NotFound` / `InvalidVpcID.NotFound` | right IDs, **wrong region** | Helm `region` + `vpcId` (scenario 01) |
| `CertificateNotFound` | cert ARN from another region/account, or deleted | ACM cert in the ALB's region |
| `services "x" not found` / `unable to find port` | Ingress backend name/port | Ingress → `edge-istio:80` |
| `failed calling webhook "mservice.elbv2.k8s.aws"` (on **any** Service create) | LBC pods down; webhook `failurePolicy: Fail` | bring LBC back (scenario 10) |

### ExternalDNS — log decoder
```bash
kubectl logs -n external-dns deploy/external-dns --since=15m
kubectl get deploy external-dns -n external-dns -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n'
```
| Log | Meaning |
|---|---|
| `Desired change: CREATE shop.<DOMAIN> A` / `UPSERT` | working |
| `All records are already up to date` but no record exists | your hostname/zone is **filtered out** (`--domain-filter`, `--zone-id-filter`) or the Ingress has no ALB address yet |
| `AccessDenied … route53:…` | Pod Identity / IAM policy scope |
| nothing about your host | missing `external-dns.alpha.kubernetes.io/hostname` annotation, or wrong `--source` |

### istiod / ztunnel / CNI
```bash
istioctl proxy-status                         # every proxy SYNCED? (STALE = istiod can't push)
kubectl logs -n istio-system deploy/istiod --since=10m | grep -iE 'error|warn' | tail
kubectl get ds -n istio-system                # ztunnel + istio-cni-node DESIRED == READY
istioctl analyze -A
```
istiod down ⇒ existing traffic keeps flowing, **changes don't apply**, new sidecar pods can't be created (scenario 11).

## L2 — DNS
```bash
NS=$(dig +short NS <HOSTED_ZONE> | head -1)
dig +short @"$NS" shop.<DOMAIN>               # authoritative truth
dig +short shop.<DOMAIN>                      # what your resolver cached
dig +short <ALB-DNS>                          # must overlap the answer above
aws route53 list-resource-record-sets --hosted-zone-id <ZONE_ID> --query "ResourceRecordSets[?contains(Name,'<DOMAIN>')]"
```
| Finding | Cause | Fix |
|---|---|---|
| authoritative empty | ExternalDNS didn't create it (L1 decoder) | fix ExternalDNS |
| authoritative OK, resolver empty | negative caching (SOA min TTL) | wait / test with `@$NS` or `--connect-to` |
| record points at a different ALB | stale record (ALB re-created while ExternalDNS was down; record owned by someone else) | ExternalDNS owner TXT; scenario 12 |
| ACM validation stuck `PENDING_VALIDATION` | registrar NS ≠ hosted zone NS | delegate the domain |

## L3 — ALB and TLS
```bash
kubectl describe ingress edge-alb -n lab-gateway | sed -n '/Events/,$p'
aws elbv2 describe-load-balancers --names <cluster>-edge --query 'LoadBalancers[0].[State.Code,Scheme,AvailabilityZones[].SubnetId]'
aws elbv2 describe-listeners --load-balancer-arn <arn> --query 'Listeners[].[Port,Protocol,Certificates[0].CertificateArn,DefaultActions[0].Type]'
TG=$(kubectl get targetgroupbinding -n lab-gateway -o jsonpath='{.items[0].spec.targetGroupARN}')
aws elbv2 describe-target-health --target-group-arn $TG --output table
echo | openssl s_client -connect <ALB-DNS>:443 -servername shop.<DOMAIN> 2>/dev/null | openssl x509 -noout -subject -issuer -ext subjectAltName
```
| Finding | Cause | Fix |
|---|---|---|
| Ingress has no ADDRESS | LBC could not build the model — read Events | L1 decoder |
| Target `unhealthy`, `Target.ResponseCodeMismatch [404]` | wrong health-check path | `/healthz/ready` |
| Target `unhealthy`, `Target.Timeout` / `FailedHealthChecks` | wrong HC port / SG | `healthcheck-port: "15021"`; LBC manages SG rules |
| **all** targets unhealthy but site works | ALB **fail-open** | still fix it (scenario 05) |
| no targets registered (`503 awselb`) | gateway pods not Ready, or Ingress points to the wrong Service | L4 |
| cert subject ≠ `*.<DOMAIN>`, self-signed | wrong `certificate-arn` | Terraform output `acm_certificate_arn` |
| `ssl-redirect` loop / 301 to http | ALB terminates TLS; app must not redirect again | — |

## L4 — Istio edge Gateway
```bash
kubectl get gateway edge -n lab-gateway -o yaml | sed -n '/^status/,$p'
kubectl get deploy,svc,pods -n lab-gateway
istioctl proxy-config listener deploy/edge-istio -n lab-gateway
istioctl proxy-config route deploy/edge-istio -n lab-gateway            # virtual hosts = attached hostnames
kubectl logs -n lab-gateway deploy/edge-istio --tail=30                  # access log
```
| Finding | Cause | Fix |
|---|---|---|
| `Programmed=False` | istiod can't deploy it (webhook, quota, bad parametersRef) | conditions message |
| Service `edge-istio` is `LoadBalancer` | parametersRef overlay missing | ConfigMap + `infrastructure.parametersRef` |
| `attachedRoutes: 0` | no route allowed on the listener | `allowedRoutes`, namespace label `lab.io/edge-routes=allowed`, hostnames |
| `proxy-config route` lacks your hostname | route not attached | L5 |

## L5 — HTTPRoute attachment and matching
```bash
kubectl get httproute -A
kubectl get httproute shop -n lab-apps -o jsonpath='{range .status.parents[*]}{.parentRef.name}{": "}{range .conditions[*]}{.type}={.status}({.reason}) {end}{"\n"}{end}'
curl -sI https://shop.<DOMAIN>/<path> | grep -i x-lab-rule
```
| Condition | Reason | Meaning / fix |
|---|---|---|
| `Accepted=False` | `NotAllowedByListeners` | listener `allowedRoutes` excludes this namespace/kind |
| `Accepted=False` | `NoMatchingListenerHostname` | route hostname outside `*.<DOMAIN>` |
| `Accepted=False` | `NoMatchingParent` | `parentRef` name/namespace/`sectionName` wrong |
| `ResolvedRefs=False` | `BackendNotFound` | Service name/namespace typo → requests get **500** |
| `ResolvedRefs=False` | `RefNotPermitted` | cross-namespace backend without ReferenceGrant (in the target ns) |
| conditions all True, wrong backend | precedence: a more specific rule, or an **older route** with the same host+match wins | `kubectl get httproute -A -o wide`; look for duplicates (doctor flags them) |
| header rule never matches | value case, header name typo | `Exact` values are case-sensitive |
| path rule → app 404 | missing `URLRewrite` | add `ReplacePrefixMatch: /` |

Istio does **not** validate `backendRefs.port`: a wrong port keeps `ResolvedRefs=True` and fails at runtime (`NC`).
`make doctor` checks ports against the Service.

## L6 — Service, endpoints, pods
```bash
kubectl get svc podinfo-v2 -n lab-apps -o jsonpath='{.spec.selector}{"  "}{.spec.ports}{"\n"}'
kubectl get endpointslices -n lab-apps -l kubernetes.io/service-name=podinfo-v2 -o wide
kubectl get pods -n lab-apps --show-labels
istioctl proxy-config endpoint deploy/edge-istio -n lab-gateway --cluster 'outbound|80||podinfo-v2.lab-apps.svc.cluster.local'
```
| Finding | Cause | Fix |
|---|---|---|
| EndpointSlice empty | selector ≠ pod labels (case!), pods not Ready | fix selector / readiness |
| endpoints exist, `proxy-config endpoint` UNHEALTHY | outlier detection / failing app | app logs |
| `backendRefs.port` not in `.spec.ports` | port mix-up (Service vs container) | use the Service port |
| canary share returns 503 | weight > 0 on a backend with no endpoints | scale it or set weight 0 |

## L7 — Mesh (sidecar, ambient, policy)
```bash
kubectl get ns -L istio-injection -L istio.io/dataplane-mode -L istio.io/use-waypoint
kubectl get pods -n <ns> -o custom-columns='POD:.metadata.name,C:.spec.containers[*].name,INIT:.spec.initContainers[*].name'
istioctl x check-inject -n sidecar-lab deploy/httpbin
istioctl ztunnel-config workload | awk 'NR==1 || $1=="ambient-lab"'     # PROTOCOL HBONE?
istioctl ztunnel-config service  | awk 'NR==1 || $1=="ambient-lab"'     # WAYPOINT column
kubectl get peerauthentication,authorizationpolicy -A
istioctl x describe pod <pod>.<ns>
```
| Finding | Cause | Fix |
|---|---|---|
| no `istio-proxy` in a sidecar namespace | label typo (`enable`), or pods created before the label | `istio-injection=enabled` + **restart** |
| STRICT but plaintext client still gets 200 | the **server** isn't in the mesh (nothing enforces STRICT) | enroll the server |
| mesh client → STRICT server = reset | the **client** isn't in the mesh (`dataplane-mode=none` on the pod, no sidecar) | enroll the client |
| ambient pod `PROTOCOL TCP` | not enrolled / opted out (`istio.io/dataplane-mode=none` on the pod) | remove opt-out |
| L7 policy ignored in ambient | no waypoint in the path: `use-waypoint` missing or names a non-existent waypoint | `istio.io/use-waypoint=waypoint` |
| L7 policy blocks **everything** in ambient | L7 rule bound with `selector:` → ztunnel fails closed | `targetRefs:` to the Service |
| pods suddenly have sidecars in ambient ns | both labels; sidecar wins | one label per namespace |
| `istioctl proxy-status` STALE / NOT SENT | istiod can't push | istiod logs |

## Golden commands (cheat sheet)
```bash
make test            # lowest red layer wins
make doctor          # hop-by-hop evidence
make evidence        # snapshot
kubectl get events -A --sort-by=.lastTimestamp | tail -30
kubectl get gateway,httproute -A
istioctl analyze -A
istioctl proxy-status
istioctl proxy-config route deploy/edge-istio -n lab-gateway
istioctl ztunnel-config workload
kubectl logs -n lab-gateway deploy/edge-istio --tail=20
kubectl logs -n kube-system deploy/aws-load-balancer-controller --tail=50
kubectl logs -n external-dns deploy/external-dns --tail=50
aws elbv2 describe-target-health --target-group-arn $(kubectl get targetgroupbinding -n lab-gateway -o jsonpath='{.items[0].spec.targetGroupARN}')
```
