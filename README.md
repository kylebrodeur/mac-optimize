# mac-optimize

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey.svg?logo=apple)](#requirements)
[![Shell: bash](https://img.shields.io/badge/shell-bash-4EAA25.svg?logo=gnu-bash&logoColor=white)](#)
[![Dependencies: none](https://img.shields.io/badge/deps-none-success.svg)](#requirements)
[![Agent Skills](https://img.shields.io/badge/Agent%20Skills-agentskills.io-8A2BE2.svg)](https://agentskills.io)

> Disk & shell hygiene for a **Mac that runs a lot of AI coding agents** on limited disk — diagnose, reclaim safely, and audit stray git worktrees, without ever deleting work that isn't provably recoverable.

It's a macOS port of a WSL2 optimization writeup. On WSL2 the failure mode was silent OOM (the kernel dismantled the session while protecting the memory hogs); on a 16 GB M1 running fleets of agents, the equivalent slow death is **disk exhaustion** — package caches, agent runtimes, editor workspace state, and stray git worktrees that grow on every run and never self-reclaim.

The design goal, borrowed from that writeup, is to **change the shape of the failure**: from "silent and fatal" to "observable and bounded." You get a report you can read, a reclaim that's safe by construction, and a watcher that acts at a threshold and tells you what it did.

## Quickstart

```bash
git clone https://github.com/kylebrodeur/mac-optimize.git
cd mac-optimize
make install          # deploy tools to ~/.local/bin + load the launchd watcher

diskreport            # see where your disk went (read-only)
mac-reclaim           # reclaim safe caches now
worktree-audit        # find stray git worktrees
```

`~/.local/bin` must be on your `PATH`. Re-running `make install` is safe.

## Tools

| Tool | What it does |
|------|--------------|
| **`diskreport`** | Read-only "where did my disk go?" — top consumers in `Application Support`, `Caches`, and dev/agent caches, plus the big "review-tier" state (VS Code `workspaceStorage`, Claude `vm_bundles`, `.claude/projects`) and recent reclaim history. Deletes nothing. |
| **`mac-reclaim`** | Reclaims in two tiers. **Safe tier** (default) clears caches that rebuild on demand (`pnpm store prune`, `uv cache prune`, npm `_cacache`, codex runtimes, `.ShipIt` updaters, stale logs) — safe *by construction*. **`--deep`** prunes stale agent state only with *evidence* it's unused, behind `--dry-run`, an allowlist, `lsof` open-file guards, and a keep-newest floor. |
| **`worktree-audit`** | Finds stray git worktrees and classifies each **SAFE** (clean + every commit reachable from another ref) or **REVIEW** (dirty or has commits that exist nowhere else). `--prune` removes SAFE ones; `--backup` archives REVIEW ones to git bundles so they *become* safe to prune. |
| **`diskguard`** | The launchd watcher (an `earlyoom` analog). At login + every 3 h: below 20 GB free it runs the **safe** reclaim and posts a non-blocking notification; below 10 GB it posts an urgent notice pointing at the manual deep tools. Never runs a destructive prune unattended. |

## How it works

Four principles, in order of trust:

1. **Observable before action.** `diskreport` answers "what's using my disk" without touching anything. Diagnose first.
2. **Safe by construction.** The default `mac-reclaim` only clears caches the owning tool rebuilds on demand — `pnpm`/`uv` prune only *unreferenced* packages; npm's `_cacache` is a re-download cache; installed `node_modules` are never touched. It **cannot** remove something you're using.
3. **Evidence before deletion.** The deep tier and worktree removal require *proof* an item is disposable: workspace state that's orphaned (its project folder is gone) or idle-and-unopened; a worktree whose every commit is reachable from another branch/tag/remote. Anything unproven is **backed up, never deleted.**
4. **Bounded automation.** `diskguard` runs unattended, but only ever the safe tier, and only at a threshold — turning a silent disk-fill into an observable, self-healing event it logs and notifies about.

## Options

**Commands & flags**

| Command | Effect |
|---------|--------|
| `diskreport` | Read-only disk report. |
| `mac-reclaim` | Reclaim safe caches (unattended-safe). |
| `mac-reclaim --deep --dry-run` | Preview deep prune — deletes nothing, prints each candidate + why it's unused. |
| `mac-reclaim --deep` | Deep prune (prompts). Add `--yes` to skip the prompt (automation). |
| `mac-reclaim --quiet` | Summary line only. |
| `worktree-audit [ROOT…]` | Audit stray worktrees (default root `~/workspace`). |
| `worktree-audit --prune` | Remove SAFE worktrees + clear stale registrations. |
| `worktree-audit --backup [--prune]` | Archive REVIEW worktrees to git bundles, then optionally prune the archived ones. |

**Environment variables**

| Var | Default | Meaning |
|-----|---------|---------|
| `KEEP_DAYS` | `30` | Age gate for the deep tier. |
| `KEEP_RECENT` | `5` | Always keep the N newest entries per category. |
| `WARN_GB` | `20` | `diskguard` reclaims + notifies below this. |
| `CRIT_GB` | `10` | `diskguard` posts an urgent notice below this. |
| `WORKTREE_BACKUP_DIR` | `~/.local/share/worktree-backups` | Where worktree bundles land. |

Allowlist paths from deep pruning in `~/.config/mac-reclaim/keep.txt` (one substring per line).

### Why `mac-reclaim --deep` is trustworthy

Age alone is a bad signal (a project you use weekly but not in 30 days shouldn't vanish). `--deep` only removes:

- **VS Code `workspaceStorage`** whose `workspace.json` points to a folder that **no longer exists** (a truly orphaned entry). If the project folder is still there, it's kept regardless of age.
- **`vm_bundles` / agent sessions / `.claude/projects`** that are idle past `KEEP_DAYS`, beyond the newest `KEEP_RECENT`, not currently open (`lsof`), and not matched by `~/.config/mac-reclaim/keep.txt`.

Preview it first — this deletes nothing: `mac-reclaim --deep --dry-run`.

### Backing up REVIEW worktrees (`worktree-audit --backup`)

REVIEW worktrees hold work that exists nowhere else — so you can't safely prune them to reclaim disk. `--backup` fixes that by **archiving them losslessly first**:

```bash
worktree-audit --backup            # list REVIEW worktrees, pick which to archive
worktree-audit --backup --prune    # archive the picked ones, then remove them
worktree-audit --backup --yes      # archive ALL REVIEW worktrees, no prompt
```

Selection accepts indices, ranges (`1-3,5`), or `all`. Each backup is an **incremental git bundle** (only the commits unique to that worktree — small, since the base stays in the surviving repo), verified with `git bundle verify` before it counts. If the worktree is **dirty**, the uncommitted diff and untracked files are captured alongside (`*.uncommitted.patch`, `*.untracked.tar.gz`). A worktree is pruned only if its backup verified.

Backups land in `$WORKTREE_BACKUP_DIR` with a `manifest.tsv` recording each one **and a ready-to-paste restore command**. To restore into the surviving repo:

```bash
git -C <repo> fetch <bundle> 'refs/heads/<branch>:refs/heads/<branch>'
# if it was dirty, in a checkout of that branch:
git apply <stem>.uncommitted.patch
tar xzf <stem>.untracked.tar.gz -C <worktree>
```

## Requirements

macOS (Apple Silicon or Intel). Pure **bash** — no runtime dependencies. Homebrew, `pnpm`, `uv`, `bun`, and `nvm` are all optional: their caches are pruned only if present (each tool is guarded by `command -v`).

## Automation & uninstall

`make install` also installs two launchd agents:

- `com.mac-optimize.diskguard` — at login + every 3 h
- `com.mac-optimize.mac-reclaim` — weekly, Sundays 11:00 (daytime, so the laptop is awake)

The plists are templates; `install.sh` fills in `$HOME` and a cross-arch `PATH` at install time, so nothing is hardcoded to one machine.

**Notification permission (one-time):** the first low-disk banner may require allowing notifications for the invoking process (osascript / Script Editor) under **System Settings → Notifications**. No blocking dialogs are ever used, so a missed banner is cosmetic — the reclaim still runs and is logged to `~/Library/Logs/diskguard.log`.

```bash
make uninstall      # unloads agents, removes deployed scripts; repo left intact
```

## Agent skills

`skills/` ships **agent-agnostic** skills in the open [Agent Skills](https://agentskills.io) format (a `SKILL.md` per folder — no vendor lock-in, no plugin manifest). Any skills-compatible agent (Claude Code, Gemini CLI, Cursor, opencode, Goose, …) can load them so it knows *when and how* to drive these tools.

| Skill | Triggers on |
|-------|-------------|
| **`mac-optimize`** | "clean up my mac", "free up space", low disk, slow machine, "audit git worktrees" — diagnose → safe reclaim → deep dry-run → worktree backup/prune. |
| **`mac-optimize-setup`** | "install mac-optimize", "set up disk automation", fresh-machine setup, Keychain token migration, uninstall. |

**Install the skills into your agent** with the [`skills`](https://github.com/vercel-labs/skills) CLI — no clone required:

```bash
npx skills add kylebrodeur/mac-optimize          # interactive: pick skills + agents
npx skills add kylebrodeur/mac-optimize --list   # list what's available
npx skills add kylebrodeur/mac-optimize --skill mac-optimize -a claude-code -y   # non-interactive
```

Or point your agent directly at `skills/`, or (Claude Code) run `make install-skills` to symlink `skills/*` into `~/.claude/skills/`. Validate against the spec with `skills-ref validate ./skills/mac-optimize`.

## License

MIT © 2026 Kyle Brodeur
