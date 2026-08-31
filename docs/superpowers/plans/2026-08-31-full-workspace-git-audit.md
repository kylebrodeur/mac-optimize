# Full Workspace Git Audit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a private, read-only `workspace-audit` command that audits every Git repository under a workspace root, incorporates linked-worktree safety results, and emits ranked Markdown/JSON backup recommendations.

**Architecture:** A Python 3 standard-library CLI recursively discovers Git roots while pruning dependency/build/cache directories. It queries Git with optional locks disabled, classifies repository risk, measures immediate-child storage buckets, invokes the existing `worktree-audit` engine for linked-worktree evidence, and renders one report model into terminal Markdown or JSON. `--save` atomically writes private timestamped report pairs; no destructive command is ever invoked.

**Tech Stack:** Python 3 standard library, Bash regression harness, Git, existing `worktree-audit` and `common.sh`.

**Spec:** `docs/superpowers/specs/2026-08-31-full-workspace-git-audit-design.md`

## Global Constraints

- Default root is `$WORKSPACE_AUDIT_ROOT`, then `$HOME/workspace`.
- Reports are private artifacts under `~/Library/Application Support/mac-optimize/private/audits` unless overridden.
- Saved directories use mode `0700`; saved reports use mode `0600` and atomic replacement.
- The command never moves, deletes, prunes, fetches, commits, resets, or reads file contents.
- No runtime dependencies beyond Python 3 standard library and Git; missing optional worktree engine is reported, not fatal.
- Rebuildable dependency/build/cache directories are recommendations, not backup payloads.

---

### Task 1: Focused CLI regression harness

**Files:**
- Create: `test/workspace-audit-test.sh`

**Interfaces:**
- Consumes: `bin/workspace-audit` CLI with `--save`, `--output-dir`, and `--format json`.
- Produces: deterministic assertions for repository discovery, dirty/untracked classification, private report files, generated-size buckets, and no destructive Git operations.

- [ ] **Step 1: Write the failing test**

Create a temporary HOME and workspace containing:

- one clean Git repository with a commit and no remote;
- one dirty Git repository with one modified tracked file and one untracked file;
- one nested fake Git directory under `node_modules` that must be skipped;
- a fake `worktree-audit` executable that records invocation and emits a known report.

Run the CLI with `--save --output-dir "$TMP/report"`, then assert with Python that JSON contains exactly two repositories, the dirty repository has nonzero tracked/untracked counts and `BACKUP_NOW` verdict, the dependency bucket is present, both report files exist, and the fake engine received the workspace root. Assert no Git ref or working-tree file was changed except the intentional fixture edit.

- [ ] **Step 2: Run test to verify it fails**

Run:

```bash
bash test/workspace-audit-test.sh
```

Expected: FAIL because `bin/workspace-audit` does not exist.

- [ ] **Step 3: Commit test only**

```bash
git add test/workspace-audit-test.sh
git commit -m "test: define full workspace audit contract"
```

---

### Task 2: Implement workspace audit command

**Files:**
- Create: `bin/workspace-audit`

**Interfaces:**
- Consumes: optional root positional argument, `WORKSPACE_AUDIT_ROOT`, `WORKSPACE_AUDIT_DIR`, `WORKTREE_AUDIT_BIN`, `--save`, `--output-dir`, and `--format text|json`.
- Produces: one JSON-compatible report model and Markdown rendering; timestamped `.json` and `.md` files when saving.

- [ ] **Step 1: Implement discovery and Git queries**

Use `os.walk` without following symlinks. Stop descending once a directory contains `.git`; prune `.git`, `node_modules`, `.cache`, `Library`, `.next`, `dist`, `build`, `coverage`, `test-results`, `.playwright-mcp`, `.turbo`, and `vendor` while discovering roots. Run Git commands through one helper with `GIT_OPTIONAL_LOCKS=0`, captured stdout/stderr, and bounded timeouts.

For each root collect path, branch, HEAD, origin, upstream, last commit ISO timestamp, root mtime, ahead/behind counts, tracked/untracked status counts, and whether HEAD is unborn. Count linked worktrees from `git worktree list --porcelain`.

- [ ] **Step 2: Implement size and risk classification**

Measure total size with `du -sk`. Measure immediate children and classify names into `dependencies`, `generated`, `git`, `agent_state`, `source_or_other`. Set verdicts as:

