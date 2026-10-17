# 01 — AWS Load Balancer Controller pointed at the wrong region

**Story:** this is the exact failure from your previous `gateway-api-test` cluster: the controller
ran with `--aws-region=ap-southeast-2` while EKS, the VPC and the subnets were in `us-east-1`.

| | |
|---|---|
| Break | `bash scenarios/01-lbc-wrong-region/break.sh` |
| Layer | L1 controller → shows up at L3 (ALB) |
| User symptom | New/changed Ingresses never reconcile. The *existing* ALB keeps serving (nothing deletes it), which makes the fault easy to miss until the next change. |

## Investigate
```bash
kubectl describe ingress edge-alb -n lab-gateway | sed -n '/Events/,$p'     # FailedBuildModel / FailedDeployModel
kubectl logs -n kube-system deploy/aws-load-balancer-controller --since=5m | grep -iE 'error|subnet|vpc'
kubectl get deploy aws-load-balancer-controller -n kube-system \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | tr ',' '\n'    # --aws-region=?
helm get values aws-load-balancer-controller -n kube-system                 # where it came from
aws ec2 describe-vpcs --vpc-ids "$VPC_ID" --region ap-southeast-2           # the VPC "does not exist" there
```
Typical errors: `InvalidVpcID.NotFound`, `InvalidSubnetID.NotFound`, or "unable to resolve at least one subnet".
The IDs are correct — the controller is asking the **wrong regional API**.

## Root cause
Region is a *client* setting. Every AWS API call is regional; an ID that exists in us-east-1 does
not exist in ap-southeast-2. Helm `--reuse-values` + a one-off `--set region=...` silently persists.

## Fix
`bash scenarios/01-lbc-wrong-region/fix.sh` — sets `region` **and** `vpcId` and verifies the args.

## Prevent
`scripts/20-platform.sh` fails the install if `--aws-region` / `--aws-vpc-id` are not exactly what
lab.env says. Never rely on IMDS auto-discovery for these two values.
