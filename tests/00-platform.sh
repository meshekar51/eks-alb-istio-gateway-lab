#!/usr/bin/env bash
# L1-L2: cluster + controllers. If this fails, nothing above it can work.
set -uo pipefail
source "$(dirname "$0")/lib.sh"
kctx_check

section "Cluster"
nodes_ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l)
(( nodes_ready >= 2 )) && pass "$nodes_ready nodes Ready" || fail "only $nodes_ready nodes Ready"

section "Gateway API CRDs"
bv=$(kubectl get crd gateways.gateway.networking.k8s.io -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version}' 2>/dev/null)
[[ "$bv" == "$GATEWAY_API_VERSION" ]] && pass "Gateway API CRDs $bv" || fail "Gateway API CRDs bundle-version='$bv' (want $GATEWAY_API_VERSION)"

section "AWS Load Balancer Controller"
avail=$(kubectl get deploy aws-load-balancer-controller -n kube-system -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
[[ "${avail:-0}" -ge 1 ]] && pass "LBC available replicas: $avail" || fail "LBC not available"
args=$(kubectl get deploy aws-load-balancer-controller -n kube-system -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null)
grep -q -- "--aws-region=${AWS_REGION}\"" <<<"$args" && pass "LBC --aws-region=${AWS_REGION}" || fail "LBC region flag is not ${AWS_REGION}: $(grep -o -- '--aws-region=[a-z0-9-]*' <<<"$args")"
grep -q -- "--aws-vpc-id=${VPC_ID}\"" <<<"$args" && pass "LBC --aws-vpc-id=${VPC_ID}" || fail "LBC vpc flag is not ${VPC_ID}"
pia=$(aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME" \
  --query "associations[?namespace=='kube-system' && serviceAccount=='aws-load-balancer-controller'] | length(@)" --output text 2>/dev/null)
[[ "$pia" == "1" ]] && pass "Pod Identity association kube-system/aws-load-balancer-controller" || fail "Pod Identity association for kube-system/aws-load-balancer-controller missing ($pia)"
for p in $(kubectl get pod -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller -o name 2>/dev/null); do
  kubectl get "$p" -n kube-system -o jsonpath='{.spec.containers[0].env[*].name}' | grep -q AWS_CONTAINER_CREDENTIALS_FULL_URI \
    && pass "$p has Pod Identity credentials" || fail "$p has NO Pod Identity credentials (created before the association? restart it)"
done
errs=$(kubectl logs -n kube-system deploy/aws-load-balancer-controller --since=10m 2>/dev/null | grep -ciE 'AccessDenied|UnauthorizedOperation|InvalidSubnet|NoCredentialProviders|error' || true)
[[ "${errs:-0}" -eq 0 ]] && pass "LBC: no errors in last 10m" || note "LBC: $errs error lines in last 10m (kubectl logs -n kube-system deploy/aws-load-balancer-controller | grep -i error)"

section "Istio"
for r in deploy/istiod ds/istio-cni-node ds/ztunnel; do
  kubectl rollout status "$r" -n istio-system --timeout=10s >/dev/null 2>&1 && pass "$r ready" || fail "$r not ready"
done
ver=$(kubectl get deploy istiod -n istio-system -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
[[ "$ver" == *":${ISTIO_VERSION}"* ]] && pass "istiod image $ver" || note "istiod image $ver (expected ${ISTIO_VERSION})"
for gc in istio istio-waypoint; do
  s=$(kubectl get gatewayclass "$gc" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
  [[ "$s" == "True" ]] && pass "GatewayClass $gc Accepted" || fail "GatewayClass $gc Accepted=$s"
done

section "ExternalDNS"
avail=$(kubectl get deploy external-dns -n external-dns -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
[[ "${avail:-0}" -ge 1 ]] && pass "external-dns available" || fail "external-dns not available"
dargs=$(kubectl get deploy external-dns -n external-dns -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null)
grep -q -- "--domain-filter=${HOSTED_ZONE}\"" <<<"$dargs" && pass "external-dns --domain-filter=${HOSTED_ZONE}" || fail "external-dns domain filter is not ${HOSTED_ZONE}: $(grep -o -- '--domain-filter=[^\"]*' <<<"$dargs")"
derr=$(kubectl logs -n external-dns deploy/external-dns --since=10m 2>/dev/null | grep -ciE 'level=error|AccessDenied' || true)
[[ "${derr:-0}" -eq 0 ]] && pass "external-dns: no errors in last 10m" || note "external-dns: $derr error lines in last 10m"

summary "00-platform"
