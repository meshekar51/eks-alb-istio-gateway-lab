#!/usr/bin/env bash
# Snapshot the FAILING state before you change anything (rule #1 of troubleshooting).
#   tools/collect-evidence.sh [label]   -> evidence/<timestamp>-<label>.tar.gz
set -uo pipefail
source "$(dirname "$0")/../scripts/lib.sh"
load_env
kctx_check
TS=$(date -u +%Y%m%dT%H%M%SZ); LABEL="${1:-snapshot}"
OUT="$LAB_ROOT/evidence/${TS}-${LABEL}"; mkdir -p "$OUT"/{k8s,logs,aws,istio}
c() { local f="$1"; shift; { echo "\$ $*"; "$@"; } > "$OUT/$f" 2>&1; }

log "Kubernetes objects"
c k8s/nodes.txt kubectl get nodes -o wide
c k8s/pods.txt kubectl get pods -A -o wide
c k8s/events.txt kubectl get events -A --sort-by=.lastTimestamp
c k8s/gateway-api.yaml kubectl get gatewayclass,gateway,httproute,referencegrant -A -o yaml
c k8s/ingress.yaml kubectl get ingress,ingressclass,ingressclassparams,targetgroupbinding -A -o yaml
c k8s/services-endpoints.txt kubectl get svc,endpointslices -n lab-apps -o wide
c k8s/namespaces.txt kubectl get ns --show-labels
c k8s/istio-security.yaml kubectl get peerauthentication,authorizationpolicy,requestauthentication -A -o yaml
c k8s/istio-networking.yaml kubectl get virtualservice,destinationrule,serviceentry,sidecar -A -o yaml
c k8s/describe-ingress.txt kubectl describe ingress edge-alb -n lab-gateway
c k8s/describe-gateway.txt kubectl describe gateway -A
c k8s/describe-httproutes.txt kubectl describe httproute -A

log "Controller logs"
c logs/lbc.log kubectl logs -n kube-system deploy/aws-load-balancer-controller --since=1h --all-containers
c logs/external-dns.log kubectl logs -n external-dns deploy/external-dns --since=1h
c logs/istiod.log kubectl logs -n istio-system deploy/istiod --since=1h
c logs/ztunnel.log kubectl logs -n istio-system -l app=ztunnel --since=30m --tail=-1 --prefix
c logs/edge-gateway.log kubectl logs -n lab-gateway deploy/edge-istio --since=30m
c logs/waypoint.log kubectl logs -n ambient-lab deploy/waypoint --since=30m
c logs/lab-apps-sidecars.log kubectl logs -n lab-apps -l app=podinfo -c istio-proxy --since=30m --tail=200 --prefix

log "Istio"
c istio/proxy-status.txt istioctl proxy-status
c istio/analyze.txt istioctl analyze -A
c istio/ztunnel-workloads.txt istioctl ztunnel-config workload
c istio/ztunnel-services.txt istioctl ztunnel-config service
c istio/ztunnel-policies.txt istioctl ztunnel-config policy
c istio/edge-routes.txt istioctl proxy-config route deploy/edge-istio -n lab-gateway
c istio/edge-clusters.txt istioctl proxy-config cluster deploy/edge-istio -n lab-gateway
c istio/waypoint-status.txt istioctl waypoint status -n ambient-lab

log "AWS"
c aws/identity.json aws sts get-caller-identity
c aws/pod-identity.json aws eks list-pod-identity-associations --cluster-name "$CLUSTER_NAME"
c aws/subnets.json aws ec2 describe-subnets --filters "Name=vpc-id,Values=${VPC_ID}" --query 'Subnets[].{id:SubnetId,az:AvailabilityZone,cidr:CidrBlock,free:AvailableIpAddressCount,tags:Tags}'
c aws/load-balancers.json aws elbv2 describe-load-balancers --names "${CLUSTER_NAME}-edge"
LB_ARN=$(aws elbv2 describe-load-balancers --names "${CLUSTER_NAME}-edge" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)
[[ -n "$LB_ARN" && "$LB_ARN" != "None" ]] && c aws/listeners.json aws elbv2 describe-listeners --load-balancer-arn "$LB_ARN"
TG=$(kubectl get targetgroupbinding -n lab-gateway -o jsonpath='{.items[0].spec.targetGroupARN}' 2>/dev/null)
[[ -n "$TG" ]] && c aws/target-health.json aws elbv2 describe-target-health --target-group-arn "$TG"
[[ -n "$TG" ]] && c aws/target-group.json aws elbv2 describe-target-groups --target-group-arns "$TG"
c aws/acm.json aws acm list-certificates --includes keyTypes=RSA_2048,EC_prime256v1
c aws/route53-records.json aws route53 list-resource-record-sets --hosted-zone-id "$HOSTED_ZONE_ID" --query "ResourceRecordSets[?ends_with(Name, '${DOMAIN}.')]"

log "Doctor"
bash "$LAB_ROOT/tools/doctor.sh" > "$OUT/doctor.txt" 2>&1 || true

tar -czf "$OUT.tar.gz" -C "$LAB_ROOT/evidence" "$(basename "$OUT")" && rm -rf "$OUT"
ok "Evidence: $OUT.tar.gz"
