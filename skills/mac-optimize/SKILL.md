---
name: mac-optimize
description: Diagnose and reclaim disk space, audit stray git worktrees, back up and prune Codex agent sessions, check SSD health, and stay ahead of memory pressure on a macOS dev machine that runs many AI coding agents. Use when the Mac is low on disk, filling up, low on memory, or feels slow; when the user says "clean up my mac", "free up space", "reclaim disk", "what's using my disk", "prune caches", "why is my mac slow", "find/clean git worktrees", "back up my codex sessions", "prune old codex/agent sessions", or "check my SSD/drive health"; or for routine maintenance. Drives the diskreport, mac-reclaim, worktree-audit, codex-backup, and diskhealth command-line tools with a safety-first workflow.
compatibility: Requires macOS with the mac-optimize tools on PATH (diskreport, mac-reclaim, worktree-audit, codex-backup, diskhealth). Install them from the mac-optimize repo (see the mac-optimize-setup skill).
license: MIT
metadata:
  author: kylebrodeur
  version: "1.0"
---

# mac-optimize

Reclaim disk and keep a macOS coding-agent machine healthy — **without ever deleting work that isn't provably recoverable.** These machines fill up because every agent run appends to caches (npm, pnpm, uv, codex runtimes, editor workspace storage) that grow on write and never self-reclaim, plus stray git worktrees from parallel agent tasks.

The tools do the work; this skill is the workflow and the guardrails.

## 1. Diagnose first (read-only)

```
diskreport
```

Shows the volume's free space, top consumers in `~/Library/Application Support` and `~/Library/Caches`, the dev/agent caches that regrow, and a REVIEW tier of large-but-real state (VS Code `workspaceStorage`, Claude `vm_bundles`). It also flags APFS local snapshots — the classic "invisible" disk sink. Never destructive.

If the fixed buckets above don't explain the free-space gap (e.g. a big single file buried inside
some app's `Application Support`), go wider:

```
diskreport --scan [PATH]     # one-shot 'dust' walk of PATH (default $HOME); opt-in, walks the whole tree
ncdu [PATH]                  # interactive instead — navigate, sort, delete in place
```

Both require Homebrew (`brew install ncdu dust`); `diskreport --scan` prints a hint instead of failing
if `dust` isn't installed. Still read-only/manual — `ncdu`'s delete key is a human action, not something
to script unattended.

For SSD health (wear, temperature, and the power-cycle/unsafe-shutdown pattern that catches external drives being yanked from power):

```
diskhealth            # SMART summary for every physical SSD (needs: brew install smartmontools)
diskhealth --verify   # + read-only filesystem check on mounted volumes
```

Read-only. A drive power-cycling ~10×/hour or with hundreds of unsafe shutdowns is a power-delivery problem (bus-powered enclosure losing 5V-3A), not a failing drive — check the cable, port, and whether the Mac is on battery before assuming the flash is dying.

## 2. Reclaim safe caches

```
mac-reclaim
```

Default mode clears only caches that rebuild on demand and leftover installers/logs. This is **safe by construction**: `pnpm store prune`/`uv cache prune` remove only unreferenced packages; `npm`'s `_cacache` is a re-download cache; installed `node_modules` are never touched. Nothing you're using can be lost. Run this freely.

## 3. Deeper reclaim — ALWAYS dry-run first

Only if step 2 isn't enough:

```
mac-reclaim --deep --dry-run     # shows every candidate + WHY it's considered unused
mac-reclaim --deep               # prompts before deleting
```

The deep tier reports orphaned VS Code `workspaceStorage` as REVIEW/protected and never removes it — reclaim it archive-first, by hand (see below). It prunes idle `vm_bundles`, `local-agent-mode-sessions`, and `.claude/projects` only when they're past `KEEP_DAYS`, beyond the newest `KEEP_RECENT`, not open per `lsof`, and not allowlisted. Never run `--deep` unattended or with `--yes` unless the user has reviewed a dry-run.

### Reclaiming orphaned `workspaceStorage` (manual, archive-first)

`mac-reclaim` keeps this REVIEW-only. The bulk of it is usually AI chat history from
dead projects, so treat it as *work* — archive before deleting:

