# 02 — ACM certificate in the wrong region

| | |
|---|---|
| Break | `bash scenarios/02-acm-cert-wrong-region/break.sh` |
| Layer | L3 (ALB listener) |
| User symptom | None at first — the old listener cert keeps serving because the LBC cannot apply the change. The Ingress is silently out of sync. |

## Investigate
```bash
kubectl describe ingress edge-alb -n lab-gateway | sed -n '/Events/,$p'
kubectl logs -n kube-system deploy/aws-load-balancer-controller --since=5m | grep -i cert
ARN=$(kubectl get ingress edge-alb -n lab-gateway -o jsonpath='{.metadata.annotations.alb\.ingress\.kubernetes\.io/certificate-arn}')
echo "$ARN" | cut -d: -f4          # <- the region is INSIDE the ARN
aws acm describe-certificate --certificate-arn "$ARN" --region "$(echo "$ARN" | cut -d: -f4)" --query 'Certificate.[Status,Type,DomainName]'
```
Expect `CertificateNotFound` from ELB: an ALB can only use ACM certificates from **its own region**
(CloudFront is the exception: it wants us-east-1).

## Fix
`bash scenarios/02-acm-cert-wrong-region/fix.sh`

## Lesson
"Configured" ≠ "applied". Always compare desired (annotation) with actual (`aws elbv2 describe-listeners`).
`tests/10-edge.sh` asserts the 443 listener uses exactly the Terraform certificate ARN.
