# VS Code Chat Backup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `vscode-chat-backup`, a macOS command that archives orphaned VS Code workspace state to an encrypted personal Google Drive, verifies real restoration, and permits only manifest-gated move-to-Trash pruning.

**Architecture:** Use one executable Python 3 CLI at `bin/vscode-chat-backup` with standard-library implementations for no-follow source traversal, deterministic fingerprints, manifest journaling, gzip tar creation/validation, staging cleanup, and restore finalization. Invoke only the external `rclone` binary for the configured Google Drive `crypt` remote, `lsof`/`pgrep` for bounded process/open-file checks, and `osascript` for macOS Trash moves. Keep `mac-reclaim` review-only for workspaceStorage; this tool is the separate archive/verify/prune authority.

**Tech Stack:** Python 3 standard library (`argparse`, `dataclasses`, `hashlib`, `json`, `os`, `pathlib`, `sqlite3`, `tarfile`, `tempfile`, `signal`, `subprocess`), macOS Bash wrapper conventions, `rclone` with a Google Drive `crypt` remote, macOS Finder Trash scripting, Bash regression fixtures.

## Global Constraints

- Every orphaned `workspaceStorage` entry remains REVIEW/protected until this workflow reaches `restored` and receives explicit prune confirmation.
- `plan` must treat entries without recognized chat directories as `unknown/REVIEW`; absence of a directory never proves that `state.vscdb` lacks chat.
- `upload` must require VS Code fully quit and fail closed on an incomplete or unavailable process/open-file check.
- Before copying, reject any symlink, device, socket, FIFO, or other special source entry using descriptor-relative/no-follow traversal; never follow, skip, transform, or materialize one.
- Validate the source before and after staging and compare pre-copy source fingerprint, staged fingerprint, post-copy source fingerprint, and source root device/inode.
- Staging and temporary restore directories use `umask 077`, directory mode `0700`, and file mode `0600`; cleanup runs on success, failure, `SIGINT`, `SIGTERM`, and `EXIT`.
- Archive objects are immutable and named `<workspace-hash>-<archive-sha256>.tar.gz.bin`; every archive has an immutable sidecar manifest retaining its complete snapshot metadata.
- Mutable lifecycle state is authoritative only in `<workspace-hash>.manifest.json`; remote and local state transitions use same-directory temp writes, `fsync`, atomic rename, and crypt-remote temp-upload-then-move.
- Verify and restore must check downloaded archive byte size and SHA-256 before metadata parsing or extraction.
- Tar validation rejects absolute paths, `..`, backslash traversal, duplicate/conflicting entries, symlinks, hard links, devices, sockets, FIFOs, overlong paths, member-count overflow, and unbounded file totals before extraction.
- Restore extracts into a hidden sibling of the destination parent, fingerprints the sole `<workspace-hash>/` child, then atomically renames that child into a new non-existing destination; cross-filesystem destinations are rejected.
- Prune is the only local deletion path. It journals the intended quarantine and Trash name before renaming, re-fingerprints the quarantined directory, and clears the journal only after rollback or a committed prune transition.
- `rclone` is the only new runtime dependency; use its built-in personal Google OAuth flow and never require a server, bucket, service account, or custom OAuth service.
- Do not modify `mac-reclaim` to perform archive/prune operations; preserve its review-only workspaceStorage guard.

---

## File Map

- **Create:** `bin/vscode-chat-backup` — executable CLI, subcommands, manifest state machine, archive/restore/prune orchestration.
- **Create:** `test/vscode-chat-backup-test.sh` — Bash end-to-end fixture harness using a fake `rclone`, fake process/open-file probes, hostile archives, crash injection, and a disposable `$HOME`.
- **Modify:** `install.sh` — install the new executable through the existing `bin/*` loop and verify `rclone` is present only when the command is used.
- **Modify:** `Makefile` — include the new CLI in doctor/install smoke checks without making `rclone` a requirement for safe cache reclaim.
- **Modify:** `README.md` — document the separate plan/upload/verify/restore/prune-verified workflow and recovery warning.
- **Modify:** `TESTING.md` — add the encrypted round-trip, crash reconciliation, hostile tar, and no-overwrite restore gates.
- **Modify:** `skills/mac-optimize/SKILL.md` and `skills/mac-optimize/references/reference.md` — point REVIEW workspaceStorage users to the new archive-first workflow.
- **Reference:** `docs/superpowers/specs/2026-08-01-vscode-chat-backup-design.md` — approved behavior contract; implementation must not weaken it.