1. Split **orphan** (project folder gone) from **alive** (folder still exists); leave alive alone.
2. `tar --zstd` each orphan's `chatSessions/` + `chatEditingSessions/` + `workspace.json` into one
   archive; write a manifest of hashes + original paths; verify every hash is listed in the archive.
3. Delete the orphan dirs only after the archive verifies. Skip any whose folder is on an unmounted
   `/Volumes/` path, and re-check the folder is really gone at delete time.

(The shelved encrypted `rclone`-crypt version of this — `vscode-chat-backup` — is archived under
`docs/superpowers/_archive/`; only its fingerprint/manifest primitives shipped.)

## 4. Audit and reclaim git worktrees

```
worktree-audit
```

Classifies every stray worktree:
- **SAFE** — clean working tree AND every commit is reachable from another ref (merged, tagged, or pushed). Removing it loses nothing. Reclaim with `worktree-audit --prune`.
- **REVIEW** — has uncommitted changes and/or commits that exist on no other ref. **Do not delete.** Archive it first:

```
worktree-audit --backup          # incremental git bundle (+ patch/tarball if dirty)
worktree-audit --backup --prune  # archive, then remove the ones that archived cleanly
```

Locked worktrees are always skipped. Backups land in `~/.local/share/worktree-backups/` with a `manifest.tsv` of restore commands.

## 5. Back up and prune Codex sessions

`~/.codex/sessions` holds the JSONL "rollout" log of every Codex run. They are
single-copy history (nothing regenerates them) and pile up fast — 10 GB+ is
normal and is often the biggest hidden driver of a shrinking disk. `codex-backup`
separates *keeping the history* from *keeping it on the internal SSD*.

Back up first (cumulative — never deletes from the drive):

```
codex-backup backup            # rsync ~/.codex/sessions → external drive
codex-backup index             # age buckets (45+/30-45/15-30/<15d) + backup status
```

Then, and only then, reclaim local space. Prune is dry-run by default and will
**only** delete sessions it can verify are already in the backup:

```
codex-backup prune --older-than 30            # dry-run: what would go, grouped by project
codex-backup prune --older-than 30 --apply    # delete local (backup keeps every copy)
```

It keeps the N newest (`--keep-recent`, default 5) and never deletes anything
not backed up. Restore is a first-class inverse — by date, session uuid, project
path, or all — and never clobbers a newer local file:

```
codex-backup restore --date 2026-07-20        # bring back one day
codex-backup restore --cwd /path/to/project   # everything from one project
codex-backup verify                           # local vs backup drift
```

The drive is resolved from `--dest`, `$CODEX_BACKUP_DEST`, `~/.config/mac-optimize/codex-backup.conf`,
or the first mounted volume with a `mac-optimize-backups/` folder. A weekly launchd agent runs
`backup --quiet` and silently no-ops whenever the drive isn't mounted — so pruning is always safe to
run later against a current backup.


## Memory pressure (not just disk)

These machines also die from **memory**: a fleet of agents exhausts RAM + swap and macOS's jetsam
killer force-quits apps. That is watched by `memguard` (installed via the `mac-optimize-setup` skill),
which warns — naming the largest process — before jetsam acts, and never kills a process or deletes
app state itself. If the Mac "feels slow" or apps get force-quit, check `~/Library/Logs/memguard.log`
and `sysctl kern.memorystatus_vm_pressure_level` (1 normal / 2 warn / 4 critical). Reclaiming disk helps
here too: swap can't grow on a full volume, so a full disk turns memory pressure fatal faster — this
combination (RAM tight *and* disk too low for swap to grow) has actually force-panicked a machine via a
`watchdogd` timeout, so `memguard` now auto-triggers `mac-reclaim`'s SAFE tier the moment it detects that
exact quadrant, instead of waiting for `diskguard`'s own schedule — still cache-only, still no process
ever killed.

## The rule

Caches are safe-by-construction — clear them. Anything holding potentially-unrecoverable work is **protected, never deleted**; REVIEW worktrees are archived first so they *become* safe to prune. When unsure, prefer `diskreport` and dry-runs over action.

## Details

Full flag/env tables, the deep-tier guards, and worktree restore recipes are in [references/reference.md](references/reference.md). Load it only when you need specifics.
