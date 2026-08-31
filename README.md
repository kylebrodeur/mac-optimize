# mac-optimize

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform: macOS](https://img.shields.io/badge/platform-macOS-lightgrey.svg?logo=apple)](#requirements)
[![Shell: bash](https://img.shields.io/badge/shell-bash-4EAA25.svg?logo=gnu-bash&logoColor=white)](#)
[![Dependencies: none](https://img.shields.io/badge/deps-none-success.svg)](#requirements)
[![Agent Skills](https://img.shields.io/badge/Agent%20Skills-agentskills.io-8A2BE2.svg)](https://agentskills.io)

> Disk, memory & shell hygiene for a **Mac that runs a lot of AI coding agents** on limited RAM and disk — diagnose, reclaim safely, watch for jetsam-inducing memory pressure, and audit stray git worktrees, without ever deleting work that isn't provably recoverable.

It's a macOS port of a WSL2 optimization writeup. On WSL2 the failure mode was silent OOM — the kernel dismantled the session while protecting the memory hogs. A 16 GB Mac running fleets of agents dies two ways: **disk exhaustion** (package caches, agent runtimes, editor workspace state, and stray git worktrees that grow on every run and never self-reclaim) and, closer to the original, **memory pressure** — a fleet of agents (each a heavy process tree that fans out subagents) exhausts RAM + compressor + swap until the kernel's jetsam killer force-quits whatever app it can reach. This toolkit covers both.

The design goal, borrowed from that writeup, is to **change the shape of the failure**: from "silent and fatal" to "observable and bounded." You get a report you can read, a reclaim that's safe by construction, and a watcher that acts at a threshold and tells you what it did.

## Install

```bash
git clone https://github.com/kylebrodeur/mac-optimize.git
cd mac-optimize
make install          # deploy tools to ~/.local/bin + load the launchd agents
make doctor           # verify the install
```

Pure clone-and-`make` — no tap, no package manager. `install.sh` copies the
tools into `~/.local/bin`, vendors the shared library, and loads the launchd
automation with your per-user paths filled in. Re-running it is safe.

## Quickstart

```bash
git clone https://github.com/kylebrodeur/mac-optimize.git
cd mac-optimize
make install          # deploy tools to ~/.local/bin + load the launchd watcher
make doctor           # verify the install (tools + launchd, and skills if present)

diskreport            # see where your disk went (read-only)
mac-reclaim           # reclaim safe caches now
worktree-audit        # find stray git worktrees
workspace-audit --save  # audit every workspace repo; save private Markdown + JSON reports
mac-safemode prepare  # capture before-state and guide one Safe Mode boot
session-backup backup all  # on-demand Pi/OMP/Claude backups (external drive)
session-backup status all  # show source and manifest status

`~/.local/bin` must be on your `PATH`. Re-running `make install` is safe.

## Tools

| Tool | What it does |
|------|--------------|
| **`diskreport`** | Read-only "where did my disk go?" — top consumers in `Application Support`, `Caches`, and dev/agent caches, plus the big "review-tier" state (VS Code `workspaceStorage`, Claude `vm_bundles`, `.claude/projects`) and recent reclaim history. Deletes nothing. `--scan [PATH]` adds a one-shot [`dust`](https://github.com/bootandy/dust) walk of PATH (default `$HOME`) to catch big single files/dirs the fixed buckets don't look inside — opt-in since it walks the whole tree. For open-ended interactive digging, use [`ncdu`](https://dev.yorhel.nl/ncdu) directly (`brew install ncdu dust`) — navigate, sort, delete in place. |
| **`mac-reclaim`** | Reclaims in two tiers. **Safe tier** (default) clears caches that rebuild on demand (`pnpm store prune`, `uv cache prune`, npm `_cacache`, codex runtimes, `.ShipIt` updaters, stale logs) — safe *by construction*. **`--deep`** prunes idle `vm_bundles`, `local-agent-mode-sessions`, and `.claude/projects` only with *evidence* they're unused, behind `--dry-run`, an allowlist, `lsof` open-file guards, and a keep-newest floor. Orphaned VS Code `workspaceStorage` is reported as REVIEW/protected and never removed until an archive-first backup and explicit verified prune workflow exists. |
| **`worktree-audit`** | *(shared via [`agent-machine-lib`](https://github.com/kylebrodeur/agent-machine-lib) — same copy as `wsl-optimize`)* Finds stray git worktrees and classifies each **SAFE** (clean + every commit reachable from another ref) or **REVIEW** (dirty or has commits that exist nowhere else). `--prune` removes SAFE ones; `--backup` archives REVIEW ones to git bundles so they *become* safe to prune. |
| **`workspace-audit`** | Read-only full-workspace Git audit: recursively discovers repositories, records branch/commit/upstream/dirty/untracked state plus filesystem mtime, separates rebuildable dependency/generated bulk from source, incorporates linked-worktree safety output, and ranks `BACKUP_NOW`, `SYNC_REVIEW`, and `COLD_ARCHIVE` candidates. `--save` writes private Markdown + JSON reports; it never moves, deletes, prunes, fetches, or changes Git state. |
| **`diskguard`** | The launchd watcher (an `earlyoom` analog). At login + every 3 h: below 20 GB free it runs the **safe** reclaim and posts a non-blocking notification; below 10 GB it posts an urgent notice pointing at the manual deep tools. Never runs a destructive prune unattended. |
| **`session-backup`** | On-demand, copy-only backups for Pi (`~/.pi/agent/sessions`), OMP (`~/.omp/agent/sessions` with parent/sidecar units), Claude Code (`~/.claude/projects` plus `file-history`), and Claude Desktop persistent state. It writes private, hash-verified manifests under `mac-optimize-backups/session-backups/<profile>/`, excludes Claude Desktop VM bundles and caches, and never schedules or prunes anything. Use `profiles`, `backup <profile|all>`, `status <profile|all>`, and `verify <profile|all>`. |
| **`memguard`** | The memory analog of `diskguard` (the real `earlyoom` port). A launchd watcher at login + every 5 min: it reads the kernel's own memory-pressure level (`kern.memorystatus_vm_pressure_level`) and free-RAM %, and at the warn/critical thresholds posts a non-blocking notification **naming the largest RAM consumer** so you can act before jetsam picks the victim. **Never kills a process or deletes app state.** In the disk↔swap coupling quadrant (RAM tight *and* disk too low for swap to grow — the state that force-panicked one of these machines via a `watchdogd` timeout) it now also auto-triggers `mac-reclaim`'s SAFE tier immediately (same rebuildable-cache-only tier `diskguard` already runs on its own schedule, just sooner) and nags every cycle instead of every 30 min until the coupling clears. |
| **`codex-backup`** | Backs up, indexes, prunes, and restores `~/.codex/sessions` — the large single-copy JSONL logs Codex writes per run (10 GB+ is normal). `backup` rsyncs them to an external drive **cumulatively** (never `--delete`), so a later prune frees local space while the backup keeps everything. `index` inventories every session by age bucket (45+/30-45/15-30/<15 days idle), size, project (`cwd`), and backup status. `prune --older-than N` deletes local sessions idle ≥ N days **only when verified present in the backup** — dry-run by default, keeps the N newest, and never touches anything not backed up. `restore` copies sessions back by date/uuid/project/all and never clobbers a newer local file. `verify` reports drift. Resolves the drive from `--dest`, `$CODEX_BACKUP_DEST`, `~/.config/mac-optimize/codex-backup.conf`, or the first mounted volume with a `mac-optimize-backups/` folder; a weekly launchd agent runs `backup --quiet` and no-ops when the drive is absent. |
| **`mac-safemode`** | Guided, evidence-first Safe Mode benchmark for macOS. `prepare` captures disk, APFS, memory, swap, monitored-process, and home-root state, persists it outside `/tmp`, and prints Apple's supported Apple silicon Startup Options steps. After the user boots Safe Mode, `finish` captures the Safe Mode state; after a normal reboot, a second `finish` writes a Markdown before/Safe Mode/normal comparison report. It never changes NVRAM or boot policy, kills processes, deletes data, or reboots without explicit `--reboot` confirmation. |
| **`diskhealth`** | Read-only SMART + filesystem health for the SSDs in the Mac. Wraps `smartctl` (smartmontools) to report overall health, temperature, available spare, wear (percentage used), media errors, and — the one that catches external drives — the **power-cycle/unsafe-shutdown pattern** (a drive power-cycling ~10×/hour or with hundreds of unsafe shutdowns is being yanked from power, not failing). `--verify` adds a read-only `diskutil verifyVolume` on mounted volumes. Requires `brew install smartmontools`. |
| **`mac-optimize-doctor`** | Read-only health check (`make doctor`): confirms the tools are on PATH and the launchd agents are loaded + valid, and points you at `npx skills list` for an agent-agnostic skills check. Never downloads or executes remote code. Exits non-zero on any failure. |

## How it works

Four principles, in order of trust:

1. **Observable before action.** `diskreport` answers "what's using my disk" without touching anything. Diagnose first.
2. **Safe by construction.** The default `mac-reclaim` only clears caches the owning tool rebuilds on demand — `pnpm`/`uv` prune only *unreferenced* packages; npm's `_cacache` is a re-download cache; installed `node_modules` are never touched. It **cannot** remove something you're using.
3. **Evidence before deletion.** The deep tier and worktree removal require *proof* an item is disposable: idle `vm_bundles`, `local-agent-mode-sessions`, and `.claude/projects`; a worktree whose every commit is reachable from another branch/tag/remote. Orphaned VS Code `workspaceStorage` is reported as REVIEW/protected and is **never removed** until an archive-first backup and explicit verified prune workflow exists. Anything unproven is **protected, never deleted.**
4. **Bounded automation.** `diskguard` runs unattended, but only ever the safe tier, and only at a threshold — turning a silent disk-fill into an observable, self-healing event it logs and notifies about. `memguard` is the memory counterpart: it watches the kernel's pressure level and warns early (naming the offender), and never kills a process or deletes app state — but it will run the same bounded safe tier `diskguard` uses, immediately, the moment disk is what's stopping swap from growing. That one lever was already proven safe elsewhere in this repo; the only thing that changed is *when* it fires.

## Options

**Commands & flags**

| Command | Effect |
|---------|--------|
| `mac-safemode prepare` | Capture a baseline and print the supported Apple silicon Safe Mode steps; no reboot is requested. |
| `mac-safemode prepare --reboot` | After explicit confirmation (`REBOOT`, or `--yes`), request a restart; the user still selects Safe Mode in Startup Options. |
| `mac-safemode finish` | Capture the current boot phase; run once in Safe Mode, then once after a normal restart to save the comparison report. |
| `diskreport --scan [PATH]` | + one-shot `dust` walk of PATH (default `$HOME`) for big single files/dirs the fixed buckets miss. Requires `dust`. |
| `mac-reclaim` | Reclaim safe caches (unattended-safe). |
| `mac-reclaim --deep --dry-run` | Preview deep prune — deletes nothing, prints each candidate + why it's unused. |
| `mac-reclaim --deep` | Deep prune (prompts). Add `--yes` to skip the prompt (automation). |
| `mac-reclaim --quiet` | Summary line only. |
| `worktree-audit [ROOT…]` | Audit stray worktrees. Precedence: positional `ROOT…`, else `$WORKTREE_ROOTS`, else common roots (`~/workspace`, `~/projects`, `~/src`, `~/code`). |
| `worktree-audit --prune` | Remove SAFE worktrees + clear stale registrations. |
| `worktree-audit --backup [--prune]` | Archive REVIEW worktrees to git bundles, then optionally prune the archived ones. |
| `workspace-audit [ROOT] --save` | Audit every Git repository under ROOT (default `$WORKSPACE_AUDIT_ROOT` or `~/workspace`) and save private Markdown + JSON reports. Add `--format json` for machine-readable stdout. |

**Environment variables**

| Var | Default | Meaning |
|-----|---------|---------|
| `KEEP_DAYS` | `30` | Age gate for the deep tier. |
| `KEEP_RECENT` | `5` | Always keep the N newest entries per category. |
| `WARN_GB` | `20` | `diskguard` reclaims + notifies below this. |
| `CRIT_GB` | `15` | `diskguard` posts an urgent notice below this; `memguard` uses it as the disk floor for its coupling alert. |
| `FREE_WARN_PCT` | `15` | `memguard` warns when free memory is at/below this %. |
| `FREE_CRIT_PCT` | `5` | `memguard` posts an urgent (jetsam-imminent) notice at/below this %. |
| `NOTIFY_COOLDOWN` | `1800` | `memguard` seconds between repeat same-level banners. |
| `COUPLING_NOTIFY_COOLDOWN` | `300` | `memguard` seconds between repeat banners *while the disk↔swap coupling note is active* — tighter than `NOTIFY_COOLDOWN` on purpose. |
| `RECLAIM_COOLDOWN` | `900` | `memguard` minimum seconds between its own auto-triggered safe reclaims in the coupling quadrant. `0` disables auto-reclaim (notify-only, prior behavior). |
| `WORKTREE_BACKUP_DIR` | `~/.local/share/worktree-backups` | Where worktree bundles land. |
| `WORKTREE_ROOTS` | unset | Constrain `worktree-audit` when no positional roots are passed. If set, defaults are not scanned; a nonexistent path yields no repos instead of falling back. |
| `WORKSPACE_AUDIT_ROOT` | unset | Default root for `workspace-audit` when no positional root is passed. |
| `WORKSPACE_AUDIT_DIR` | `~/Library/Application Support/mac-optimize/private/audits` | Private directory for saved workspace audit reports. |
| `WORKTREE_AUDIT_BIN` | auto-detected | Optional path to the read-only linked-worktree audit engine. |

Allowlist paths from deep pruning in `~/.config/mac-reclaim/keep.txt` (one substring per line).

### Why `mac-reclaim --deep` is trustworthy

Age alone is a bad signal (a project you use weekly but not in 30 days shouldn't vanish). `--deep` handles state as follows:

- **VS Code `workspaceStorage`** whose `workspace.json` points to a folder that **no longer exists** is reported as **REVIEW/protected**; `mac-reclaim` never removes it until an archive-first backup and explicit verified prune workflow exists. If the project folder is still there, it's kept regardless of age.
- The only items `--deep` removes are **`vm_bundles` / `local-agent-mode-sessions` / `.claude/projects`** that are idle past `KEEP_DAYS`, beyond the newest `KEEP_RECENT`, not currently open (`lsof`), and not matched by `~/.config/mac-reclaim/keep.txt`.

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

## Related tools

These solve adjacent problems well; this repo defers to them rather than shipping weaker copies.

| Tool | Why |
|---|---|
| [`wsl-optimize`](https://github.com/kylebrodeur/wsl-optimize) | The WSL2 sibling. On WSL the silent killer is memory (the OOM killer reaps session plumbing while protecting the hogs) *plus* a virtual disk that only grows. Shares `worktree-audit` and `lib/common.sh` with this repo. |
| [`agent-machine-lib`](https://github.com/kylebrodeur/agent-machine-lib) | The shared bash primitives both repos vendor: platform detection, deletion guards, and the safe-tier cache reclaim. Refresh with `make vendor-lib`. |
| [`agent-session-kill`](https://github.com/kylebrodeur/agent-session-kill) | Agent transcript cleanup done properly: trash-first deletion, protection lists for auth/settings/skills/memory, and coverage of Pi/OMP/Copilot Chat. `mac-reclaim --deep` **delegates `~/.claude/projects` to it when installed** and only falls back to its own pruning otherwise. |
## Requirements

macOS (Apple Silicon or Intel). The suite is **bash-first with zero runtime dependencies**; the safe-tier cache reclaim and `worktree-audit` come from [`agent-machine-lib`](https://github.com/kylebrodeur/agent-machine-lib), vendored into `lib/` and `bin/` (not a submodule, so the zero-dependency promise holds). Three tools — `codex-backup`, `session-backup`, and `vscode-chat-backup` — are **Python 3** (standard library only, already on macOS). `codex-backup` uses `rsync` and prefers Homebrew's `rsync` 3.x when present, falling back to the system `openrsync`; `session-backup` uses atomic standard-library copies and SHA-256 manifests. Homebrew, `pnpm`, `uv`, `bun`, and `nvm` are all optional: their caches are pruned only if present (each guarded by `command -v`). `ncdu`/`dust` (`brew install ncdu dust`) are optional too — `diskreport --scan` and ad hoc interactive digging degrade to a hint if they're missing.

`mac-safemode` also uses only Python 3 standard-library modules. It is a guided diagnostic: it records evidence and prints the supported Startup Options flow, but never changes boot policy or performs cleanup.

`workspace-audit` also uses only Python 3 standard-library modules (plus Git and
the macOS `du` utility for repository metadata and size measurements).

## Automation & uninstall

`make install` installs the tools and the four existing launchd agents. `session-backup` is intentionally **not** a launchd service: run it only when requested.

- `session-backup backup all` — copy all available profiles
- `session-backup status all` — show source counts and manifest presence
- `session-backup verify all` — hash-check local sources against the external copies

The plists are templates; `install.sh` fills in `$HOME` and a cross-arch `PATH` at install time, so nothing is hardcoded to one machine.

- `com.mac-optimize.diskguard` — at login + every 3 h
- `com.mac-optimize.memguard` — at login + every 5 min
- `com.mac-optimize.mac-reclaim` — weekly, Sundays 11:00 (daytime, so the laptop is awake)
- `com.mac-optimize.codex-backup` — weekly, Sundays 11:30 (`codex-backup backup --quiet`; no-ops when the external drive isn't mounted, never deletes)

**Notification permission (one-time):** the first low-disk or low-memory banner may require allowing notifications for the invoking process (osascript / Script Editor) under **System Settings → Notifications**. No blocking dialogs are ever used, so a missed banner is cosmetic — the guard still runs and logs to `~/Library/Logs/diskguard.log` / `~/Library/Logs/memguard.log`.


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

## Testing

Full clone → install → run → maintain → uninstall verification, with assertions and STOP checks at each step: **[TESTING.md](TESTING.md)**.

## License

MIT © 2026 Kyle Brodeur
