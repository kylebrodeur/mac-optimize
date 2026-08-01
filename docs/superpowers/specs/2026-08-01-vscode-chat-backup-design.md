# VS Code Chat Backup Design

## Date
2026-08-01

## Status
Approved for implementation.

## Problem and Evidence

VS Code stores chat state and AI agent session history per workspace under `~/Library/Application Support/Code/User/workspaceStorage/`. Each entry is keyed by a hashed workspace path, and its `state.vscdb` plus extension-specific subdirectories hold conversation threads, inline edit context, and transient model outputs. On a machine running many AI coding agents, these entries accumulate even after the original workspace directories are deleted.

A recent scan of one production machine found:

- **121 orphaned `workspaceStorage` entries** — entries whose `workspace.json` points to a directory that no longer exists.
- **92 of those orphans contain chat/history directories** — identified by the presence of `chatSessions/` or `chatEditingSessions/` directories in the measured scan.
- **6.62 GiB** total for the orphaned, chat-bearing subset.

The current `mac-reclaim` behavior classifies all orphaned `workspaceStorage` as **REVIEW/protected** and never deletes it. This is correct: the chat history inside those entries is not safely re-creatable and can hold important context, decisions, and references. The missing capability is a way to make that state **provably recoverable** off-machine before reclaiming local disk.

## Goals

1. Back up every orphaned VS Code `workspaceStorage` entry that contains chat or history data to encrypted personal cloud storage before any local deletion.
2. Use client-side encryption so the remote storage provider cannot read chat contents.
3. Make the backup, verification, restore, and prune operations explicit, review-gated commands — never unattended or implicit.
4. Preserve deterministic evidence that the archived copy equals the original source at the time of backup.
5. Support a real restore rehearsal from the encrypted remote back onto the local machine.
6. Integrate with the existing review-only guard: a `workspaceStorage` entry becomes eligible for local deletion only after it has been uploaded, verified, restored as a rehearsal, and explicitly approved for pruning.

## Non-Goals

1. **No service account or server.** Backups are to a personal Google Drive, authenticated by the user's own OAuth credentials via `rclone`. There is no shared server, pooled account, or API backend.
2. **No broad deletion of `workspaceStorage`.** This design is only for orphaned entries containing chat or history. Active workspace storage remains untouched.
3. **No real-time/continuous backup.** The tool is a point-in-time batch workflow, not a daemon.
4. **No cross-user or team sharing.** Each user has their own remote crypt target and recovery material.
5. **No replacement for general backup/DR.** This is a narrow safety net for editor chat state, not a full-machine backup strategy.

## Architecture: rclone Crypt over Personal Google Drive

### Transport and storage

- **Remote protocol:** Google Drive via `rclone`.
- **Authentication:** `rclone`'s built-in OAuth client first. The user runs `rclone config`, selects Google Drive, and authenticates in a browser to their own account. A personal OAuth client ID is optional and supported if the user prefers it; the default built-in client is sufficient.
- **Encryption layer:** `rclone crypt` over the Google Drive remote. The crypt remote encrypts file names and contents client-side; operations through the crypt remote (such as `rclone ls` or `rclone copy`) see logical plaintext names and contents, while rclone handles encryption and decryption transparently. The crypt password and optional salt are stored in the user's local `rclone.conf`; that file is protected on disk via `chmod 0600` and is never uploaded.
- **Server-side visibility:** Google Drive sees only encrypted blobs and encrypted file names. It cannot read chat content or original paths. To prove this, inspect the underlying Drive remote directly; the crypt remote itself presents plaintext.

### Layout on the encrypted remote

Each backed-up workspace becomes one encrypted compressed archive stored under a single root folder on the crypt remote:

```
<vscode-chat-backup-crypt-remote:root>/
  manifests/
    <workspace-hash>.manifest.json
    <workspace-hash>-<archive-sha256>.manifest.json
  archives/
    <workspace-hash>-<archive-sha256>.tar.gz.bin
```

- `<workspace-hash>` is the VS Code workspace hash used in the local `workspaceStorage/` directory name. It is deterministic, opaque, and already stable across machines for the same workspace path.
- Archive objects are immutable and content-addressed by the plaintext archive SHA-256. A new upload publishes a new archive object; superseded objects are retained automatically. Any future garbage collection requires a separately verified `restored` replacement, preserved prior-manifest metadata, and explicit user action.
- Each immutable archive has an immutable sidecar manifest named `<workspace-hash>-<archive-sha256>.manifest.json` containing its complete fingerprint, archive hash/size, member bounds, source path, and creation metadata. The mutable `<workspace-hash>.manifest.json` is only the current-state pointer and never the sole record for an older archive.
- Archive and manifest names are encrypted by the crypt remote.

