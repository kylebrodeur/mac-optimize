# Full Workspace Git Audit Design

## Goal

Provide a repeatable, read-only audit of every Git repository under a configurable workspace root, combining ordinary repository state with the existing linked-worktree safety engine and saving private Markdown/JSON reports on request.

## Scope

The command audits repositories under `~/workspace` by default. It does not move, delete, prune, fetch, commit, or mutate repositories. It may write reports only when `--save` is explicitly supplied.

For each repository it records:

- Absolute path, current branch, HEAD, origin URL, and upstream ref.
- Last commit timestamp and filesystem modification timestamp.
- Dirty tracked-file count, untracked-file count, ahead/behind counts when upstream exists.
- Whether the repository has commits but no remote/upstream, or has an unborn HEAD.
- Total on-disk size and immediate-child size buckets classified as source, Git metadata, agent state, dependencies, generated output, or other.
- Linked worktree count and the output of `worktree-audit` for the configured root.

For mounted volumes it records capacity/free space and known backup roots, including `/Volumes/Work HD/mac-optimize-backups` and `/Volumes/Work HD/workspace-cold` when present.

## Report contract

The JSON report uses `schema_version: 1` and contains `generated_at`, `root`, `repository_count`, `repositories`, `volumes`, and `worktree_engine`. Paths remain absolute because reports are private operator artifacts.

The Markdown report contains:

1. Scope and timestamp.
2. Summary counts.
3. Ranked `BACKUP_NOW`, `SYNC_REVIEW`, and `COLD_ARCHIVE` candidates.
4. Rebuildable-bulk notes for dependency/build/cache directories.
5. Linked-worktree engine output.
6. Mounted-volume capacity.
7. Exact archive-first command suggestions and a statement that no automatic move/delete/prune occurred.

Candidate ranking prioritizes dirty/untracked state and local-only commits, then local-only clean repositories, while explicitly calling out rebuildable bulk that should not be copied as irreplaceable work.

## CLI

```text
workspace-audit [ROOT]
workspace-audit [ROOT] --save
workspace-audit [ROOT] --save --output-dir PATH
workspace-audit [ROOT] --format text|json
```

- `ROOT` defaults to `$WORKSPACE_AUDIT_ROOT`, then `$HOME/workspace`.
- `--save` atomically writes a timestamped Markdown and JSON pair to `$WORKSPACE_AUDIT_DIR` or `~/Library/Application Support/mac-optimize/private/audits`.
- `--output-dir` overrides the save directory.
- `--format json` emits the JSON report to stdout; the default emits the Markdown report to stdout.
- Missing `worktree-audit` is reported as an unavailable engine rather than failing the repository scan.

## Privacy and safety

- Reports default to stdout and are not written without `--save`.
- Saved reports are created beneath a private directory with mode `0700`; report files use mode `0600` and atomic replacement.
- The command never includes credentials, process arguments, or file contents.
- The command never invokes `git fetch`, `git reset`, `git clean`, `git worktree remove`, or any backup/prune operation.
- Backup suggestions use the existing `worktree-audit --backup` flow for linked worktrees and clearly distinguish that recommendation from execution.

## Integration

- Add `bin/workspace-audit`; `install.sh` already installs every file in `bin/`.
- Add a focused self-contained regression harness under `test/`.
- Add Makefile targets for `workspace-audit` and include it in `doctor` tool checks.
- Document full-workspace scope and private reports in README and CHANGELOG.
- Keep the public repository free of this machine's generated audit output.
