# Messy lab — answer key (SPOILERS)

Faults are listed in the order you will most likely meet them (bottom-up along the request path).
"Source-of-truth fix" is what makes it permanent; "Live fix" is the quick proof.

---

### M01 — LBC has no AWS credentials (Pod Identity association for the wrong service account)
* **Symptom:** Ingress `edge-alb` has no ADDRESS. Events: `FailedBuildModel` / `FailedDeployModel`.
* **Evidence:**
  ```bash
  kubectl logs -n kube-system deploy/aws-load-balancer-controller | grep -i denied
  #  … AccessDenied: User: arn:aws:sts::…:assumed-role/istio-gateway-lab-node/i-… is not authorized to perform: elasticloadbalancing:…
  aws eks list-pod-identity-associations --cluster-name istio-gateway-lab --namespace kube-system
  #  serviceAccount: aws-load-balancer-controler   <- typo, one "l"
  kubectl get pod -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller -o jsonpath='{.items[0].spec.containers[0].env[*].name}'
  #  no AWS_CONTAINER_CREDENTIALS_FULL_URI
  ```
* **Root cause:** the association is matched on (namespace, **service account name**). No match ⇒ no credentials ⇒
  the AWS SDK falls back to IMDS ⇒ the **node** role ⇒ AccessDenied.
* **Fix (source of truth):** `make infra` (Terraform recreates `kube-system/aws-load-balancer-controller`), delete
  the stray association, then **restart the controller** — credentials are injected only at pod creation:
  ```bash
  aws eks delete-pod-identity-association --cluster-name istio-gateway-lab --association-id <typo-one>
  kubectl rollout restart deploy/aws-load-balancer-controller -n kube-system
  ```

### M02 — Only one public subnet is discoverable
* **Symptom (after M01):** Ingress event `subnets count less than minimal required count: 1 < 2`.
* **Evidence:**
  ```bash
  aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC_ID Name=tag:lab.tier,Values=public \
    --query 'Subnets[].[SubnetId,AvailabilityZone,Tags[?Key==`kubernetes.io/role/elb`]|[0].Value]' --output table
  ```
* **Root cause:** the `kubernetes.io/role/elb` tag was removed from the AZ-b public subnet. Because *some* subnet
  still has the role tag, the LBC only considers role-tagged subnets (reachability discovery is skipped) → 1 AZ.
* **Fix:** `make infra` (Terraform re-adds the tag; `terraform plan` shows the drift). Live:
  `aws ec2 create-tags --resources <subnet> --tags Key=kubernetes.io/role/elb,Value=1`.

### M05 — Ingress points at a Service that does not exist
* **Symptom (after M02):** event `… services "edge" not found`.
* **Root cause:** the gateway Service is `<gateway>-<gatewayclass>` = **`edge-istio`**, not the Gateway name.
* **Fix:** `make apps` (or `kubectl apply` the golden `k8s/ingress/edge-alb.yaml`).

### M03 — HTTPS serves a self-signed certificate for the wrong name
* **Symptom:** ALB exists; `curl https://…` → `SSL certificate problem: self-signed certificate`; browser warning.
* **Evidence:**
  ```bash
  echo | openssl s_client -connect $ALB:443 -servername shop.$DOMAIN 2>/dev/null | openssl x509 -noout -subject -issuer -ext subjectAltName
  #  subject=CN = legacy.<DOMAIN>   issuer=CN = legacy.<DOMAIN>
  kubectl get ingress edge-alb -n lab-gateway -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/certificate-arn}'
  aws acm describe-certificate --certificate-arn <that-arn> --query 'Certificate.[Type,DomainName]'   # IMPORTED
  ```
* **Fix:** annotation → `terraform output -raw acm_certificate_arn` (golden Ingress). Then
  `aws acm delete-certificate` the imported one (it fails with `ResourceInUseException` until the ALB let go of it).

