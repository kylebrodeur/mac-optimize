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

### Changed
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
