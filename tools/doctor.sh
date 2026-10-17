#!/usr/bin/env bash
# =============================================================================
#  doctor.sh - walk the request path hop by hop and show EVIDENCE for each hop.
#
#  Browser
#    -> [L2 DNS]      Route 53 record (ExternalDNS)          -> ALB IPs?
#    -> [L3 TLS/ALB]  ACM cert, listeners, target health      (LBC built it?)
#    -> [L4 Gateway]  edge-istio pods / Service / Programmed  (istiod built it?)
#    -> [L5 Routes]   HTTPRoute Accepted / ResolvedRefs
#    -> [L6 Backend]  Service port, selector, ready endpoints
#    -> [L7 Mesh]     sidecar/ambient enrollment, mTLS mode, waypoint
#  [L1 Controllers] underpin everything: LBC, ExternalDNS, istiod, ztunnel, CNI
#
#  It does not fix anything. It tells you WHERE to look, with the command that proves it.
# =============================================================================
set -uo pipefail
source "$(dirname "$0")/../scripts/lib.sh"
load_env
kctx_check

FIRST_BAD=""
layer()  { printf '\n%s[%s]%s %s\n' "$C_CYN" "$1" "$C_OFF" "$2"; CUR="$1"; }
flag()   { bad "$*"; [[ -z "$FIRST_BAD" ]] && FIRST_BAD="$CUR"; }
hint()   { printf '      %s↳ %s%s\n' "$C_DIM" "$*" "$C_OFF"; }

# ----------------------------------------------------------------------------- L1
layer L1 "Controllers"
for spec in "kube-system deploy/aws-load-balancer-controller" "external-dns deploy/external-dns" \
            "istio-system deploy/istiod" "istio-system ds/ztunnel" "istio-system ds/istio-cni-node"; do
  read -r ns res <<<"$spec"
  if kubectl rollout status "$res" -n "$ns" --timeout=5s >/dev/null 2>&1; then ok "$ns/$res ready"; else
    flag "$ns/$res NOT ready"; hint "kubectl get pods -n $ns; kubectl describe $res -n $ns"; fi
done
args=$(kubectl get deploy aws-load-balancer-controller -n kube-system -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null)
r=$(grep -o -- '--aws-region=[a-z0-9-]*' <<<"$args" | cut -d= -f2)
[[ "$r" == "$AWS_REGION" ]] && ok "LBC region $r" || { flag "LBC region '$r' != $AWS_REGION"; hint "helm get values aws-load-balancer-controller -n kube-system"; }
for p in $(kubectl get pod -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller -o name 2>/dev/null); do
  kubectl get "$p" -n kube-system -o jsonpath='{.spec.containers[0].env[*].name}' | grep -q AWS_CONTAINER_CREDENTIALS_FULL_URI \
    || { flag "$p has no Pod Identity credentials"; hint "aws eks list-pod-identity-associations --cluster-name $CLUSTER_NAME ; then restart the pod"; }
done
le=$(kubectl logs -n kube-system deploy/aws-load-balancer-controller --since=15m 2>/dev/null | grep -iE '"level":"error"|AccessDenied|InvalidSubnet|subnets count|CertificateNotFound' | tail -3)
[[ -z "$le" ]] && ok "LBC: no errors (15m)" || { flag "LBC errors:"; sed 's/^/        /' <<<"$le" | cut -c1-300; }
de=$(kubectl logs -n external-dns deploy/external-dns --since=15m 2>/dev/null | grep -iE 'level=error|AccessDenied|no hosted zone|All records are already up to date|Desired change' | tail -3)
[[ -n "$de" ]] && { printf '      external-dns says:\n'; sed 's/^/        /' <<<"$de" | cut -c1-300; }
dfilter=$(kubectl get deploy external-dns -n external-dns -o jsonpath='{.spec.template.spec.containers[0].args}' 2>/dev/null | grep -o -- '--domain-filter=[^"]*' | cut -d= -f2)
[[ "$dfilter" == "$HOSTED_ZONE" ]] && ok "external-dns domain-filter $dfilter" || { flag "external-dns domain-filter '$dfilter' != $HOSTED_ZONE"; hint "helm get values external-dns -n external-dns"; }

