# 10 — LBC down ⇒ nobody can create a Service

| | |
|---|---|
| Break | `bash scenarios/10-lbc-down-blocks-service-creation/break.sh` |
| Layer | L1 (admission webhooks) |
| User symptom | `Internal error occurred: failed calling webhook "mservice.elbv2.k8s.aws": ... no endpoints available for service "aws-load-balancer-webhook-service"` — on **every** Service create, including the Services istiod generates for gateways and waypoints. |

## Why
The LBC chart registers a mutating webhook for Services with `failurePolicy: Fail`
(`serviceMutatorWebhookConfig.failurePolicy`). With zero controller pods, the API server cannot call it and refuses.
The existing ALB keeps working — it's the *changes* that fail.

```bash
kubectl get mutatingwebhookconfigurations aws-load-balancer-webhook -o jsonpath='{range .webhooks[*]}{.name}{"  failurePolicy="}{.failurePolicy}{"\n"}{end}'
kubectl get endpoints -n kube-system aws-load-balancer-webhook-service
```

## Fix
`bash scenarios/10-lbc-down-blocks-service-creation/fix.sh`. In production: keep ≥2 replicas + a PodDisruptionBudget, or
set `enableServiceMutatorWebhook=false` if you never use the LBC for `type: LoadBalancer` Services.
