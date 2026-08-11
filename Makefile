SHELL := /bin/bash

REPO_ROOT := $(CURDIR)
CLUSTER_NAME ?= zheta-local
KUBECONFIG := $(REPO_ROOT)/.kube/config
export CLUSTER_NAME
export KUBECONFIG

.PHONY: check up image deploy watch serve kill-pod node-down node-up argocd-up drift verify destroy

check:
	./scripts/check-tools.sh

up: check
	mkdir -p .kube .lab
	terraform -chdir=terraform init
	terraform -chdir=terraform apply -auto-approve -var="cluster_name=$(CLUSTER_NAME)"
	kubectl get nodes -o wide

image:
	./scripts/build-and-load.sh

deploy: image
	kubectl apply -k gitops/apps/zheta/base
	kubectl -n zheta rollout status deployment/zheta --timeout=120s
	kubectl -n zheta get deployment,pods -o wide

watch:
	./scripts/watch.sh

serve:
	@echo "Open http://localhost:8080; stop with Ctrl-C."
	kubectl -n zheta port-forward service/zheta 8080:80

kill-pod:
	./scripts/failure.sh pod

node-down:
	./scripts/failure.sh node-down

node-up:
	./scripts/failure.sh node-up

argocd-up: image
	./scripts/install-argocd.sh

drift:
	./scripts/gitops-drift.sh

verify:
	./scripts/verify.sh

destroy:
	terraform -chdir=terraform destroy -auto-approve -var="cluster_name=$(CLUSTER_NAME)"

