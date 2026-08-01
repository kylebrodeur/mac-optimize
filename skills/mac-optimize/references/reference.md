# mac-optimize — reference

Load this only when you need exact flags, environment variables, or restore steps.

## diskreport

Read-only. No flags. Sections: volume free space + APFS snapshot count; top `~/Library/Application Support`; top `~/Library/Caches`; regrowing dev/agent caches (`~/.npm`, `~/Library/pnpm`, `~/.cache`, `~/.bun`); REVIEW-tier big-but-real state; recent reclaim log tail.

If the snapshot count is nonzero, thin them with: `tmutil thinlocalsnapshots / <bytes> 4`.

## mac-reclaim

```
mac-reclaim                 # safe caches only (unattended-safe)
mac-reclaim --deep          # + prune proven-unused agent state (prompts)
mac-reclaim --deep --dry-run  # show what deep WOULD remove, and why. Deletes nothing.
mac-reclaim --deep --yes    # deep prune without prompting (automation only)
mac-reclaim --quiet         # summary line only
```

Environment:
- `KEEP_DAYS` (default 30) — age gate for the deep tier.
- `KEEP_RECENT` (default 5) — always keep the N newest entries per category.

Allowlist: `~/.config/mac-reclaim/keep.txt` — one path substring per line; any candidate whose path matches is never pruned.

Safe tier clears: `~/.npm/_cacache` + `_npx`, `pnpm store prune`, `uv cache prune`, `brew cleanup -s`, `bun pm cache rm`, `~/.cache/codex-runtimes`, `~/.cache/node`, `*.ShipIt` updaters, VS Code `CachedExtensionVSIXs`/`Cache`/`CachedData`/`Crashpad`, and stale app logs.

Deep tier: orphaned VS Code `workspaceStorage` is reported as **REVIEW/protected** and is never removed until an archive-first backup and explicit verified prune workflow exists. The only deep-delete candidates (only when idle > `KEEP_DAYS`, beyond newest `KEEP_RECENT`, not open per `lsof`, not allowlisted) are `vm_bundles`, `local-agent-mode-sessions`, and `~/.claude/projects`.

Log: `~/Library/Logs/mac-reclaim.log`, self-capped to the last 500 lines.

## worktree-audit

```
worktree-audit [ROOT ...]        # audit (default root: ~/workspace)
worktree-audit --prune           # remove SAFE worktrees + clear stale registrations
worktree-audit --backup          # archive REVIEW worktrees to git bundles (prompts to select)
worktree-audit --backup --prune  # archive, then remove the ones that archived cleanly
worktree-audit --yes             # skip the confirmation prompt (select all)
```

Classification: SAFE = clean working tree AND zero commits unique to this worktree (every commit reachable from another branch/tag/remote). REVIEW = dirty or has unique unmerged/unpushed commits. Locked and main worktrees are never touched.

Backups: `${WORKTREE_BACKUP_DIR:-~/.local/share/worktree-backups}/<repo>__<branch>__<timestamp>.bundle`, incremental (unique commits, prerequisites = other refs). Dirty trees also get `<stem>.uncommitted.patch` and `<stem>.untracked.tar.gz`. A `manifest.tsv` records a restore command per backup.

### Restoring a backed-up worktree

Incremental bundles restore against the surviving repo:

```
# bring the branch back
git -C <repo> fetch <backup>.bundle 'refs/heads/<branch>:refs/heads/<branch>'
# if it was dirty, reapply the working-tree state in a checkout of that branch
git -C <worktree> apply <stem>.uncommitted.patch
tar -xzf <stem>.untracked.tar.gz -C <worktree>
```

For a detached backup, fetch the recorded sha instead of a branch name. The `manifest.tsv` row has the exact command.