## Commands

All commands are subcommands of a single entry point, proposed name `vscode-chat-backup`. Each command is interactive by default and requires `--yes` only for scripted use after review.

### `plan`

1. Enumerate every `workspaceStorage` entry whose `workspace.json` target path does not exist.
2. Classify each entry as:
   - **chat-bearing** if it contains `chatSessions/`, `chatEditingSessions/`, or another explicitly recognized extension chat/history directory.
   - **unknown/REVIEW** if no recognized directory is present. Absence of a directory does not prove that `state.vscdb` lacks chat, so the plan command never labels an entry definitively non-chat from metadata alone. The user may explicitly select an unknown entry for archive.
3. Print a table: workspace hash, original workspace path, source storage path, chat-bearing/unknown/REVIEW flag, local size, proposed archive name, and a recommendation.
4. Every orphan remains REVIEW/protected under the existing guard; this command does not mark any entry for deletion.
5. No source file is modified. Full content is read only during `upload`.

### `upload`

1. For each orphan selected by the user (including an `unknown/REVIEW` entry explicitly included):
   a. Verify the source directory still exists and is still orphaned (its `workspace.json` target path does not exist).
   b. Quit or confirm VS Code is not running. The tool must either detect that VS Code is fully quit (no `Code` or `Code Helper` processes with the user's UID) or fail closed if open checks cannot be completed within a bounded timeout.
   c. Before staging, walk the live source with no-follow metadata checks. Reject the source immediately if any entry is a symlink, device, socket, FIFO, or other special file; do not copy, transform, skip, or materialize that entry. Use descriptor-relative/no-follow traversal so the copy cannot follow a link or block on a FIFO. Compute a **pre-copy live fingerprint** of the source tree (see Fingerprinting below) and record the live root identity (device/inode of the source directory).
   d. Copy only regular files and directories into a staging directory with `umask 077`, directory mode `0700`, and file mode `0600`; the copy operation itself must never follow links or special files.
   e. Walk the staged tree and fail closed if any entry is not a regular file or directory. Report the offending path and abort the upload for that entry. Compute the **staged fingerprint** of the staged tree.
   f. Compute a **post-copy live fingerprint** of the live source tree. Re-check the live root identity. The upload proceeds only if the pre-copy live fingerprint, the staged fingerprint, and the post-copy live fingerprint are all identical and the root identity has not changed. If any differ, abort and report source mutation during staging.
   g. Use the staged fingerprint as the deterministic tree fingerprint recorded in the manifest, and record the exact `regular_file_count` and `regular_bytes` totals of the staged tree. These become the authoritative caps for hostile-entry validation during `verify` and `restore`.
   h. Create a compressed archive from the staged tree. The archive contains only regular files and directories; link entries, device files, and special files are never archived. Each archive member is stored under the single top-level directory `<workspace-hash>/` so the restore prefix constraint can be enforced. The archive creation process must not mutate the original source directory in place.
   i. Compute the plaintext compressed archive SHA-256 and byte size. Use that digest in the immutable `archives/<workspace-hash>-<archive-sha256>.tar.gz.bin` name. Upload it with a temp-upload-then-move protocol, then confirm the final remote object exists, can be downloaded, and its downloaded SHA-256 and byte size match the local archive.
   j. Atomically write and publish the immutable sidecar manifest `<workspace-hash>-<archive-sha256>.manifest.json` using the temp-upload-then-move protocol. Then atomically write and publish the mutable `<workspace-hash>.manifest.json` pointer with `state` set to `uploaded`, `source_path` canonicalized, `generation` and `updated_at` bumped, and the immutable archive name and all source/archive totals recorded. The pointer is published only after the archive and sidecar are confirmed; the `uploaded` transition is committed only after all remote objects are confirmed.
2. If VS Code is detected running, the command fails closed: no source data is staged, no archive is created, and the user is told to quit VS Code first.
3. Staging directories are cleaned up on normal exit, `SIGINT`, `SIGTERM`, and `EXIT`. A leftover staging directory is reported as an error on the next run.

### `verify`

1. For each uploaded archive selected by the user:
   a. Download the immutable archive from the crypt remote to a fresh staging directory with restrictive permissions (`umask 077`, mode `0700`/`0600`). `rclone` decrypts file names and contents transparently; the staging file is plaintext bytes.
   b. Before parsing or extracting, compare the downloaded byte size and SHA-256 to the manifest's `archive_size_bytes` and `archive_sha256`. On mismatch, record `verify-failed` and stop.
   c. Validate the archive metadata against every rule in Hostile Tar Entry Validation below. Reject the archive if any member fails.
   d. Create a fresh extraction directory with mode `0700` and umask `077`. Extract only after validation succeeds.
   e. Recompute the deterministic tree fingerprint of the extracted tree, using the single top-level `<workspace-hash>/` directory as the root.
   f. Compare it to the fingerprint recorded in the manifest.
   g. If equal, atomically write the local manifest with `state` set to `verified`, `generation` and `updated_at` bumped, and publish the same manifest remotely. The transition is committed only after both writes succeed.
   h. If not equal, atomically write the local manifest with `state` set to `verify-failed`, `generation` and `updated_at` bumped, record the error, and publish the same manifest remotely. Stop; the user must investigate before any prune.
2. A verify failure is treated as a data-integrity incident; the corresponding local source is never pruned until the remote archive is corrected or replaced.

### `restore`

1. For a selected workspace hash and a destination directory chosen by the user:
   a. Refuse to use an existing destination; restore always creates a new directory atomically.
   b. Download the immutable archive from the crypt remote to a staging file with mode `0600`. `rclone` decrypts transparently.
   c. Compare the downloaded byte size and SHA-256 to the manifest's `archive_size_bytes` and `archive_sha256`. On mismatch, record `restore-failed` and stop before parsing or extracting.
   d. Validate the archive metadata against every rule in Hostile Tar Entry Validation below. Reject the archive if any member fails.
   e. Canonicalize the destination parent, require it to exist and be writable, and create a hidden wrapper sibling under that parent (`.<workspace-hash>.restore.<nonce>`) with mode `0700` and umask `077`. This guarantees the final rename is same-filesystem; reject a destination whose parent cannot satisfy this check. Extract only after archive validation succeeds.
   f. Recompute the fingerprint of the wrapper's sole `<workspace-hash>/` child and compare it to the manifest fingerprint.
   g. If the fingerprint matches, atomically rename that validated `<workspace-hash>/` child—not the wrapper—into the new user-specified destination only after all checks pass. Never overwrite an existing destination; remove the now-empty wrapper only after the child rename succeeds.
   h. Atomically write the local manifest with `state` set to `restored`, `generation` and `updated_at` bumped, record `restore.verified_fingerprint`, `restore.destination`, and `restore.restored_at`, and publish the same manifest remotely. The transition is committed only after both writes succeed. Report success and print the restore location.
   i. If any check fails, atomically write the local manifest with `state` set to `restore-failed`, `generation` and `updated_at` bumped, record `restore.error`, and publish the same manifest remotely. Stop. The local source remains protected from `prune-verified`.
2. The `restore` command is the **real remote restore rehearsal**; a successful `restore` is required before any entry can become eligible for `prune-verified`.
3. The default destination is a sub-directory under `~/.local/share/vscode-chat-restores/<workspace-hash>/`. The user may override it.

### `prune-verified`

1. List only local orphan entries whose manifest `state` is `restored` (i.e., `restore.verified_fingerprint` exists and matches the manifest `tree_fingerprint`) **and** whose local source fingerprint freshly matches the manifest fingerprint. The source path is taken from the manifest's `source_path` field.
2. Require explicit confirmation per entry or for a reviewed batch. The confirmation must display the canonical `source_path` and the original workspace path.
3. On confirmation for a single entry:
   a. Confirm VS Code is fully quit or fail closed if open checks cannot complete within a bounded timeout; verify with `lsof` that no process has the `source_path` open. Abort if either check fails.
   b. Canonicalize and verify the manifest's `source_path` equals the expected path under `~/Library/Application Support/Code/User/workspaceStorage/<workspace_hash>`. Reject any deviation.
   c. Before renaming, atomically write a local prune journal with `{source_path, quarantine_path, workspace_hash, generation}` using mode `0600` and `fsync`/`rename`. Then atomically rename the exact source directory to the unique quarantine sibling on the same filesystem. This removes the path from VS Code's live namespace before the final freshness check. If the journal or rename fails, abort without mutation.
   d. Fingerprint the quarantined directory and compare it to the manifest fingerprint. If it differs, attempt to atomically rename it back to the original source path. Clear the journal only after that rollback succeeds; if rollback fails (including because the source path was recreated), preserve the quarantine and journal, report both paths, and stop without pruning.
   e. Move the verified quarantine directory to a uniquely named item in the macOS Trash using `osascript -e 'tell application "Finder" to delete POSIX file …'` or equivalent safe move-to-trash API. The unique name is `<workspace-hash>-<original-workspace-basename>-<iso-timestamp>`.
   f. Update the manifest `state` to `pruned`, bump `generation` and `updated_at`, record the Trash item name and prune timestamp, atomically write the local manifest, and publish the same manifest remotely. Preserve the `restore` record for audit. The transition is committed only after both writes succeed; clear the prune journal only after that commit.
4. The command refuses to delete any path that is not the exact `source_path` listed in the manifest under `~/Library/Application Support/Code/User/workspaceStorage/`. No shell `rm -rf` or broad glob deletion is used.
5. If the fingerprint freshness check fails, the manifest `state` is not `restored`, `source_path` does not canonicalize correctly, or `restore.verified_fingerprint` does not match `tree_fingerprint`, the entry is reported as ineligible and skipped.

## Archive and Staging Security

### Staging directory

- Location: under a temporary root such as `$(mktemp -d /tmp/vscode-chat-backup.XXXXXX)` or a user-configured staging parent.
- Permissions: created with `umask 077`; directory mode `0700`; files copied with mode `0600`.
- No hard links to the source are used. The staging tree is a real copy so that compression and fingerprinting operate on a snapshot isolated from concurrent source mutation.

### Source immutability

- `upload` never modifies files inside `~/Library/Application Support/Code/User/workspaceStorage/`. The source directory is read, copied, archived, and optionally moved to Trash only by `prune-verified`.
- Archive creation reads from the staging copy, not the live source.

### Signal and crash cleanup

- The staging directory is registered with a trap for `INT`, `TERM`, and `EXIT` that removes it.
- If cleanup fails, the next tool invocation detects a leftover staging directory and refuses to run until the user inspects it.

## Source Consistency and Deterministic Fingerprints

### Fingerprint algorithm

The deterministic tree fingerprint is computed on the staged tree, with the workspace hash treated as the single root directory name. This matches the archive layout described in the `upload` command. Path ordering is bytewise (`LC_ALL=C` collation) so the fingerprint is deterministic across machines and locales.

1. Treat the staged tree as if its root is named `<workspace-hash>/`.
2. Walk the tree in bytewise lexicographic path order (`LC_ALL=C` `sort` semantics).
3. For each regular file: emit `<workspace-hash>/<relative-path>\0<sha256(file-contents)>\0`.
4. For each directory: emit `<workspace-hash>/<relative-path>/\0`.
5. Concatenate all records in sorted order and compute SHA-256 over the concatenation.
6. Encode the final digest as lowercase hex prefixed with `sha256:`. This is the **tree fingerprint** stored in the manifest.

The fingerprint is deterministic, content-addressed, and independent of timestamps, ownership, or mode bits. It proves that a later extracted tree is byte-identical to the staged source.

### Source consistency during upload

Because VS Code must be fully quit before upload, the source tree is quiescent. If the running-process check cannot complete (for example, `pgrep` times out), the command fails closed rather than risk concurrent mutation.

### Fingerprint in the manifest

The manifest stores:

```json
{
  "version": 1,
  "workspace_hash": "<hash>",
  "original_workspace_path": "<full original workspace path>",
  "source_path": "<full canonical source storage path, e.g. ~/Library/Application Support/Code/User/workspaceStorage/<hash>>",
  "archive_name": "<hash>-<archive-sha256>.tar.gz.bin",
  "tree_fingerprint": "sha256:...",
  "archive_sha256": "sha256:...",
  "archive_size_bytes": 12345,
  "regular_file_count": 42,
  "regular_bytes": 12345678,
  "created_at": "2026-08-01T12:34:56Z",
  "updated_at": "2026-08-01T12:34:56Z",
  "generation": 1,
  "state": "uploaded|verified|restored|pruned|verify-failed|restore-failed",
  "restore": {
    "verified_fingerprint": "sha256:...",
    "destination": "/Users/.../.local/share/vscode-chat-restores/<hash>/",
    "restored_at": "2026-08-01T12:40:00Z"
  },
  "pruned": {
    "trash_name": "<hash>-<basename>-20260801T123456Z",
    "pruned_at": "2026-08-01T12:35:00Z"
  }
}
```

## Hostile Tar Entry Validation

Archive extraction is treated as untrusted input because the remote could be compromised or a manifest could be swapped. Validation is a **hard pre-extraction gate** that runs against archive metadata before any bytes are written to disk. Plain `tar -tf` followed by a later extraction is not sufficient, because the extraction pass can still create dangerous links, device files, or prefix-conflicting members. The tool must inspect the full member list first and reject the archive if any member violates a rule.

Before extracting any archive, the tool validates every tar entry from metadata alone, and also validates aggregate archive metadata before any member is processed:

1. **No absolute paths.** Entries starting with `/`, Windows drive-letter roots (e.g., `C:`), or backslash path separators are rejected.
2. **Exactly one valid root directory.** The archive must contain exactly one top-level directory named `<workspace-hash>/`. Entries whose normalized name is empty, `.`, a single directory segment other than `<workspace-hash>/`, or any path that resolves above that root are rejected.
3. **No parent-directory traversal.** Entries containing `..` path components, or that normalize to a path outside the expected root, are rejected.
4. **Prefix constraint.** Every entry must be under the single expected top-level directory `<workspace-hash>/`. Members that are the root directory itself are allowed only as the single archive root; no other root-level files or directories are permitted.
5. **No duplicate or path-conflicting members.** If two entries normalize to the same path, or if a file entry collides with a directory entry at the same normalized path, the archive is rejected.
6. **No links of any kind.** Hard-link entries and symlink entries are both rejected. No link target is trusted.
7. **No device files, sockets, or FIFOs.** Only regular files and directories are accepted.
8. **Exact member-count and size bounds from the manifest.** Before extraction, validate that:
   - the total number of regular-file entries equals `manifest.regular_file_count`;
   - the sum of regular-file uncompressed sizes equals `manifest.regular_bytes`;
   - the total number of archive members (regular files + directories) does not exceed `min(1_000_000, manifest.regular_file_count + 10_000)`;
   - no single regular-file uncompressed size exceeds `2_147_483_648` bytes (2 GiB);
   - the total uncompressed size of all regular files does not exceed `53_687_091_200` bytes (50 GiB).
   Any mismatch aborts extraction and marks the archive as `verify-failed` or `restore-failed`.
9. **Exact path-length bounds.** Each path component must not exceed `255` bytes; the total normalized path length must not exceed `4096` bytes.
10. **Extraction target isolation.** Extraction happens only into a newly created directory with mode `0700` under a validated staging root or destination-parent sibling, as appropriate. No member is allowed to escape this directory, even through symlink or prefix tricks.
11. On validation failure, no extraction occurs. The archive is reported as `verify-failed` (for the `verify` command) or `restore-failed` (for the `restore` command), the staging directory is removed, and the corresponding local source remains protected from `prune-verified`.

## Encrypted Drive, OAuth, and 1Password Recovery Material

### OAuth configuration

- Default: `rclone`'s built-in OAuth application. The user runs `rclone config` once, chooses Google Drive, and completes browser authentication.
- Optional: the user may supply a personal OAuth client ID and secret during `rclone config` if they prefer their own Google Cloud project.
- No service account JSON, no headless server, no shared credentials.

### Crypt remote configuration

- The crypt remote wraps the Google Drive remote. It requires a password and an optional salt.
- The password is generated by the user or by the tool with a cryptographically secure random generator and stored in `rclone.conf`.
- `rclone.conf` is created or updated with file mode `0600` and owned by the user.

### 1Password recovery material

The tool generates a small recovery document for the user to store in 1Password (or another password manager). This document is the only way to decrypt the remote blobs if the local Mac is lost, so it must contain the actual keying material needed to reconstruct the crypt remote:

- **Google Drive remote name** and **crypt remote name** as configured in `rclone.conf`.
- **Crypt password** and **crypt salt** in their portable `rclone obscure` form (the values stored in `rclone.conf` under `password` and `password2`).
- **Crypt filename-encryption and directory-name-encryption modes** (e.g., `filename_encryption = standard`, `directory_name_encryption = true`).
- **Google Drive root folder ID** or **root_folder_id** value, and the exact backup folder path on Drive.
- **rclone version** required.
- **Manifest file name format** and the remote path layout.
- **Re-authentication steps:** the `rclone config` flow to re-authorize the Google Drive remote on a new Mac, plus a reminder that the OAuth refresh token is **not** included in this document and must be re-created by signing in again.
- A clear warning that anyone with this recovery item can decrypt the remote archives; store it only in a trusted password manager.

The recovery material is printed at first successful upload and can be regenerated with `vscode-chat-backup recovery-document`. It is never uploaded to Google Drive and is never written to disk without mode `0600`.

## Manifest Schema and State Machine

### Schema

The immutable archive sidecar contains only archive identity and source-snapshot metadata: `workspace_hash`, `original_workspace_path`, `source_path`, `archive_name`, `tree_fingerprint`, `archive_sha256`, `archive_size_bytes`, `regular_file_count`, `regular_bytes`, and `created_at`. It never contains mutable lifecycle fields. The current pointer manifest contains the same immutable fields plus mutable `updated_at`, `generation`, `state`, `restore`, `pruned`, and `history`; lifecycle authority comes from this pointer, while verification of an older archive uses its immutable sidecar.

```json
{
  "$schema": "vscode-chat-backup-manifest-v1",
  "version": 1,
  "workspace_hash": "string (required)",
  "original_workspace_path": "string (required, the deleted project/workspace path from workspace.json)",
  "source_path": "string (required, canonical path under ~/Library/Application Support/Code/User/workspaceStorage/<workspace_hash>)",
  "archive_name": "string (required)",
  "tree_fingerprint": "string, 'sha256:' prefix (required)",
  "archive_sha256": "string, 'sha256:' prefix (required, plaintext compressed archive hash)",
  "archive_size_bytes": "integer (required, plaintext compressed archive byte size)",
  "regular_file_count": "integer (required, exact count of regular files in the archive)",
  "regular_bytes": "integer (required, exact total uncompressed size of regular files)",
  "created_at": "ISO 8601 UTC (required)",
  "updated_at": "ISO 8601 UTC (required, set on every state change)",
  "generation": "integer (required, monotonically increasing on every committed state change)",
  "state": "uploaded|verified|restored|pruned|verify-failed|restore-failed (required)",
  "restore": {
    "verified_fingerprint": "string, 'sha256:' prefix, must equal tree_fingerprint",
    "destination": "string (absolute path)",
    "restored_at": "ISO 8601 UTC",
    "error": "string (present only when state is restore-failed)"
  },
  "pruned": {
    "trash_name": "string",
    "pruned_at": "ISO 8601 UTC"
  },
  "history": [
    {
      "state": "string",
      "at": "ISO 8601 UTC"
    }
  ]
}
```

### State machine

```
plan → uploaded ──→ verified ──→ restored ──→ pruned
              └─→ verify-failed ──(re-upload)──→ uploaded
verified ──(restore failure)──→ restore-failed ──(successful retry)──→ restored
```

- `uploaded`: archive and manifest exist on the crypt remote; local source untouched.
- `verified`: a local download-and-extract produced the same tree fingerprint as the source during the `verify` command.
- `restored`: a real restore rehearsal succeeded; `restore.verified_fingerprint` equals `tree_fingerprint`. This is the required gate before `prune-verified`.
- `pruned`: local source moved to uniquely named Trash; remote archive and restore record retained for audit.
- `verify-failed`: `verify` fingerprint mismatch or extraction validation failure; requires manual investigation.
- `restore-failed`: `restore` fingerprint mismatch or hostile-archive validation failure; requires manual investigation.

Allowed transitions:

| From | To | Trigger |
|------|-----|---------|
| (none) | `uploaded` | successful `upload` |
| `uploaded` | `verified` | successful `verify` |
| `verified` | `restored` | successful `restore` with matching fingerprint |
| `restored` | `pruned` | successful `prune-verified` with fresh local fingerprint match |
| `uploaded` | `verify-failed` | `verify` mismatch or extraction failure |
| `verified` | `restore-failed` | `restore` mismatch or hostile-archive rejection |
| `verify-failed` | `uploaded` | re-upload after correction |
| `restore-failed` | `restored` | re-run `restore` successfully after correction; durable restore evidence is rewritten |

### Crash reconciliation

If the tool or machine crashes mid-operation:

1. On the next run, any local staging directory or partially extracted restore directory is detected and reported as an error; the user must inspect and remove it before the command resumes.
2. If a prune journal exists, reconcile it before any new action. If the source path is present and the quarantine path is absent, clear the journal as an unstarted rename. If the source path is absent and the quarantine path is present, fail closed and require explicit recovery: fingerprint the quarantine, then either rename it back to the exact source path or complete the already-confirmed Trash/manifest commit. Never silently discard it. If both paths exist or neither exists, report ambiguity and stop.
3. Local manifests are stored in `~/.local/share/vscode-chat-backup/manifests/` with mode `0700` and per-file mode `0600`. All state changes are written atomically (temp file in the same directory, `fsync`, then `rename`) before any remote upload is attempted, so a crash cannot leave a partially written manifest. Each manifest carries a monotonically increasing `generation` and an `updated_at` timestamp that are both bumped on every committed state change.
4. `upload` is idempotent at the remote level: if an archive and manifest with the same workspace hash and same fingerprint already exist, the upload is skipped and the existing remote state is reconciled locally without regressing `verified`, `restored`, or `pruned` to `uploaded`; restore and prune evidence is preserved.
5. Partially uploaded archives are detected by a missing remote manifest or a remote manifest missing required fields; they are reported and can be re-uploaded.
6. A crash during `verify` leaves the local state as `uploaded` if the remote/local manifest update did not complete, or as `verified` if it completed; the next `verify` reconciles local against remote and starts fresh.
7. A crash during `restore` leaves the state as `verified` if no durable restore evidence was written, or as `restored` if the write completed before the crash. `prune-verified` must check for the durable `restore.verified_fingerprint` record, not only the top-level state, so an incomplete restore cannot be pruned.
8. If local and remote manifests differ (for example, after a crash between the local write and remote upload), the tool reconciles using the higher `generation` first. If the remote generation is higher, the remote copy is downloaded and mirrored locally. If generations are equal but content differs, the tool reports a manifest conflict and fails closed; the user must inspect and resolve it manually. If generations are equal and content is identical, no action is needed.

### Local manifest persistence

Manifests are stored in two places: a local cache and the crypt remote.

- **Local directory:** `~/.local/share/vscode-chat-backup/manifests/`, created with mode `0700`.
- **Local file:** one current-state JSON manifest per workspace hash, named `<workspace-hash>.manifest.json`, mode `0600`; immutable sidecar manifests are retained locally by archive digest.
- **Remote files:** the current pointer at `manifests/<workspace-hash>.manifest.json` plus one immutable sidecar at `manifests/<workspace-hash>-<archive-sha256>.manifest.json` for every archive.
- **Atomic local write:** every manifest update is written to a unique temp file in the same directory, `fsync`-ed, and renamed over the target. There is never a partially written manifest on disk.
- **Atomic remote write:** every manifest update is uploaded to a temporary name on the crypt remote (for example, `manifests/<workspace-hash>.manifest.json.tmp.<generation>`), then moved to the final name. This ensures a remote consumer never sees a partial manifest.
- **Commit semantics:** a state transition is considered committed when the local current pointer and remote current pointer are atomically updated after the immutable archive and sidecar succeed. The sidecar is never overwritten.
- **Remote publication ordering:** for every state transition, the tool increments `generation` and `updated_at`, atomically writes the local manifest, then performs the remote temp-upload-and-move. If the remote step fails, the local manifest already reflects the new state; the user can retry the same command, which will detect the generation mismatch and complete the remote publication.
- **Manifest authority:** in normal operation the local and remote copies are identical. If they differ, the copy with the higher `generation` is authoritative. Equal generations with unequal content are a conflict and the tool fails closed, requiring manual resolution. On first run on a second Mac, the tool downloads the remote manifest set into the local manifest directory.
- **Required fields for prune authority:** `prune-verified` refuses to act unless the local manifest has a valid `source_path`, `state` is `restored`, and `restore.verified_fingerprint` equals `tree_fingerprint`.

## Failure Semantics

- **Fail closed.** If any safety check (VS Code quit, fingerprint match, open-file check, tar validation, remote existence) cannot be confirmed, the operation stops.
- **Per-entry atomicity with explicit partial batches.** Each selected entry advances its own manifest only after its local and remote atomic writes succeed. A batch may report partial success; failed entries remain in their prior protected state and are never rolled back by pretending the remote update was transactional.
- **Never delete on failure.** A failed upload, verify, or restore never triggers local deletion.
- **Timeout bounded.** External calls to `rclone`, `lsof`/`pgrep`, and `osascript` have bounded timeouts. A timeout is treated as a failure, not a success.
- **No source mutation on tool crash.** Staging is a copy; source is only moved by the explicit `prune-verified` command after all prior gates succeed.

## Trash Pruning

The `prune-verified` command is the only local deletion path. It uses the exact sequence defined in the `prune-verified` command section and additionally:

1. Requires the manifest `state` to be `restored` with `restore.verified_fingerprint` equal to `tree_fingerprint`.
2. Uses the manifest's `source_path` as the only source path it will ever move to Trash.
3. Bumps `generation` and `updated_at`, atomically writes the local manifest, and publishes it remotely before reporting the prune as committed.
4. Never empties Trash.

The tool never empties Trash. The user retains final control through the standard macOS Trash UI.

## Testing and Acceptance Criteria

### Unit/functional tests

1. **Fingerprint stability:** Two identical trees produce the same fingerprint; a single byte change produces a different fingerprint.
2. **Source immutability:** After `upload`, the source directory's modification time and contents are unchanged (verified by a before-and-after fingerprint).
3. **Crash cleanup:** Simulated `SIGINT` during staging leaves no staging directory.
4. **VS Code running guard:** `upload` exits non-zero when a fake `Code` process is present.
5. **Source special-file guard:** `upload` rejects a source containing a symlink, device file, socket, or FIFO before copying and never follows or blocks on it; a second staged-tree validation also fails closed.
6. **Hostile tar rejection:** Tar entries with `..`, absolute paths, device files, and hard links are all rejected during `restore`.
7. **Trash naming:** `prune-verified` produces a Trash item whose name contains the workspace hash, basename, and timestamp.
8. **Prune journal crash recovery:** terminate after journal write, after source-to-quarantine rename, and after the Trash move; restart reconciliation must preserve or restore the exact source/quarantine/Trash state and must never silently discard a directory.
9. **Restore tree finalization:** restore an archive whose sole top-level child is `<workspace-hash>/` and assert that exactly that child, not an extra wrapper, lands at the requested destination.
10. **Cross-volume restore rejection:** select a destination on another volume and assert the tool rejects it before extraction or requires a same-filesystem destination-parent sibling; no partial destination is left.

### Integration tests

1. Run `plan` on a test machine; confirm chat-bearing orphans are identified correctly.
2. Run `upload` for a small chat-bearing entry; confirm the archive and manifest appear on the crypt remote.
3. Run `verify` for the same entry; confirm state transitions to `verified`.
4. Run `restore` into a fresh directory; confirm the manifest `state` becomes `restored`, the extracted tree fingerprint matches the source, and that chat data can be read by VS Code when pointed at the restore directory.
5. Run `prune-verified` for the same entry; confirm the local directory moves to Trash with a unique name and the manifest state becomes `pruned`.
6. Inspect the macOS Trash and confirm the item is recoverable.
7. Confirm that `prune-verified` refuses to delete the local source unless the manifest `state` is `restored` and `restore.verified_fingerprint` matches `tree_fingerprint`.

### Manual safety checklist

- [ ] `mac-reclaim --deep --dry-run` still reports orphaned `workspaceStorage` as REVIEW/protected and does not list it as a deletion candidate.
- [ ] `vscode-chat-backup plan` does not require write access to `workspaceStorage`.
- [ ] `vscode-chat-backup upload` fails if VS Code is running.
- [ ] Inspecting the underlying Google Drive remote directly (not the crypt remote) shows encrypted blob names and encrypted file names; the crypt remote's `rclone ls` shows only logical plaintext names, and no original workspace path is visible.
- [ ] The recovery document can be used on a second Mac with no original `rclone.conf` to re-create the rclone remotes, re-authorize Google Drive, and decrypt an existing archive.

## Rollout and Migration from the Current Review-Only Guard

### Current behavior

`mac-reclaim --deep` already reports every orphaned `workspaceStorage` entry as REVIEW/protected and never removes it. The earlier temporary local keep-list guard has been removed after patched installed binary verification; the source guard in `mac-reclaim` is authoritative.

### Migration path

1. The new `vscode-chat-backup` command is added as a separate binary. It does not change `mac-reclaim` deletion behavior.
2. `mac-reclaim` keeps its existing review-only behavior: orphaned `workspaceStorage` is never a deletion candidate.
3. Once `vscode-chat-backup` ships and is documented, the skill and README guidance can optionally recommend running `vscode-chat-backup plan` after `mac-reclaim --deep --dry-run` so the user has an actionable next step for REVIEW items.
4. A future optional integration could allow `mac-reclaim --deep` to call `vscode-chat-backup prune-verified` only for entries the user has explicitly pre-approved, but that is out of scope for this design.

### Documentation updates

- The `mac-optimize` skill already states that orphaned `workspaceStorage` is REVIEW/protected until an archive-first backup and explicit verified prune workflow exists. This design is that workflow.
- No wording in README.md, SKILL.md, or references/reference.md should claim that `workspaceStorage` is safely deleted. The only safe deletion path is `prune-verified` after upload, verify, restore rehearsal, and explicit user confirmation.

## Out of Scope

- Automated unattended pruning.
- Deletion of active workspace storage.
- Cross-platform support beyond macOS.
- Migration from non-encrypted backups or non-Google-Drive remotes.
- GUI or menu-bar integration.

## Glossary

- **workspace hash:** The opaque directory name VS Code uses inside `workspaceStorage/`, derived from the workspace path.
- **orphan:** A `workspaceStorage` entry whose recorded original workspace path no longer exists on disk.
- **chat-bearing:** An orphan that contains recoverable chat, history, or agent-session artifacts.
- **tree fingerprint:** A deterministic SHA-256 summary of a directory tree's file contents and paths.
- **crypt remote:** An `rclone` remote that encrypts file names and contents on top of a base remote.