- `BACKUP_NOW` for dirty/untracked state, unpublished commits, or unborn/local-only work that cannot be reconstructed remotely;
- `SYNC_REVIEW` for repositories behind upstream without local-only changes;
- `COLD_ARCHIVE` for clean repositories with no remote or old local-only state;
- `HEALTHY` for clean repositories synchronized with upstream.

Sort recommendations by risk first, then size descending. Include explicit notes that dependency/generated buckets are rebuildable.

- [ ] **Step 3: Integrate the existing worktree engine**

Resolve the engine from `WORKTREE_AUDIT_BIN`, `PATH`, or the repository's sibling `bin/worktree-audit`. Invoke it read-only with the configured root and `GIT_OPTIONAL_LOCKS=0`; capture output, exit code, and unavailable/error state in `worktree_engine`. Never pass `--backup`, `--prune`, or `--yes`.

- [ ] **Step 4: Render and save reports safely**

Render Markdown with scope, summary, ranked candidates, size notes, engine output, mounted-volume capacity, and archive-first commands. Render JSON from the same report model. Enumerate `/Volumes` and use `shutil.disk_usage`, recording only mount name, capacity, free, and recognized backup roots. On `--save`, create the output directory with `0700`, write temporary files with `0600`, flush/fsync, and `os.replace` them to timestamped filenames.

- [ ] **Step 5: Run focused test to verify it passes**

Run:

```bash
bash test/workspace-audit-test.sh
```

Expected: all assertions pass, including exact repository count, dirty classification, report creation, and engine invocation.

- [ ] **Step 6: Commit implementation**

```bash
git add bin/workspace-audit test/workspace-audit-test.sh
git commit -m "feat: add full workspace git audit reports"
```

---

### Task 3: Integrate installation, doctor, and documentation

**Files:**
- Modify: `Makefile:1-30`
- Modify: `bin/mac-optimize-doctor:14-18`
- Modify: `README.md:28-58,69-101,150-165`
- Modify: `CHANGELOG.md:7-30`

**Interfaces:**
- Consumes: installed `workspace-audit` executable.
- Produces: discoverable Makefile command, doctor coverage, documented private report workflow, and release-facing change note.

- [ ] **Step 1: Add Makefile command**

Add `workspace-audit` to `.PHONY` and add a `workspace-audit:` target that runs `bin/workspace-audit --save`, keeping existing `audit` as the linked-worktree-only engine target.

- [ ] **Step 2: Add doctor coverage**

Include `workspace-audit` in the tools-on-PATH loop without changing launchd checks. The doctor must remain read-only and must not run an audit.

- [ ] **Step 3: Document full scope and privacy boundary**

Document `workspace-audit` separately from `worktree-audit`: full repository scan versus linked-worktree safety engine, last Git commit plus filesystem mtime, generated/dependency separation, private Markdown/JSON output, and explicit non-destructive behavior. Document `WORKSPACE_AUDIT_ROOT`, `WORKSPACE_AUDIT_DIR`, and `WORKTREE_AUDIT_BIN`.

- [ ] **Step 4: Add changelog entry**

Add the new full workspace Git audit/report capability under `Unreleased`, including the private report location and archive-first safety boundary.

- [ ] **Step 5: Run documentation and shell checks**

Run:

```bash
bash -n bin/workspace-audit test/workspace-audit-test.sh install.sh uninstall.sh
```

Expected: no syntax errors.

- [ ] **Step 6: Commit integration**

```bash
git add Makefile bin/mac-optimize-doctor README.md CHANGELOG.md
git commit -m "docs: integrate workspace audit reporting"
```

---

### Task 4: Full verification and current report

**Files:**
- Create outside repository: `~/Library/Application Support/mac-optimize/private/audits/<timestamp>-workspace-git-audit.md`
- Create outside repository: matching `.json` report

- [ ] **Step 1: Run focused regression test**

```bash
bash test/workspace-audit-test.sh
```

- [ ] **Step 2: Run full repository suite**

```bash
make test
```

- [ ] **Step 3: Verify install and doctor integration**

```bash
make install
make doctor
```

Expected: `workspace-audit` is installed and doctor reports it on PATH.

- [ ] **Step 4: Generate and inspect the real private audit**

```bash
bin/workspace-audit "$HOME/workspace" --save
```

Inspect the generated report for repository count, Work HD capacity, worktree engine output, ranked candidates, and absence of destructive action claims.

- [ ] **Step 5: Verify repository cleanliness and diff**

```bash
git diff --check
git status --short
```

Expected: no whitespace errors; only intentional source/docs changes remain before release decision.