### M06 — Health check path does not exist
* **Symptom:** none for users! `tests/10-edge.sh` / doctor: all targets `unhealthy`,
  `Target.ResponseCodeMismatch` "Health checks failed with these codes: [404]".
* **Root cause:** `healthcheck-path: /healthz/readiness` — Istio's status port serves `/healthz/ready`. With **all**
  targets unhealthy the ALB fails open, hiding the problem.
* **Fix:** golden Ingress (`/healthz/ready`).

### M04 — ExternalDNS ignores the hosted zone
* **Symptom:** `curl: (6) Could not resolve host`; works with `--connect-to`.
* **Evidence:**
  ```bash
  dig +short @$(dig +short NS $HOSTED_ZONE | head -1) shop.$DOMAIN        # empty
  kubectl get deploy external-dns -n external-dns -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n' | grep filter
  #  --domain-filter=<letters swapped>
  kubectl logs -n external-dns deploy/external-dns | tail      # "All records are already up to date" - nothing in scope
  ```
* **Fix:** `helm upgrade external-dns … -f platform/external-dns-values.yaml` (rendered by `make platform`).
  Then wait for the next loop / negative-cache TTL; verify against the authoritative NS.

### M07 — The listener only accepts routes from its own namespace
* **Symptom:** 404 for every host, empty body, Envoy access log flag `NR`.
* **Evidence:**
  ```bash
  kubectl get httproute -n lab-apps -o custom-columns=N:.metadata.name,A:.status.parents[0].conditions[0].reason
  #  NotAllowedByListeners
  kubectl get gateway edge -n lab-gateway -o jsonpath='{.spec.listeners[0].allowedRoutes}'   # {"namespaces":{"from":"Same"}}
  ```
* **Fix:** golden `k8s/gateway/edge-gateway.yaml` (`from: Selector`, label `lab.io/edge-routes=allowed`).

### M08 — An old "temporary" route shadows the canary
* **Symptom:** `tests/30-canary.sh`: 0% v2 and `rules seen: ' '` (no `x-lab-rule` header). Header/query/path rules still work.
* **Evidence:**
  ```bash
  kubectl get httproute -n lab-apps -o custom-columns=NAME:.metadata.name,HOSTS:.spec.hostnames,CREATED:.metadata.creationTimestamp
  #  shop-v1-pin  [shop.<DOMAIN>]  <older>
  ```
* **Root cause:** two routes, same hostname, identical match (`PathPrefix /`, no headers) → tie → **oldest route wins**.
* **Fix:** `kubectl delete httproute shop-v1-pin -n lab-apps` (it's not in git — that's the tell).

### M11 — `/v2` path rule lost its URLRewrite
* **Symptom:** `https://shop.<DOMAIN>/v2` → 404 **with** a body `404 page not found`, header `x-lab-rule: path-v2`
  and `x-envoy-upstream-service-time` → the *application* answered.
* **Fix:** golden `k8s/routes/shop.yaml` (URLRewrite `ReplacePrefixMatch: /`).

### M12 — Header rule matches `x-canery`
* **Symptom:** `curl -H 'x-canary: true'` → `x-lab-rule: weighted`, mostly v1.
* **Evidence:** `kubectl get httproute shop -n lab-apps -o jsonpath='{.spec.rules[?(@.name=="header-canary")].matches[0].headers}'`
* **Fix:** golden route.

### M09 — `podinfo-v2` Service selects nothing
* **Symptom:** forced-v2 requests (`/v2`, header, query, `canary.<DOMAIN>`) → `503 no healthy upstream` (`UH`);
  weighted traffic → ~10% 503s.
* **Evidence:**
  ```bash
  kubectl get svc podinfo-v2 -n lab-apps -o jsonpath='{.spec.selector}'          # {"app":"podinfo","version":"V2"}
  kubectl get pods -n lab-apps -l app=podinfo --show-labels                      # version=v2
  kubectl get endpointslices -n lab-apps -l kubernetes.io/service-name=podinfo-v2 # no endpoints
  ```
