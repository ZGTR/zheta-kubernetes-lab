SHELL := /bin/bash

REPO_ROOT := $(CURDIR)
CLUSTER_NAME ?= helixworks-local
KUBECONFIG := $(REPO_ROOT)/.kube/config
export CLUSTER_NAME
export KUBECONFIG

.PHONY: check up cni-probe image deploy product-images product-deploy product-local product-smoke product-stop mesh-render mesh-verify watch serve kill-pod node-down node-up argocd-up argocd-forge drift verify destroy

check:
	./scripts/check-tools.sh

up: check
	mkdir -p .kube .lab
	terraform -chdir=terraform init
	terraform -chdir=terraform apply -auto-approve -var="cluster_name=$(CLUSTER_NAME)"
	./scripts/verify-kind-network-policy.sh
	kubectl get nodes -o wide

cni-probe:
	./scripts/probe-network-policy.sh

image:
	./scripts/build-and-load.sh

deploy: image
	kubectl apply -k gitops/apps/helixworks/base
	kubectl -n helixworks rollout status deployment/helixworks --timeout=120s
	kubectl -n helixworks get deployment,pods -o wide

product-images:
	./scripts/build-forge-images.sh

product-deploy: product-images
	kubectl apply -k gitops/apps/forge/overlays/local
	kubectl -n helixworks-forge rollout status deployment --all --timeout=180s

product-local:
	docker compose up --build -d

product-smoke:
	./scripts/smoke-product.sh

product-stop:
	docker compose down

mesh-render:
	kubectl kustomize gitops/apps/forge/overlays/ambient-local

mesh-verify:
	./scripts/verify-ambient-source.sh

watch:
	./scripts/watch.sh

serve:
	@echo "Open http://localhost:8080; stop with Ctrl-C."
	kubectl -n helixworks port-forward service/helixworks 8080:80

kill-pod:
	./scripts/failure.sh pod

node-down:
	./scripts/failure.sh node-down

node-up:
	./scripts/failure.sh node-up

argocd-up: image
	./scripts/install-argocd.sh

argocd-forge:
	kubectl apply -f argocd/project.yaml
	kubectl apply -f argocd/applicationsets/forge-local.yaml

drift:
	./scripts/gitops-drift.sh

verify:
	./scripts/verify.sh
	./scripts/verify-platform.sh

destroy:
	terraform -chdir=terraform destroy -auto-approve -var="cluster_name=$(CLUSTER_NAME)"
