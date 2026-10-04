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

Safe tier clears: `~/.npm/_cacache` + `_npx`, `pnpm store prune`, `uv cache prune`, `brew cleanup -s`, `bun pm cache rm`, `~/.cache/codex-runtimes`, `~/.cache/node`, `*.ShipIt` updaters, VS Code `CachedExtensionVSIXs`/`Cache`/`CachedData`/`Crashpad`, stale app logs, and **superseded browser revisions**.

**Browser caches are not "safe by construction" like the rest.** A Playwright/Puppeteer browser is a pinned *binary*; `rm -rf`-ing the cache frees nothing because the next test run re-downloads the same bytes. `am_browser_cache_prune` therefore removes only *superseded* revisions of `ms-playwright` and `~/.cache/puppeteer` and keeps: any revision an installed `playwright-core` pins (read from its `.links` map), any revision in use per `lsof`, and the newest `BROWSER_KEEP_NEWEST` (default 1) unreferenced revisions as a rollback margin. To stop the download entirely, see `browser-guard` below.

Deep tier: orphaned VS Code `workspaceStorage` is reported as **REVIEW/protected** and is never auto-removed; reclaim it manually, archive-first (tar `chatSessions/` + `chatEditingSessions/` + `workspace.json`, verify, then delete — skipping unmounted `/Volumes/` paths, re-checking the folder is gone). Only Task-1 primitives shipped in `bin/vscode-chat-backup`; the full encrypted workflow is archived under `docs/superpowers/_archive/`. The only deep-delete candidates (only when idle > `KEEP_DAYS`, beyond newest `KEEP_RECENT`, not open per `lsof`, not allowlisted) are `vm_bundles`, `local-agent-mode-sessions`, and `~/.claude/projects`.

Log: `~/Library/Logs/mac-reclaim.log`, self-capped to the last 500 lines.

## browser-guard

One shared browser directory for every Playwright/Puppeteer install, so no repo pays a ~560 MB re-download. Shared via `agent-machine-lib` (same copy as `wsl-optimize`).

```
browser-guard status               # shared root, pinned revisions, reclaimable
browser-guard adopt [ROOT ...]     # materialise every revision the repos pin
browser-guard check  [ROOT ...]    # assert the shared root satisfies every pin (exit 1 on drift)
browser-guard gc                   # remove superseded revisions + agent-browser orphans
browser-guard env                  # print the shell exports to wire it up
```

Options: `--dry-run`, `--root DIR`, `--keep N`.

Each revision dir is a **symlink** to a real Chrome for Testing (agent-browser's copy preferred: a distinct bundle from the user's daily Chrome, so a headless run can never shadow their real browser). The `chrome-headless-shell` is **hardlink-copied** instead, so the shared root keeps working if `ms-playwright` is deleted outright. Nothing is downloaded, and no bytes are duplicated.

Env: `BROWSER_GUARD_ROOT` (default `~/.cache/browsers` — deliberately *outside* the caches a reclaim walks), `BROWSER_KEEP_NEWEST`. Wiring:

```sh
export PLAYWRIGHT_BROWSERS_PATH="$HOME/.cache/browsers"
export PUPPETEER_CACHE_DIR="$HOME/.cache/browsers"
export PUPPETEER_SKIP_DOWNLOAD=1
```

With those set, `npx playwright install chromium` inside any repo is a no-op (browsers already present at the shared path). Read-only except `adopt` and `gc`.

> `PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1` does **not** stop `playwright install` — it only gates the npm postinstall hook. Verified: with it set, the command still downloaded 580 MB.

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

## memguard (memory watcher)

Automation, not an interactive CLI (installed by the `mac-optimize-setup` skill; runs via launchd at login + every 5 min). Reads `kern.memorystatus_vm_pressure_level` (1 normal / 2 warn / 4 critical) and the free-RAM % from `memory_pressure`, names the largest RAM process, and notifies — it **never** kills or deletes. Swap is shown as `used/totalMB` for context only (the ratio is not a trigger: it sits ~80% whenever swap was ever touched). Escalates to the coupling alert when RAM is tight **and** disk is below `CRIT_GB` (swap can't grow on a full volume).

Env: `FREE_WARN_PCT` (15), `FREE_CRIT_PCT` (5), `CRIT_GB` (15), `NOTIFY_COOLDOWN` (1800s). Log: `~/Library/Logs/memguard.log`, self-capped to 500 lines.
