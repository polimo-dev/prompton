.DEFAULT_GOAL := help
.PHONY: help worktree worktree-rm worktree-list test-worktrees dev-deploy

# Preserve literal input: neither Make functions nor shell syntax are executed.
unexport name from
export WORKTREE_NAME := $(value name)
export WORKTREE_FROM := $(value from)

help: ## Show available commands
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  %-20s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

worktree: ## Add .worktrees/<name> (name=... [from=main])
	@sh scripts/worktree.sh worktree

worktree-rm: ## Remove a clean worktree, keeping its branch (name=...)
	@sh scripts/worktree.sh worktree-rm

worktree-list: ## List the primary checkout and linked worktrees
	@git worktree list

test-worktrees: ## Test worktree lifecycle and deployment guards without deploying
	@sh scripts/test-worktrees.sh

dev-deploy: ## Build and roll the dev server from the primary checkout only (no push)
	@sh scripts/worktree.sh require-primary
	docker --context orbstack build -f app/Dockerfile -t prompton-server:dev-local .
	docker --context orbstack image inspect prompton-server:dev-local --format '{{.Id}} {{.Created}}'
	kubectl --context orbstack -n prompton rollout restart deployment/prompton
	kubectl --context orbstack -n prompton rollout status deployment/prompton --timeout=300s
