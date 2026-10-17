SHELL := /bin/bash
.DEFAULT_GOAL := help

## ---------------------------------------------------------------- build
tools:        ## install pinned kubectl/helm/terraform/istioctl on the bastion
	bash bootstrap/install-tools.sh
infra:        ## terraform: VPC, EKS, nodes, Pod Identity, ACM cert (~15-20 min)
	bash scripts/10-infra.sh
kubeconfig:   ## (re)write kubeconfig for the lab cluster
	bash scripts/kubeconfig.sh
platform:     ## Gateway API CRDs, AWS LBC, Istio ambient, ExternalDNS
	bash scripts/20-platform.sh
apps:         ## namespaces, apps, edge Gateway, HTTPRoutes, ALB Ingress, mesh labs
	bash scripts/30-apps.sh
lab: infra platform apps  ## everything above, in order
reviews:      ## OPTIONAL: Bookinfo reviews-v1/v2 behind the same ALB, 90/10 (make reviews V1=50 V2=50)
	bash scripts/40-reviews.sh $(V1) $(V2)

## ---------------------------------------------------------------- verify
test:         ## all layers bottom-up (platform, edge, routing, canary, mTLS, waypoint)
	bash tests/run-all.sh
test-platform: ; bash tests/00-platform.sh
test-edge:     ; bash tests/10-edge.sh
test-routing:  ; bash tests/20-routing.sh
test-canary:   ; bash tests/30-canary.sh
test-mtls:     ; bash tests/40-mtls.sh
test-waypoint: ; bash tests/50-waypoint.sh
doctor:       ## walk the request path hop by hop with evidence
	bash tools/doctor.sh
evidence:     ## snapshot everything into evidence/*.tar.gz BEFORE you change anything
	bash tools/collect-evidence.sh $(LABEL)

## ---------------------------------------------------------------- canary
canary-status:   ## show weights + sample 100 requests
	bash tools/canary.sh status
canary-set:      ## make canary-set V1=50 V2=50
	bash tools/canary.sh set $(V1) $(V2)
canary-rollout:  ## progressive rollout with automatic rollback on errors
	bash tools/canary.sh rollout
canary-rollback: ## 100% to v1 now
	bash tools/canary.sh rollback

## ---------------------------------------------------------------- messy lab
messy:        ## plant 15 faults across every layer (spoilers in messy/break-everything.sh)
	bash messy/break-everything.sh
messy-score:  ## remaining faults per layer, no spoilers
	bash messy/score.sh
unmess:       ## give up: reconcile everything back to git + terraform
	bash messy/restore-golden.sh

## ---------------------------------------------------------------- teardown
destroy:      ## ALB + DNS first, then controllers, then terraform destroy
	bash scripts/90-destroy.sh

## ---------------------------------------------------------------- offline checks (CI)
validate:     ## offline: terraform fmt/validate, shellcheck, yaml, kubeconform, istioctl validate
	bash tools/validate-offline.sh

help:
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'