# ----------------------------------------------------------------------------- L2
layer L2 "DNS  (Route 53 <- ExternalDNS)"
ALB=$(alb_hostname)
AUTH_NS=$(dig +short NS "$HOSTED_ZONE" | head -1)
ALB_IPS=$( [[ -n "$ALB" ]] && dig +short "$ALB" A | sort )
for h in "$SHOP_HOST" "$API_HOST" "$CANARY_HOST"; do
  rec=$(dig +short "@${AUTH_NS}" "$h" A | sort)
  if [[ -z "$rec" ]]; then flag "$h: NXDOMAIN/empty at $AUTH_NS"; hint "aws route53 list-resource-record-sets --hosted-zone-id $HOSTED_ZONE_ID --query \"ResourceRecordSets[?contains(Name,'${h%%.*}')]\""
  elif [[ -n "$ALB_IPS" ]] && ! comm -12 <(echo "$rec") <(echo "$ALB_IPS") | grep -q .; then flag "$h points to $(echo "$rec" | tr '\n' ' ')- not the current ALB"; hint "stale record? ExternalDNS ownership TXT: dig +short TXT a-${h} @${AUTH_NS}"
  else ok "$h -> $(echo "$rec" | tr '\n' ' ')"; fi
done

# ----------------------------------------------------------------------------- L3
layer L3 "ALB + TLS  (AWS Load Balancer Controller)"
if [[ -z "$ALB" ]]; then
  flag "Ingress edge-alb has no address - the LBC did not build an ALB"
  kubectl get events -n lab-gateway --field-selector involvedObject.name=edge-alb --sort-by=.lastTimestamp 2>/dev/null | tail -4 | cut -c1-300 | sed 's/^/        /'
  hint "kubectl describe ingress edge-alb -n lab-gateway  |  kubectl logs -n kube-system deploy/aws-load-balancer-controller | grep -i error"
else
  ok "ALB $ALB"
  LB_ARN=$(aws elbv2 describe-load-balancers --names "${CLUSTER_NAME}-edge" --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)
  cert=$(aws elbv2 describe-listeners --load-balancer-arn "$LB_ARN" --query 'Listeners[?Port==`443`].Certificates[0].CertificateArn' --output text 2>/dev/null)
  if [[ "$cert" == "$ACM_CERT_ARN" ]]; then ok "443 cert = Terraform ACM cert"; else
    flag "443 cert is $cert"; aws acm describe-certificate --certificate-arn "$cert" --query 'Certificate.[DomainName,SubjectAlternativeNames,Type,Status]' --output text 2>/dev/null | sed 's/^/        /'
    hint "kubectl get ingress edge-alb -n lab-gateway -o jsonpath='{.metadata.annotations.alb\\.ingress\\.kubernetes\\.io/certificate-arn}'"; fi
  san=$(echo | timeout 8 openssl s_client -connect "${ALB}:443" -servername "$SHOP_HOST" 2>/dev/null | openssl x509 -noout -ext subjectAltName 2>/dev/null | tail -1)
  [[ "$san" == *"*.${DOMAIN}"* ]] && ok "TLS SAN: $(echo "$san" | xargs)" || flag "TLS SAN for SNI $SHOP_HOST: '$(echo "$san" | xargs)'"
  TG=$(kubectl get targetgroupbinding -n lab-gateway -o jsonpath='{.items[0].spec.targetGroupARN}' 2>/dev/null)
  if [[ -n "$TG" ]]; then
    aws elbv2 describe-target-health --target-group-arn "$TG" \
      --query 'TargetHealthDescriptions[].[Target.Id,Target.Port,TargetHealth.State,TargetHealth.Reason,TargetHealth.Description]' --output text 2>/dev/null \
      | while read -r id port st rest; do
          if [[ "$st" == "healthy" ]]; then ok "target $id:$port healthy"; else bad "target $id:$port $st $rest"; fi
        done
    unhealthy=$(aws elbv2 describe-target-health --target-group-arn "$TG" --query 'length(TargetHealthDescriptions[?TargetHealth.State!=`healthy`])' --output text 2>/dev/null)
    [[ "${unhealthy:-0}" != "0" ]] && { flag "$unhealthy unhealthy target(s)"; hint "aws elbv2 describe-target-groups --target-group-arns $TG --query 'TargetGroups[0].[HealthCheckPort,HealthCheckPath,Matcher]'"; hint "NOTE: if ALL targets are unhealthy the ALB fails OPEN and still forwards traffic"; }
  else flag "no TargetGroupBinding in lab-gateway"; fi
