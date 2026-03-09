.PHONY: release-prepare release-publish

REMOTE ?= origin
FORCE ?= 0

release-prepare:
ifndef BUMP
	$(error BUMP is required. Usage: make release-prepare BUMP=<patch|minor|major>)
endif
	@./scripts/release.sh prepare $(BUMP) $(REMOTE)

release-publish:
	@FORCE=$(FORCE) ./scripts/release.sh publish