* **Fix:** golden `k8s/apps/podinfo.yaml` (`version: v2` — labels are case-sensitive).

### M10 — `api` route uses the container port
* **Symptom:** `https://api.<DOMAIN>/` → 5xx; HTTPRoute is `Accepted` **and** `ResolvedRefs=True`.
* **Evidence:**
  ```bash
  kubectl get httproute api -n lab-apps -o jsonpath='{.spec.rules[0].backendRefs[0].port}'   # 8080
  kubectl get svc httpbin -n lab-apps -o jsonpath='{.spec.ports}'                         # port 8000 → targetPort 8080
  kubectl logs -n lab-gateway deploy/edge-istio | grep api.   # response flag NC (no cluster for port 8080)
  ```
* **Root cause:** `backendRefs.port` is the Service port. Istio doesn't validate it in status — runtime failure only.
* **Fix:** golden route (8000).

### M13 — sidecar-lab is silently out of the mesh
* **Symptom:** `tests/40-mtls.sh`: legacy → sidecar-lab **succeeds** under STRICT; no XFCC header.
* **Evidence:**
  ```bash
  kubectl get ns sidecar-lab --show-labels                       # istio-injection=enable  (not "enabled")
  kubectl get pods -n sidecar-lab                                # 1/1 READY - no sidecar
  istioctl x check-inject -n sidecar-lab deploy/httpbin
  ```
* **Root cause:** only the exact value `enabled` triggers injection. No sidecar ⇒ nothing enforces STRICT.
* **Fix:** `kubectl label ns sidecar-lab istio-injection=enabled --overwrite && kubectl rollout restart deploy -n sidecar-lab`.

### M14 — The ambient client opted itself out
* **Symptom:** ambient-lab curl → ambient-lab httpbin = `RESET` under STRICT.
* **Evidence:**
  ```bash
  istioctl ztunnel-config workload | grep ambient-lab            # curl-… PROTOCOL TCP (httpbin HBONE)
  kubectl get deploy curl -n ambient-lab -o jsonpath='{.spec.template.metadata.labels}'   # istio.io/dataplane-mode: none
  ```
* **Fix:** remove the pod-template label:
  `kubectl patch deploy curl -n ambient-lab --type=json -p='[{"op":"remove","path":"/spec/template/metadata/labels/istio.io~1dataplane-mode"}]'`
  (a plain `kubectl apply` of the golden file does **not** remove labels added by `kubectl patch` — three-way merge).

### M15 — Waypoint label names a waypoint that doesn't exist
* **Symptom:** `/forbidden` returns **200** instead of 403 (after M14 is fixed).
* **Evidence:**
  ```bash
  kubectl get ns ambient-lab -L istio.io/use-waypoint             # ambient-waypoint
  kubectl get gateway -n ambient-lab                               # only "waypoint"
  istioctl ztunnel-config service | grep ambient-lab               # WAYPOINT None
  ```
* **Root cause:** ztunnel sends traffic directly when the named waypoint doesn't exist → L7 policy never runs.
* **Fix:** `kubectl label ns ambient-lab istio.io/use-waypoint=waypoint --overwrite`. Harden with the
  `require-waypoint` policy from docs/03.

---

## Which check would have caught it before users did?
| Fault | Caught by |
|---|---|
| M01 | `tests/00-platform.sh` (association + pod env) |
| M02 | `terraform plan` drift; Terraform test `golden_plan` asserts every public subnet is tagged |
| M03, M06 | `tests/10-edge.sh` (listener cert ARN, target health) |
| M04 | `tests/00-platform.sh` (domain filter), `tests/10-edge.sh` (authoritative DNS) |
| M05 | `scripts/30-apps.sh` waits for the ALB address |
| M07, M08, M10–M12 | `tests/20-routing.sh` + doctor duplicate-host and port checks |
| M09 | `tests/30-canary.sh` (non-200 count) + doctor endpoints |
| M13–M15 | `tests/40-mtls.sh`, `tests/50-waypoint.sh` |