fi

# ----------------------------------------------------------------------------- L4
layer L4 "Istio edge Gateway  (istiod deploys it from the Gateway resource)"
prog=$(kubectl get gateway edge -n lab-gateway -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
[[ "$prog" == "True" ]] && ok "Gateway edge Programmed" || { flag "Gateway edge Programmed=$prog"; kubectl get gateway edge -n lab-gateway -o jsonpath='{range .status.conditions[*]}{.type}={.status} {.reason}: {.message}{"\n"}{end}' | sed 's/^/        /'; }
kubectl get gateway edge -n lab-gateway -o jsonpath='{range .status.listeners[*]}{.name}: attachedRoutes={.attachedRoutes} {range .conditions[?(@.status=="False")]}[{.type}={.status} {.reason}]{end}{"\n"}{end}' 2>/dev/null | sed 's/^/      listener /'
from=$(kubectl get gateway edge -n lab-gateway -o jsonpath='{.spec.listeners[0].allowedRoutes.namespaces.from}')
hn=$(kubectl get gateway edge -n lab-gateway -o jsonpath='{.spec.listeners[0].hostname}')
printf '      allowedRoutes.from=%s  listener hostname=%s\n' "$from" "$hn"
ready=$(kubectl get deploy edge-istio -n lab-gateway -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[[ "${ready:-0}" -ge 1 ]] && ok "edge-istio ready replicas: $ready" || flag "edge-istio has no ready pods"

# ----------------------------------------------------------------------------- L5
layer L5 "HTTPRoutes  (attachment + references)"
kubectl get httproute -A -o json 2>/dev/null | jq -r '
  .items[] | . as $r | ($r.status.parents // [{}])[] |
  "\($r.metadata.namespace)/\($r.metadata.name)\t\($r.spec.hostnames // ["*"] | join(","))\t" +
  ([.conditions[]? | select(.status=="False") | "\(.type)=False(\(.reason))"] | join(" ")) +
  "\t\($r.metadata.creationTimestamp)"' | while IFS=$'\t' read -r name hosts conds created; do
    if [[ -z "$conds" ]]; then ok "$name [$hosts] created $created"; else bad "$name [$hosts] $conds"; fi
  done
kubectl get httproute -A -o json | jq -e '[.items[].status.parents[]?.conditions[]? | select(.status=="False")] | length > 0' >/dev/null 2>&1 \
  && { flag "some HTTPRoute has a False condition"; hint "kubectl get httproute <name> -n lab-apps -o jsonpath='{.status}' | jq"; }
dup=$(kubectl get httproute -A -o json | jq -r '[.items[] | .spec.hostnames[]?] | group_by(.) | map(select(length>1)) | .[][0]' | sort -u)
[[ -n "$dup" ]] && { flag "hostname(s) claimed by MORE than one HTTPRoute: $dup"; hint "on equal matches the OLDEST route wins - check creationTimestamp above"; }

# ----------------------------------------------------------------------------- L6
layer L6 "Backends  (backendRef -> Service port -> ready endpoints)"
while IFS=$'\t' read -r route rule svc port weight; do
  if ! kubectl get svc "$svc" -n lab-apps >/dev/null 2>&1; then flag "$route/$rule -> svc/$svc does not exist"; continue; fi
  ports=$(kubectl get svc "$svc" -n lab-apps -o jsonpath='{.spec.ports[*].port}')
  eps=$(kubectl get endpointslices -n lab-apps -l kubernetes.io/service-name="$svc" -o json | jq '[.items[].endpoints[]? | select(.conditions.ready==true)] | length')
  if [[ " $ports " != *" $port "* ]]; then flag "$route/$rule -> $svc:$port but Service ports are [$ports]"
  elif [[ "$eps" == "0" ]]; then flag "$route/$rule -> $svc:$port (weight $weight) has 0 ready endpoints"; hint "kubectl get svc $svc -n lab-apps -o jsonpath='{.spec.selector}' vs kubectl get pods -n lab-apps --show-labels"
  else ok "$route/$rule -> $svc:$port weight=$weight endpoints=$eps"; fi
done < <(kubectl get httproute -n lab-apps -o json | jq -r '.items[] | .metadata.name as $r | .spec.rules[] | (.name // "-") as $n | .backendRefs[]? | "\($r)\t\($n)\t\(.name)\t\(.port)\t\(.weight // 1)"' | sort -u)

# ----------------------------------------------------------------------------- L7
layer L7 "Mesh  (enrollment, mTLS, waypoint)"
for ns in lab-apps sidecar-lab ambient-lab legacy-lab; do
  inj=$(kubectl get ns "$ns" -o jsonpath='{.metadata.labels.istio-injection}')
  amb=$(kubectl get ns "$ns" -o jsonpath='{.metadata.labels.istio\.io/dataplane-mode}')
  wp=$(kubectl get ns "$ns" -o jsonpath='{.metadata.labels.istio\.io/use-waypoint}')
  pa=$(kubectl get peerauthentication -n "$ns" -o jsonpath='{.items[*].spec.mtls.mode}' 2>/dev/null)
  pods_wo=$(kubectl get pods -n "$ns" -o json | jq -r '[.items[] | select(([.spec.containers[].name] + [.spec.initContainers[]?.name]) | index("istio-proxy") | not) | .metadata.name] | join(",")')
  printf '      %-12s injection=%-8s dataplane=%-8s use-waypoint=%-9s mTLS=%-10s pods-without-sidecar=[%s]\n' \
    "$ns" "${inj:--}" "${amb:--}" "${wp:--}" "${pa:-PERMISSIVE}" "$pods_wo"
  if [[ -n "$inj" && "$inj" != "enabled" ]]; then flag "$ns: istio-injection='$inj' (only 'enabled' works)"; fi
  if [[ "$inj" == "enabled" && -n "$pods_wo" ]]; then flag "$ns: injection enabled but pods without sidecar: $pods_wo (created before the label? restart them)"; fi
  if [[ -n "$wp" ]] && ! kubectl get gateway "$wp" -n "$ns" >/dev/null 2>&1; then flag "$ns: use-waypoint=$wp but no Gateway '$wp' exists -> L7 policy silently bypassed"; fi
done
nohbone=$(istioctl ztunnel-config workload 2>/dev/null | awk '$1=="ambient-lab" && $NF!="HBONE" && $2 !~ /^waypoint/ {print $2}' | tr '\n' ' ')
[[ -z "$nohbone" ]] && ok "all ambient-lab workloads are HBONE" || { flag "ambient-lab workloads NOT in ambient: $nohbone"; hint "kubectl get pod <pod> -n ambient-lab -o jsonpath='{.metadata.labels}' (istio.io/dataplane-mode=none opts a pod out)"; }
an=$(istioctl analyze -A 2>&1 | grep -E 'Error|Warning' | head -5)
[[ -z "$an" ]] && ok "istioctl analyze: clean" || { printf '      istioctl analyze:\n'; sed 's/^/        /' <<<"$an" | cut -c1-250; }

# ----------------------------------------------------------------------------- recent events
printf '\n%s[events]%s last warnings in lab namespaces\n' "$C_CYN" "$C_OFF"
for ns in lab-gateway lab-apps sidecar-lab ambient-lab; do
  kubectl get events -n "$ns" --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -2 | grep -v '^LAST' | cut -c1-220 | sed "s/^/      $ns: /"
done

echo
if [[ -n "$FIRST_BAD" ]]; then
  printf '%sLowest broken layer: %s%s  -> docs/MASTER-TROUBLESHOOTING.md section %s\n' "$C_RED" "$FIRST_BAD" "$C_OFF" "$FIRST_BAD"
  exit 1
fi
printf '%sNo problems detected on the request path.%s\n' "$C_GRN" "$C_OFF"
