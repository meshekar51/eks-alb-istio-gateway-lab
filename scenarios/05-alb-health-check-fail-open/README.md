# 05 — Every target unhealthy… and the site still works (ALB fail-open)

| | |
|---|---|
| Break | `bash scenarios/05-alb-health-check-fail-open/break.sh` |
| Layer | L3 |
| User symptom | **None.** Traffic keeps flowing. Only the target group / `tests/10-edge.sh` show it. |

## Investigate
```bash
TG=$(kubectl get targetgroupbinding -n lab-gateway -o jsonpath='{.items[0].spec.targetGroupARN}')
aws elbv2 describe-target-health --target-group-arn "$TG" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State,TargetHealth.Reason,TargetHealth.Description]' --output table
aws elbv2 describe-target-groups --target-group-arns "$TG" --query 'TargetGroups[0].[HealthCheckPort,HealthCheckPath,Matcher.HttpCode]'
```

## Why it still works
When **no** target in any enabled AZ is healthy, an ALB *fails open* and routes to all targets. So a broken
health check does not take you down — until one target becomes healthy, and then **all** traffic goes to that one.
Health checks that never pass are a time bomb, not a nuisance.

## Why 15021 and not 80
`/healthz/ready` on Istio's status port 15021 answers 200 when Envoy is ready. Port 80 would only answer for a
matching `Host` header → 404 → unhealthy.

## Fix
`bash scenarios/05-alb-health-check-fail-open/fix.sh`
