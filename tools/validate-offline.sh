#!/usr/bin/env bash
# Offline checks - no AWS, no cluster. Used by CI (.github/workflows/validate.yaml) and `make validate`.
#   1. terraform fmt + validate
#   2. shellcheck every script
#   3. render every manifest with dummy values (catches unrendered ${VARS})
#   4. kubeconform: core kinds + Gateway API / Istio CRD schemas
#   5. istioctl validate on the Istio + Gateway API objects
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; cd "$ROOT" || exit 1
rc=0; step() { printf '\n\033[1;36m== %s\033[0m\n' "$*"; }; failed() { echo "  FAILED: $*"; rc=1; }

step "terraform fmt / validate"
if command -v terraform >/dev/null; then
  terraform -chdir=infra/terraform fmt -check -recursive || failed "terraform fmt"
  terraform -chdir=infra/terraform init -backend=false -input=false >/dev/null && \
  terraform -chdir=infra/terraform validate || failed "terraform validate"
else echo "  (terraform not installed - skipped)"; fi

step "shellcheck"
if command -v shellcheck >/dev/null; then
  mapfile -t SH < <(git ls-files '*.sh' 2>/dev/null || find . -name '*.sh' -not -path './.git/*')
  shellcheck -S warning -x "${SH[@]}" || failed "shellcheck"
else echo "  (shellcheck not installed - skipped)"; fi

step "render manifests with dummy values"
export DOMAIN=lab.example.org HOSTED_ZONE=example.org HOSTED_ZONE_ID=Z0000000000000 AWS_REGION=us-east-1 \
  CLUSTER_NAME=istio-gateway-lab VPC_ID=vpc-0123456789abcdef0 \
  ACM_CERT_ARN=arn:aws:acm:us-east-1:111122223333:certificate/00000000-0000-0000-0000-000000000000 \
  SHOP_HOST=shop.lab.example.org API_HOST=api.lab.example.org CANARY_HOST=canary.lab.example.org \
  PODINFO_V1_IMAGE=ghcr.io/stefanprodan/podinfo:6.14.1 PODINFO_V2_IMAGE=ghcr.io/stefanprodan/podinfo:6.15.0 \
  HTTPBIN_IMAGE=docker.io/mccutchen/go-httpbin:v2.15.0 CURL_IMAGE=docker.io/curlimages/curl:8.16.0 \
  CANARY_V1_WEIGHT=90 CANARY_V2_WEIGHT=10 REVIEWS_V1_WEIGHT=90 REVIEWS_V2_WEIGHT=10 \
  REVIEWS_V1_IMAGE=registry.istio.io/release/examples-bookinfo-reviews-v1:1.20.3 \
  REVIEWS_V2_IMAGE=registry.istio.io/release/examples-bookinfo-reviews-v2:1.20.3 \
  RATINGS_IMAGE=registry.istio.io/release/examples-bookinfo-ratings-v1:1.20.3
VARS='${DOMAIN} ${HOSTED_ZONE} ${HOSTED_ZONE_ID} ${AWS_REGION} ${CLUSTER_NAME} ${VPC_ID} ${ACM_CERT_ARN} ${SHOP_HOST} ${API_HOST} ${CANARY_HOST} ${PODINFO_V1_IMAGE} ${PODINFO_V2_IMAGE} ${HTTPBIN_IMAGE} ${CURL_IMAGE} ${CANARY_V1_WEIGHT} ${CANARY_V2_WEIGHT} ${REVIEWS_V1_IMAGE} ${REVIEWS_V2_IMAGE} ${RATINGS_IMAGE} ${REVIEWS_V1_WEIGHT} ${REVIEWS_V2_WEIGHT}'
OUT=$(mktemp -d); trap 'rm -rf "$OUT"' EXIT
while IFS= read -r f; do
  mkdir -p "$OUT/$(dirname "$f")"
  envsubst "$VARS" < "$f" > "$OUT/$f"
  grep -q '\${[A-Z_]*}' "$OUT/$f" && failed "unrendered variable in $f"
done < <(find k8s messy/manifests platform -name '*.yaml' | sort)
echo "  rendered $(find "$OUT" -name '*.yaml' | wc -l) files"

step "kubeconform (strict, with Gateway API + Istio CRD schemas)"
if command -v kubeconform >/dev/null; then
  kubeconform -strict -summary -ignore-missing-schemas=false \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
    -skip IstioOperator \
    "$OUT/k8s" "$OUT/messy/manifests" || failed "kubeconform"
else echo "  (kubeconform not installed - skipped)"; fi

step "istioctl validate"
if command -v istioctl >/dev/null; then
  for f in "$OUT"/k8s/mesh/*.yaml "$OUT"/k8s/gateway/*.yaml "$OUT"/k8s/routes/*.yaml; do
    istioctl validate -f "$f" >/dev/null 2>"$OUT/iv.err" || { cat "$OUT/iv.err"; failed "istioctl validate $f"; }
  done
  echo "  ok"
else echo "  (istioctl not installed - skipped)"; fi

echo; [[ $rc -eq 0 ]] && echo "ALL OFFLINE CHECKS PASSED" || echo "SOME CHECKS FAILED"
exit $rc
