---
name: mac-optimize-setup
description: Install and configure the mac-optimize disk and shell hygiene toolset on a macOS machine, including the launchd automation (a low-disk watcher, a memory-pressure watcher, and a weekly reclaim) and optionally moving a 1Password service-account token out of a cleartext dotfile into the login Keychain. Use when setting up a new Mac, when the user says "install mac-optimize", "set up disk automation", or "set up the disk cleanup tools", or when uninstalling them.
compatibility: Requires macOS, git, and a checkout of the mac-optimize repo. Homebrew, pnpm, uv, and nvm are optional (their caches are only pruned if present).
license: MIT
metadata:
  author: kylebrodeur
  version: "1.0"
---

# mac-optimize-setup

Install the mac-optimize tooling (`diskreport`, `mac-reclaim`, `worktree-audit`, `diskguard`, `memguard`) and its launchd automation onto a Mac.

## Install

From a checkout of the repo:

```
git pull            # if already cloned
make install
```

`install.sh` is idempotent. It copies `bin/*` to `~/.local/bin` (make sure that's on `PATH`), installs the three launchd plists to `~/Library/LaunchAgents`, and (re)loads them.

## Verify

```
launchctl list | grep mac-optimize    # expect com.mac-optimize.diskguard, .memguard, and .mac-reclaim
diskreport                            # confirm the tools resolve on PATH
```

`diskguard` runs at login and every 3 hours; if free space drops below 20 GB it runs a safe reclaim and posts a notification (urgent notice, no auto-delete, below 10 GB). `memguard` runs at login and every 5 minutes; it watches the kernel memory-pressure level and free RAM and, when memory is tight, posts a notification naming the largest process (it never kills or deletes anything). `mac-reclaim` runs a safe reclaim weekly.

**One-time macOS permission:** the first low-disk notification may need Notification Center permission for `osascript`/Script Editor (System Settings → Notifications). The reclaim still runs regardless; only the banner is gated.

## Optional: secure a 1Password service-account token

If a `OP_SERVICE_ACCOUNT_TOKEN` is exported in cleartext in a shell dotfile, move it into the login Keychain (never print the value):

```
# store (from a shell where the token is currently set)
security add-generic-password -a "$USER" -s op-service-account-token \
  -w "$OP_SERVICE_ACCOUNT_TOKEN" -T /usr/bin/security -U

# verify it authenticates, then replace the dotfile line with:
export OP_SERVICE_ACCOUNT_TOKEN="$(security find-generic-password -a "$USER" -s op-service-account-token -w 2>/dev/null)"
```

The `-T /usr/bin/security` grant lets the shell read it at startup without a prompt. Confirm with `op whoami` before removing the cleartext.

## Uninstall

```
make uninstall      # bootout the launchd agents, remove plists + deployed scripts
```

The repo (source of truth) is left intact.

## Using the skills with any agent

The skills in this repo's `skills/` directory follow the open [Agent Skills](https://agentskills.io) format (`SKILL.md` per folder). Point any skills-compatible agent at them, or for Claude Code symlink each folder into `~/.claude/skills/`. Validate with `skills-ref validate ./skills/<name>`.