---

### Task 1: Build manifest and fingerprint primitives

**Files:**
- Create: `bin/vscode-chat-backup`
- Test: `test/vscode-chat-backup-test.sh`

**Interfaces:**
- `tree_fingerprint(root: Path) -> SnapshotFingerprint` returns `sha256:<hex>`, `regular_file_count`, `regular_bytes`, and sorted per-entry records.
- `atomic_json_write(path: Path, value: dict) -> None` writes mode `0600` through a same-directory temp file, flush/fsync, and atomic rename.
- `load_manifest(path: Path) -> dict` validates required fields and state values before use.
- `canonical_source_path(workspace_hash: str) -> Path` derives only `~/Library/Application Support/Code/User/workspaceStorage/<hash>` and rejects traversal.

- [ ] **Step 1: Write failing fixture assertions** for identical-tree stability, byte-change divergence, canonical source derivation, mode `0600`, and interrupted atomic-write recovery.
- [ ] **Step 2: Run the focused fixture** and confirm the new CLI/helper behavior is absent.
- [ ] **Step 3: Implement deterministic traversal.** Sort relative POSIX paths; record type, relative path, regular-file size, and per-file SHA-256; reject non-regular/non-directory entries; exclude timestamps, ownership, and mode bits from the digest.
- [ ] **Step 4: Implement manifest schema validation.** Require `workspace_hash`, `original_workspace_path`, canonical `source_path`, immutable `archive_name`, `tree_fingerprint`, `archive_sha256`, `archive_size_bytes`, `regular_file_count`, `regular_bytes`, `created_at`, `updated_at`, `generation`, and valid lifecycle state.
- [ ] **Step 5: Run the focused fixture** and confirm all primitive assertions pass.
- [ ] **Step 6: Commit** `feat: add chat backup manifest primitives`.

### Task 2: Implement plan and safe source snapshotting

**Files:**
- Modify: `bin/vscode-chat-backup`
- Modify: `test/vscode-chat-backup-test.sh`

**Interfaces:**
- `plan` prints every orphan with hash, original workspace path, canonical storage path, size, `chat-bearing` or `unknown/REVIEW`, archive name proposal, and recommendation.
- `snapshot_source(source: Path, staging: Path) -> SnapshotFingerprint` performs no-follow preflight, copy, staged validation, and pre/post live fingerprint comparison.
- `check_vscode_quit() -> None` succeeds only when bounded `pgrep`/open checks prove VS Code is fully quit.

- [ ] **Step 1: Add plan fixtures** for a chatSessions orphan, chatEditingSessions orphan, unknown orphan, live workspace, malformed workspace.json, and a state.vscdb-only orphan.
- [ ] **Step 2: Assert plan classifies unknown entries as REVIEW** and never labels them definitively non-chat.
- [ ] **Step 3: Add source fixtures** containing a symlink, FIFO, socket, and a file modified during copy; assert each upload preparation fails before archive creation and never blocks/follows.
- [ ] **Step 4: Implement bounded VS Code/open-file probes** with explicit closed/open/unavailable results; unavailable is failure, never permission to continue.
- [ ] **Step 5: Implement descriptor-relative/no-follow traversal and source/staged fingerprint equality checks** with root device/inode identity checks.
- [ ] **Step 6: Run plan and source-snapshot tests** and confirm all failure paths leave staging cleaned.
- [ ] **Step 7: Commit** `feat: add safe workspace backup planning`.

### Task 3: Implement rclone crypt upload and immutable manifests

**Files:**
- Modify: `bin/vscode-chat-backup`
- Modify: `test/vscode-chat-backup-test.sh`

