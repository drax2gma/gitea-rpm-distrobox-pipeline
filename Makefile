SHELL := /usr/bin/env bash
.DEFAULT_GOAL := help

# Local infra overlay (gitignored): REPO, GITEA_URL, BUILD_HOST, REMOTES,
# BUILD_RUNNER, DEPLOY_RUNNER, ARTIFACT_BASE. See infra.env.example.
-include infra.env

REPO      ?= example-org/gitea-rpm-distrobox-pipeline
GITEA_URL ?= https://gitea.example.com
BUILD_HOST ?= build-host
REMOTES   ?= gitea github
WORKFLOW  ?= build-rpm.yml
REF       ?= main
# CI variables `make vars-push` uploads (read by `${{ vars.X || 'default' }}`).
VARS      ?= BUILD_RUNNER DEPLOY_RUNNER ARTIFACT_BASE
BUILD_RUNNER  ?= rhel7-ol7
DEPLOY_RUNNER ?= deploy-host
ARTIFACT_BASE ?= /home/runner/el7-artifacts
export BUILD_RUNNER DEPLOY_RUNNER ARTIFACT_BASE

# Gitea API token from the tea login (evaluated by the shell at recipe time).
TOKEN = $$(python3 -c "import yaml,os;print(yaml.safe_load(open(os.path.expanduser('~/.config/tea/config.yml')))['logins'][0]['token'])")

.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
	  | awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.PHONY: ci
ci: ## Commit and push to all remotes (does NOT trigger the build)
	@test -n "$(m)" || { echo "usage: make ci m='commit message'" >&2; exit 2; }
	git add -A && git commit -m "$(m)"
	$(MAKE) push

.PHONY: push
push: ## Push main to every remote (gitea + github)
	@for r in $(REMOTES); do \
	  echo "==> pushing to $$r"; git push $$r main || exit 1; \
	done

.PHONY: push-gitea
push-gitea: ## Push main to Gitea only
	git push gitea main

.PHONY: push-github
push-github: ## Push main to GitHub only
	git push github main

.PHONY: ci-build
ci-build: ## Trigger the Gitea build workflow (manual dispatch)
	@curl -fsSL -o /dev/null -w "triggered $(WORKFLOW) @ $(REF): HTTP %{http_code}\n" \
	  -X POST \
	  -H "Authorization: token $(TOKEN)" \
	  -H "Content-Type: application/json" \
	  -d "{\"ref\":\"$(REF)\"}" \
	  "$(GITEA_URL)/api/v1/repos/$(REPO)/actions/workflows/$(WORKFLOW)/dispatches"

.PHONY: vars-push
vars-push: ## Upload $(VARS) from infra.env as Gitea repo variables
	@for v in $(VARS); do \
	  val="$${!v}"; \
	  [ -n "$$val" ] || { echo "ERROR: $$v is empty" >&2; exit 2; }; \
	  code=$$(curl -s -o /dev/null -w '%{http_code}' -X POST \
	    -H "Authorization: token $(TOKEN)" -H "Content-Type: application/json" \
	    -d "{\"value\":\"$$val\"}" \
	    "$(GITEA_URL)/api/v1/repos/$(REPO)/actions/variables/$$v"); \
	  if [ "$$code" = "409" ]; then \
	    curl -fsSL -o /dev/null -X PUT \
	      -H "Authorization: token $(TOKEN)" -H "Content-Type: application/json" \
	      -d "{\"value\":\"$$val\"}" \
	      "$(GITEA_URL)/api/v1/repos/$(REPO)/actions/variables/$$v" || exit 1; \
	    code=204; \
	  fi; \
	  case "$$code" in 201|204) echo "==> $$v=$$val";; *) echo "ERROR: $$v -> HTTP $$code" >&2; exit 1;; esac; \
	done

.PHONY: vars-list
vars-list: ## List Gitea repo variables
	@curl -fsSL -H "Authorization: token $(TOKEN)" \
	  "$(GITEA_URL)/api/v1/repos/$(REPO)/actions/variables" | jq -r '.[] | "\(.name)=\(.data)"'

.PHONY: status
status: ## Show the last Gitea workflow runs
	@curl -fsSL -H "Authorization: token $(TOKEN)" \
	  "$(GITEA_URL)/api/v1/repos/$(REPO)/actions/tasks?limit=5" \
	  | jq -r '.workflow_runs[] | "\(.id) \(.name) run#\(.run_number) \(.status)"'

.PHONY: logs
logs: ## Tail the build-host runner log
	ssh $(BUILD_HOST) "sudo journalctl -u act_runner -f"

.PHONY: logs-deploy
logs-deploy: ## Tail the deploy-host runner log
	journalctl --user -u act_runner -f

# ---------------------------------------------------------------- distroboxes
# el7 install target. ubi7 = public ubi7 (RHEL 7.9 userland, yum only).
.DISTROBOX_ENV = PKG=$(PKG)

.PHONY: box-ubi7
box-ubi7: ## Create the ubi7 (RHEL 7.9 userland) distrobox if missing
	CICD_BOX=ubi7 CICD_IMAGE=localhost/ubi7-base:latest CICD_BASE_CONTEXT=packaging/rhel7 \
	  bash packaging/bin/install-in-distrobox.sh bootstrap

.PHONY: install-ubi7
install-ubi7: ## Install the built RPM into ubi7 (PKG=openssl35)
	CICD_BOX=ubi7 ARTIFACT_DIR=$(HOME)/el7-artifacts/$(PKG)-ubi7 bash packaging/bin/install-in-distrobox.sh install

.PHONY: boxes
boxes: ## List distroboxes
	distrobox list
