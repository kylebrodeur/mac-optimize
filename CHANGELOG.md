# Changelog

All notable changes to **mac-optimize** are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **`memguard`** — a launchd memory-pressure watcher (login + every 5 min), the
  memory analog of `diskguard` and the other half of the `earlyoom` lesson. Reads
  the kernel's `kern.memorystatus_vm_pressure_level` and free-RAM %, names the
  largest RAM consumer, escalates in the disk↔swap coupling quadrant (RAM tight
  **and** disk low, so swap can't grow), debounces banners, and **never kills or
  deletes**. Swap ratio is deliberately not a trigger (it sits ~80% whenever swap
  was ever touched). Wired into `install`/`uninstall`/`doctor`.
- **`vscode-chat-backup`** — manifest and deterministic tree-fingerprint
  primitives (no-follow descriptor-relative traversal, atomic `0600` JSON writes,
  pointer/sidecar manifest validation and reconciliation). Foundation only; the
  full encrypted archive/verify/restore/prune workflow from the design spec was
  **not** built and has been archived (see `docs/superpowers/_archive/`).
- **`codex-backup`** — back up, index, prune, and restore `~/.codex/sessions`,
  the large single-copy JSONL rollout logs Codex writes per run (10 GB+ is
  normal and was the dominant driver of one machine's disk drop). `backup`
  rsyncs them to an external drive **cumulatively** (never `--delete`); `index`
  buckets every session by idle age (45+/30-45/15-30/<15 days), size, project
  (`cwd`), and backup status, writing a JSON+TSV index to both the drive and
  `~/.codex/`; `prune --older-than N` deletes local sessions idle ≥ N days
  **only when byte-verifiable in the backup** (dry-run default, keeps the N
  newest, never touches un-backed-up files); `restore` round-trips by
  date/uuid/project/all without clobbering newer local files; `verify` reports
  drift. Ships a weekly launchd agent that runs `backup --quiet` and no-ops when
  the drive is unmounted. Python 3 stdlib, prefers Homebrew rsync 3.x when
  present. Covered by `test/codex-backup-test.sh` (23 assertions).

### Changed
- **`memguard`** now auto-triggers `mac-reclaim`'s SAFE tier immediately (own
  `RECLAIM_COOLDOWN`, default 900s) the moment it detects the disk↔swap coupling
  quadrant, instead of only notifying and waiting for `diskguard`'s own schedule.
  Repeat banners in that specific quadrant now use a tighter
  `COUPLING_NOTIFY_COOLDOWN` (default 300s) instead of the normal 1800s. Prompted
  by a real incident: sustained RAM pressure + disk hitting 0GB (swap at 97% of
  an 18GB ceiling) starved `watchdogd` long enough to force a kernel panic —
  `memguard` had correctly logged `CRITICAL` every cycle for hours but never
  acted, because acting was previously out of scope for a "never kills or
  deletes" watcher. The safe cache tier is not app state or a process, so
  running it sooner doesn't cross that line; only the timing changed. Set
  `RECLAIM_COOLDOWN=0` to restore the prior notify-only behavior.
- **`diskguard`** now escalates when the safe tier can't restore headroom: it
  names the biggest disk consumers, flags the safe tier as exhausted, points at
  the deep tools, and debounces repeat banners (via a `.state` file) instead of
  re-posting an identical alarm every run.
- `mac-reclaim --dry-run` reports the safe tier's intended actions instead of
  silently skipping the tier.
- Orphaned VS Code `workspaceStorage` is protected as REVIEW and never
  auto-deleted; reclaiming it is a manual, archive-first step.
- Open-file (`lsof`) checks fail closed when unavailable rather than assuming a
  directory is closed.

### Docs
- README documents the memory failure mode (jetsam) and `memguard` alongside the
  disk story; tools table, principles, env-var table, and automation section
  updated for three launchd agents.
- TESTING.md adds §4g (memguard + diskguard-escalation verification).
- Homebrew install instructions.
- Skills: `mac-optimize-setup` synced to three agents; the `mac-optimize` usage
  skill documents the archive-first `workspaceStorage` cleanup and memory
  pressure.
- Archived the shelved `vscode-chat-backup` implementation plan and design spec
  under `docs/superpowers/_archive/`.

## [1.0.0] - 2026-07-31

### Added
- Initial macOS disk & shell hygiene toolset for machines that run fleets of AI
  coding agents:
  - **`diskreport`** — read-only "where did my disk go?" report (top consumers,
    regrowing caches, REVIEW-tier state, APFS local-snapshot flag).
  - **`mac-reclaim`** — two-tier reclaim: safe-by-construction cache clearing
    (default) and an evidence-gated `--deep` tier for proven-unused agent state,
    behind `--dry-run`, an allowlist, `lsof` guards, and a keep-newest floor.
  - **`worktree-audit`** — classify stray git worktrees SAFE/REVIEW, with
    `--prune` and archive-first `--backup`.
  - **`diskguard`** — launchd low-disk watcher: safe reclaim + notify at a
    threshold, never a destructive prune unattended.
  - **`mac-optimize-doctor`** — read-only health check (tools on PATH, launchd
    agents loaded + valid). Never fetches or executes remote code.
- Shared `common.sh` vendored from
  [`agent-machine-lib`](https://github.com/kylebrodeur/agent-machine-lib);
  transcript cleanup delegated to `agent-session-kill`; `worktree-audit` shared
  with `wsl-optimize`.
- launchd automation (`diskguard`, weekly `mac-reclaim`) and a `TESTING.md`
  clone-to-uninstall verification guide.

[Unreleased]: https://github.com/kylebrodeur/mac-optimize/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/kylebrodeur/mac-optimize/releases/tag/v1.0.0