**Interfaces:**
- `upload(workspace_hash: str, remote: str) -> Manifest` creates one immutable archive and sidecar, then publishes the mutable pointer.
- `run_rclone(args: list[str], timeout: float) -> CompletedProcess` uses bounded timeouts and raises a typed failure without touching source state.
- Remote objects: `archives/<hash>-<archive_sha256>.tar.gz.bin`, `manifests/<hash>-<archive_sha256>.manifest.json`, and current pointer `manifests/<hash>.manifest.json`.

- [ ] **Step 1: Add a fake-rclone fixture** that copies local objects to a disposable remote root, supports temp-upload-then-move, and can inject timeout/interrupted-upload failures.
- [ ] **Step 2: Assert upload leaves the source byte-identical and creates no symlink/special archive member.**
- [ ] **Step 3: Implement gzip tar creation** with one `<workspace-hash>/` top-level directory and regular files/directories only.
- [ ] **Step 4: Compute archive hash/size before naming the immutable archive object.** Upload and re-download to confirm hash/size before publishing either manifest.
- [ ] **Step 5: Persist the immutable sidecar (snapshot metadata only), then the current lifecycle pointer** using atomic local writes and crypt-remote temp-upload-then-move.
- [ ] **Step 6: Add idempotency tests** proving a later `verified`, `restored`, or `pruned` pointer is never regressed to `uploaded`, and superseded archive/sidecar objects remain available.
- [ ] **Step 7: Add interrupted-upload and signal cleanup tests** proving source remains untouched and staging is removed.
- [ ] **Step 8: Run upload tests** with fake rclone and confirm no real remote/cache command is reached.
- [ ] **Step 9: Commit** `feat: upload encrypted immutable chat archives`.

### Task 4: Implement hostile archive verification

**Files:**
- Modify: `bin/vscode-chat-backup`
- Modify: `test/vscode-chat-backup-test.sh`

**Interfaces:**
- `verify(workspace_hash: str, remote: str) -> Manifest` downloads the pointer-selected immutable archive, validates hash/size, validates tar metadata, extracts into staging, fingerprints, and transitions one pointer to `verified` or `verify-failed`.
- `validate_tar(path: Path, manifest: dict) -> None` performs metadata-only validation before extraction.

- [ ] **Step 1: Generate hostile tar fixtures** for absolute paths, `..`, backslashes, duplicate paths, file/dir conflicts, symlink, hard link, device, FIFO, oversized member, excessive count, and wrong top-level prefix.
- [ ] **Step 2: Assert every hostile fixture is rejected before any extraction target is created.**
- [ ] **Step 3: Implement downloaded archive byte-size and SHA-256 checks** before tar parsing.
- [ ] **Step 4: Implement complete tar metadata validation** against manifest member count/bytes and 50 GiB total bound.
- [ ] **Step 5: Implement verified extraction and pointer transitions** with per-entry partial-batch reporting; failed entries remain protected and are not rolled back by a fictitious batch transaction.
- [ ] **Step 6: Run hostile archive and successful verify tests.**
- [ ] **Step 7: Commit** `feat: verify chat archive integrity`.

### Task 5: Implement restore finalization and no-overwrite behavior

**Files:**
- Modify: `bin/vscode-chat-backup`
- Modify: `test/vscode-chat-backup-test.sh`

**Interfaces:**
- `restore(workspace_hash: str, destination: Path | None, remote: str) -> Manifest` performs a real remote download/rehearsal and transitions to `restored` only after final destination rename succeeds.
- Destination parent must be existing/writable and same-filesystem with its hidden extraction sibling.

- [ ] **Step 1: Add restore fixtures** with a valid archive, pre-existing destination, destination on another volume, and archive whose only child is `<workspace-hash>/`.
- [ ] **Step 2: Assert existing destinations are never overwritten** and cross-volume destinations fail before partial finalization.
- [ ] **Step 3: Implement hidden sibling extraction** under the validated destination parent, validate hash/size and hostile metadata, fingerprint the sole `<hash>` child, then atomically rename that child—not the wrapper—to the requested destination.
- [ ] **Step 4: Assert restore output has exactly one `<workspace-hash>` tree and no doubled wrapper.**
- [ ] **Step 5: Persist `restored` evidence only after final rename and remote/local manifest commits succeed; clean staging on every failure/signal.**
- [ ] **Step 6: Run restore rehearsal tests** and confirm source remains unchanged.
- [ ] **Step 7: Commit** `feat: add verified chat archive restore`.

