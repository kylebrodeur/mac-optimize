.PHONY: install uninstall install-skills report audit reclaim lint

install:
	./install.sh

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
