.PHONY: install uninstall install-skills doctor report audit reclaim lint vendor-lib

install:
	./install.sh

# Verify the install: tools on PATH, launchd agents loaded, skills (optional).
doctor:
	@bin/mac-optimize-doctor

# Activate the agent-agnostic skills for Claude Code by symlinking each skill
# folder into ~/.claude/skills. Other agents can point directly at ./skills.
# Idempotent; the repo stays the source of truth.
install-skills:
	@mkdir -p "$$HOME/.claude/skills"
	@for d in skills/*/; do \
		n=$$(basename "$$d"); \
		ln -sfn "$$PWD/skills/$$n" "$$HOME/.claude/skills/$$n" && \
		echo "linked ~/.claude/skills/$$n -> $$PWD/skills/$$n"; \
	done

uninstall:
	./uninstall.sh

report:
	bin/diskreport

audit:
	bin/worktree-audit

reclaim:
	bin/mac-reclaim

lint:
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck bin/* install.sh uninstall.sh; \
	else \
		echo "shellcheck not installed — skipping (brew install shellcheck)"; \
	fi

# Refresh the vendored shared library + shared tool from agent-machine-lib.
# Vendored rather than submoduled because this repo promises zero dependencies.
vendor-lib:
	@set -e; \
	sha=$$(git ls-remote https://github.com/kylebrodeur/agent-machine-lib.git refs/heads/main | awk '{print $$1}'); \
	test -n "$$sha"; \
	tmp=$$(mktemp -d); \
	trap 'rm -rf "$$tmp"' EXIT; \
	curl -fsSL "https://raw.githubusercontent.com/kylebrodeur/agent-machine-lib/$$sha/lib/common.sh" \
		-o "$$tmp/common.sh"; \
	curl -fsSL "https://raw.githubusercontent.com/kylebrodeur/agent-machine-lib/$$sha/bin/worktree-audit" \
		-o "$$tmp/worktree-audit"; \
	chmod +x "$$tmp/worktree-audit"; \
	mv "$$tmp/common.sh" lib/common.sh; \
	mv "$$tmp/worktree-audit" bin/worktree-audit; \
	printf '%s\n' "$$sha" > lib/.vendored-from; \
	echo "refreshed lib/common.sh + bin/worktree-audit from agent-machine-lib@$$sha"