### Task 6: Implement quarantine-journaled prune-verified

**Files:**
- Modify: `bin/vscode-chat-backup`
- Modify: `test/vscode-chat-backup-test.sh`

**Interfaces:**
- `prune_verified(workspace_hash: str, remote: str, assume_yes: bool) -> Manifest` is the only source mutation path.
- Journal record: `{source_path, quarantine_path, workspace_hash, generation, trash_name}` written atomically before source rename.
- `move_to_trash(path: Path, trash_name: str) -> None` uses bounded `osascript`/Finder move and never empties Trash.

- [ ] **Step 1: Add prune fixtures** for stale source changes, open source, allowlisted source, source recreated during quarantine, and crash points after journal write, after quarantine rename, and after Trash move.
- [ ] **Step 2: Assert prune requires `state=restored`, matching restore fingerprint, exact canonical source path, and explicit confirmation.**
- [ ] **Step 3: Implement journal write, same-filesystem quarantine rename, quarantine fingerprint, conditional rollback, and deterministic unique Trash name before the first rename.**
- [ ] **Step 4: Implement startup reconciliation**: source present/quarantine absent clears an unstarted journal; source absent/quarantine present fails closed and offers only explicit restore/finalize; both/neither stops as ambiguous; Trash item plus manifest state is checked for post-move crashes.
- [ ] **Step 5: Assert successful prune moves only the exact source directory to Trash and retains archive, sidecar, restore evidence, and source manifest history.**
- [ ] **Step 6: Run prune crash tests** and confirm no source is silently discarded.
- [ ] **Step 7: Commit** `feat: add manifest-gated Trash pruning`.

### Task 7: Integrate install, docs, and end-to-end verification

**Files:**
- Modify: `install.sh`
- Modify: `Makefile`
- Modify: `README.md`
- Modify: `TESTING.md`
- Modify: `skills/mac-optimize/SKILL.md`
- Modify: `skills/mac-optimize/references/reference.md`
- Modify: `test/vscode-chat-backup-test.sh`

- [ ] **Step 1: Add install/doctor checks** that install the executable and report missing `rclone` only for backup commands; safe `mac-reclaim` remains usable without rclone.
- [ ] **Step 2: Document personal Google Drive OAuth, `rclone crypt`, 1Password recovery material, exact command order, and the no-delete default.**
- [ ] **Step 3: Add the full local round-trip test**: plan → upload → verify → restore → prune-verified, with an explicit review gate between dry-run output and prune.
- [ ] **Step 4: Add remote download/recovery rehearsal** using a fresh rclone config fixture and verify archive/sidecar/pointer recovery.
- [ ] **Step 5: Run all focused Bash syntax, fixture, install, and doctor checks** under `/bin/bash` 3.2; run no destructive command against live workspaceStorage.
- [ ] **Step 6: Commit** `feat: ship vscode chat backup workflow`.

## Plan Self-Review Checklist

- [x] Every approved design section maps to one or more implementation tasks.
- [x] Symlink/special-file source rejection happens before copy and staged-tree validation happens again.
- [x] Archive hash/size are computed before immutable naming; archive and sidecar precede the mutable pointer.
- [x] Verify/restore validate downloaded hash/size before parsing and never overwrite destinations.
- [x] Restore renames the sole hash child, not the wrapper, and rejects cross-filesystem destinations.
- [x] Prune journals before rename, records Trash identity, reconciles crashes, and conditionally rolls back.
- [x] Open-file checks distinguish closed, open, and unavailable; deletion rechecks immediately before each removal.
- [x] Sidecar preserves immutable metadata for every retained archive; lifecycle state remains pointer-authoritative.
- [x] No task depends on a placeholder, unbounded retry, service account, or silent fallback.
