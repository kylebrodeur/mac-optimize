# TESTING — mac-optimize

End-to-end verification on macOS: clone → install → run → maintain → uninstall.

> **Read this first.** This procedure is the durable macOS verification checklist
> for the shared `agent-machine-lib` adoption. Every destructive step is gated
> behind a dry-run whose correctness you assert before proceeding. If a **STOP**
> check fails, stop and report it.

Record results as you go; the last section is a copy-paste template.

---

> **Shell note.** Every tool here runs under `#!/usr/bin/env bash`. If your login
> shell is zsh, run any hand-verification snippet as `bash -c '...'` — zsh does
> **not** word-split unquoted expansions, so an inline zsh re-check of a bash
> script can return the opposite answer with no error. `lib/common.sh` is safe to
> source from either shell; `bin/worktree-audit` uses `${BASH_SOURCE[0]}` and must
> be *executed*, not sourced from zsh.


## 0. Prerequisites

```bash
sw_vers                       # macOS version
bash --version | head -1      # /bin/bash 3.2 is fine — scripts target it
command -v git python3 lsof   # required
command -v pnpm uv bun brew npm   # optional; each is command -v guarded
df -h /System/Volumes/Data | tail -1   # note free space BEFORE anything
```

**STOP if:** `python3` or `lsof` is missing. The deep tier's orphan detection needs
`python3`; `lsof` is the open-file guard. The implementation also fails closed at
runtime: a missing, failing, or diagnostic `lsof` check protects the candidate and
does not treat the check as proof that the path is closed.

Record: macOS version, bash version, free space.

---

## 1. Clone

```bash
git clone https://github.com/kylebrodeur/mac-optimize.git
cd mac-optimize
git log --oneline --grep='agent-machine-lib' -5
```

**Expect:** history includes the `agent-machine-lib` adoption or follow-up vendoring commits.

## 2. Build

There is no build step — pure bash, zero runtime dependencies. Verify instead that
everything parses and that the vendored library is present:

```bash
for f in bin/* install.sh uninstall.sh lib/common.sh; do bash -n "$f" || echo "PARSE FAIL: $f"; done
echo "---"
ls -l lib/common.sh bin/worktree-audit
cat lib/.vendored-from        # the agent-machine-lib commit this was vendored from
make lint                     # shellcheck if installed; skips cleanly if not
```

**STOP if:** anything prints `PARSE FAIL`.

Sanity-check the shared library in isolation before any tool uses it:

```bash
bash -c '. lib/common.sh
  echo "platform: $AM_PLATFORM"          # must be: macos
  am_is_macos && echo "am_is_macos: yes" || echo "am_is_macos: NO — BUG"
  echo "mtime of \$HOME: $(am_mtime "$HOME")"      # a 10-digit unix timestamp, not 0
  echo "idle days \$HOME: $(am_idle_days "$HOME")" # small integer, not empty
  echo "free KiB: $(am_free_kb /)"                 # non-empty integer
'
```

**STOP if:** `AM_PLATFORM` is not `macos`, or `am_mtime` returns `0` for `$HOME`.
`am_mtime` tries GNU `stat -c` first and falls back to BSD `stat -f` — a `0` here
means both failed and every age-based decision downstream is wrong.

Then confirm the previously-GNU-only helper works on BSD tooling:

```bash
bash -c '. lib/common.sh
  mkdir -p /tmp/amtest/{old,new}
  touch -t 202401010000 /tmp/amtest/old       # backdate one entry
  echo "stale (keep 0):"; am_stale_entries /tmp/amtest 30 0
  echo "stale (keep 5):"; am_stale_entries /tmp/amtest 30 5
  rm -rf /tmp/amtest'
```

**Expect:** `keep 0` lists `/tmp/amtest/old`; `keep 5` lists nothing.
**STOP if:** `keep 0` lists nothing — that is the `find -printf` bug this helper was
rewritten to avoid, and it fails *silently*.

## 3. Install

```bash
make install
```

**Expect:** scripts copied to `~/.local/bin`, `lib/common.sh` installed to
`~/.local/lib/mac-optimize/`, and three launchd agents loaded (diskguard, memguard, mac-reclaim).

```bash
make doctor
```

**Expect:** `0 failed`. Then verify the install independently:

```bash
ls -l ~/.local/lib/mac-optimize/common.sh
launchctl list | grep 'com\.mac-optimize\.'
for pl in ~/Library/LaunchAgents/com.mac-optimize.*.plist; do
  plutil -lint "$pl"; grep -c '__HOME__\|__PATH__' "$pl"   # must be 0
done
```

**STOP if:** any plist still contains `__HOME__`/`__PATH__` (the template wasn't
substituted), or `~/.local/lib/mac-optimize/common.sh` is missing.

### 3a. The installed-copy trap

This is the bug that bit `wsl-optimize`: the repo copy worked and the installed copy
silently did nothing, because it couldn't find the library.

```bash
cd /tmp                       # deliberately outside the repo
worktree-audit --help | head -3
worktree-audit | tail -20
```

**STOP if:** you see `cannot find lib/common.sh`, or output is empty where running it
from the repo produced results. Compare directly:

```bash
cd /tmp && worktree-audit | grep -cE 'SAFE|REVIEW'
cd -   && ./bin/worktree-audit | grep -cE 'SAFE|REVIEW'
```

**Expect:** identical counts.

## 4. Run

### 4a. Read-only first

```bash
diskreport
```

**Expect:** free space, top consumers, dev/agent caches, a REVIEW tier, APFS local
snapshots. Deletes nothing. Note the reported free space.

### 4b. Safe tier — dry-run, and assert it frees nothing

The safe tier previously *skipped* itself under `--dry-run`; it now reports intent.
`make install` also loads `diskguard` with `RunAtLoad`; on a low-disk machine that
can start a real safe reclaim concurrently. Wait until `diskguard` is idle before
measuring free-space deltas, or a correct dry-run can appear to free GiB.

```bash
while launchctl list | awk '/com\.mac-optimize\.diskguard/ && $1 != "-" {found=1} END{exit !found}'; do
  echo "waiting for diskguard to finish…"
  sleep 5
done
before=$(df -Pk /System/Volumes/Data | awk 'NR==2{print $4}')
./bin/mac-reclaim --deep --dry-run
after=$(df -Pk /System/Volumes/Data | awk 'NR==2{print $4}')
echo "delta KiB: $((after-before))    # must be ~0"
```

**Expect:** `would:` lines for pnpm/uv/npm/bun/brew, a list of deep candidates each
with a reason, and `delta ≈ 0` (small noise from other processes is fine; hundreds of
MiB is not).

**STOP if:** delta is materially nonzero — especially positive, because increased free
space means something deleted data during what should have been a dry-run.

Also confirm the shared tier actually ran (this is the behaviour change):

**Expect** to see `brew cleanup -s` and `bun pm cache rm` mentioned as `would:`.
**STOP if:** you only see `(dry-run: safe tier skipped)` — the old code path.

### 4c. Safe tier for real

```bash
mac-reclaim
df -h /System/Volumes/Data | tail -1
```

**Expect:** reclaims caches, prints a summary. Nothing you were using breaks.
Re-running immediately should reclaim ≈0 (idempotent).

### 4d. Deep tier

**workspaceStorage safety guard.** Orphaned VS Code
`~/Library/Application Support/Code/User/workspaceStorage` directories are
classified as REVIEW and are never deletion candidates for `mac-reclaim`.
Current live evidence found chat-bearing state in these directories, so cleanup
must be archive-first. Only the manifest/fingerprint primitives shipped in
`bin/vscode-chat-backup`; the full encrypted prune workflow was shelved (archived
design contract: `docs/superpowers/_archive/2026-08-01-vscode-chat-backup-design.md`).
Until it exists, reclaim orphaned workspaceStorage by hand, archive-first: tar each
orphan's `chatSessions/` + `chatEditingSessions/` + `workspace.json`, verify the
archive lists every entry, then delete the orphans — skipping any whose project
folder is on an unmounted `/Volumes/` path, and re-checking the folder is really gone.

First verify the `agent-session-kill` delegation logic with a disposable home so
the check does not scan live agent state:

```bash
(
set -euo pipefail
fake_home=$(mktemp -d /tmp/mac-reclaim-delegation.XXXXXX)
shim=
trap 'rm -rf "$fake_home" "${shim:-}"' EXIT
mkdir -p "$fake_home/.claude/projects"/{old1,old2}
mkdir -p "$fake_home/Library/Application Support/Claude/vm_bundles"/{old1,old2}
mkdir -p "$fake_home/Library/Application Support/Claude/local-agent-mode-sessions"/{old1,old2}
touch -t 202401010000 "$fake_home/.claude/projects"/old*
touch -t 202401010000 "$fake_home/Library/Application Support/Claude/vm_bundles"/old*
touch -t 202401010000 "$fake_home/Library/Application Support/Claude/local-agent-mode-sessions"/old*

# Without agent-session-kill on PATH, .claude/projects is handled locally.
HOME="$fake_home" PATH=/usr/bin:/bin:/usr/sbin:/sbin KEEP_RECENT=0 KEEP_DAYS=0 \
  ./bin/mac-reclaim --deep --dry-run | tee /tmp/mac-reclaim-no-session-kill.txt
grep -qF '~/.claude/projects' /tmp/mac-reclaim-no-session-kill.txt

# With agent-session-kill on PATH, .claude/projects is delegated and not listed,
# while vm_bundles and local-agent-mode-sessions still stay locally handled.
shim=$(mktemp -d /tmp/agent-session-kill.XXXXXX)
printf '#!/bin/sh\nexit 0\n' > "$shim/agent-session-kill"
chmod +x "$shim/agent-session-kill"
HOME="$fake_home" PATH="$shim:/usr/bin:/bin:/usr/sbin:/sbin" KEEP_RECENT=0 KEEP_DAYS=0 \
  ./bin/mac-reclaim --deep --dry-run | tee /tmp/mac-reclaim-with-session-kill.txt
grep -qF 'delegating ~/.claude/projects to agent-session-kill' /tmp/mac-reclaim-with-session-kill.txt
! grep -qF '~/.claude/projects/old' /tmp/mac-reclaim-with-session-kill.txt
grep -qF '~/Library/Application Support/Claude/vm_bundles/old' /tmp/mac-reclaim-with-session-kill.txt
grep -qF '~/Library/Application Support/Claude/local-agent-mode-sessions/old' /tmp/mac-reclaim-with-session-kill.txt
)
```

Then review the live 4b candidate list and agree with every reason:

Only after reviewing 4b's candidate list and agreeing with every reason:

```bash
mac-reclaim --deep          # prompts
```

**Never** run `--deep --yes` before reviewing a dry-run.

### 4e. Worktrees

```bash
worktree-audit                      # audit only
worktree-audit --backup             # archive REVIEW ones (select interactively)
worktree-audit --prune              # remove SAFE ones
```

**Expect:** each worktree classified SAFE (clean *and* every commit reachable from
another ref) or REVIEW. Verify one SAFE classification by hand before pruning:

```bash
# For a repo it called SAFE, replace R and B, then confirm the branch's commits
# exist elsewhere. NOTE: run via bash -c — this relies on bash arrays.
bash -c 'R=/absolute/path/to/repo; B=branch-name
  ex=(); while IFS= read -r r; do ex+=("$r"); done < <(
    git -C "$R" for-each-ref --format="%(refname)" refs/heads refs/tags refs/remotes | grep -vxF "refs/heads/$B")
  git -C "$R" rev-list "refs/heads/$B" --not "${ex[@]}" | wc -l'
```

**Expect:** `0` — no unique commits. **STOP if** non-zero for a SAFE row.

If you use `--backup`, **round-trip one restore** before trusting it:

```bash
ls ~/.local/share/worktree-backups/
cat ~/.local/share/worktree-backups/manifest.tsv     # includes a restore command
git bundle verify ~/.local/share/worktree-backups/<name>.bundle
```

### 4f. Default roots

Root precedence is: positional roots, then `WORKTREE_ROOTS`, then common defaults
(`~/workspace`, `~/projects`, `~/src`, `~/code`). `WORKTREE_ROOTS` constrains the
scan; it must not fall back to defaults when set, even if the path is missing.

```bash
worktree-audit                       # probes common roots
WORKTREE_ROOTS=/tmp/definitely-missing-worktree-root worktree-audit
WORKTREE_ROOTS=/tmp/definitely-missing-worktree-root ./bin/worktree-audit /tmp
```

### 4g. Memory watcher (memguard) and diskguard escalation

`memguard` is the memory analog of `diskguard` — a launchd watcher (login + every
5 min) that reads the kernel memory-pressure level and free-RAM %, names the
largest RAM consumer, and **never kills or deletes**. Force each state via
thresholds so no real pressure is needed:

```bash
memguard; tail -1 ~/Library/Logs/memguard.log                         # logs `ok` at pressure L1, `WARN` at L2 — both correct
FREE_WARN_PCT=100 CRIT_GB=0   memguard; tail -1 ~/Library/Logs/memguard.log   # WARN (RAM in band, disk not aggravating)
FREE_WARN_PCT=100 CRIT_GB=999 memguard; tail -1 ~/Library/Logs/memguard.log   # CRITICAL (disk<->swap coupling)
FREE_CRIT_PCT=100             memguard; tail -1 ~/Library/Logs/memguard.log   # CRITICAL (free-RAM floor)
sysctl kern.memorystatus_vm_pressure_level                            # authoritative signal: 1 normal / 2 warn / 4 crit
```

**Expect:** the plain run's level tracks `kern.memorystatus_vm_pressure_level` — `ok`
at L1, `WARN` at L2 (a memory-tight-but-idle box legitimately sits at L2). Swap is
deliberately NOT a trigger (it sits ~80% whenever swap was ever touched, so it would
false-alarm); it is shown as `used/totalMB`. Forced runs log `WARN`/`CRITICAL` with
the largest process named.
**STOP if:** it logs `CRITICAL` while the kernel reports L1/normal and free RAM is
healthy, or memguard ever kills a process.

**diskguard escalation.** When the safe tier can't restore headroom diskguard names
the biggest disk consumers, flags the safe tier exhausted, points at the deep tools,
and debounces repeat banners. Force the critical path (safe reclaim only — deletes
nothing destructive):

```bash
WARN_GB=9999 CRIT_GB=9999 diskguard; tail -2 ~/Library/Logs/diskguard.log
```

**Expect:** a `CRITICAL:` line naming the top fillers (e.g. workspaceStorage,
vm_bundles) plus `mac-reclaim --deep --dry-run` guidance; `~/Library/Logs/diskguard.log.state`
records the level so the banner is not re-posted every run.

## 5. Maintain

```bash
make doctor          # expect 0 failed
make vendor-lib      # refresh the shared library + worktree-audit
git diff --stat      # shows vendored drift, if any, from the resolved upstream SHA
```

If `vendor-lib` produces a diff, re-run the section 2 library checks before committing.
If a fix belongs in shared code, the order is:

1. Fix and push `agent-machine-lib`.
2. Run `make vendor-lib` in both `mac-optimize` and `wsl-optimize`.
3. Verify each consumer's `lib/.vendored-from` equals the exact 40-character
   `agent-machine-lib` commit SHA that was just pushed.
4. Verify each consumer's vendored `lib/common.sh` and `bin/worktree-audit` bytes
   match that exact upstream commit.
5. Push both consumers so all three repositories stay in step.

**Idempotency** — re-running install must actually re-apply, not no-op:

```bash
make install && make install && make doctor
launchctl list | grep 'com\.mac-optimize\.'
```

**Note the launchd analog of a trap we hit twice on systemd:** `enable --now` there
was satisfied by "already running" and silently ignored a changed unit. `install.sh`
here does `launchctl bootout` then `bootstrap`, which is correct — but verify the
agents are actually reloaded (check their PIDs change) rather than assuming.

Automation: `diskguard` at login + every 3 h, `memguard` at login + every 5 min, `mac-reclaim` weekly Sundays 11:00.

```bash
tail -20 ~/Library/Logs/diskguard.log
tail -20 ~/Library/Logs/memguard.log
tail -20 ~/Library/Logs/mac-reclaim.log
```

**First low-disk banner** may require allowing notifications for `osascript` under
System Settings → Notifications. A missed banner is cosmetic; the reclaim still runs
and logs.

## 6. Uninstall

```bash
make uninstall
```

Then assert zero residue:

```bash
ls ~/.local/bin/{diskreport,mac-reclaim,worktree-audit,diskguard,mac-optimize-doctor} 2>/dev/null | wc -l   # want 0
ls ~/.local/lib/mac-optimize/ 2>/dev/null | wc -l                                                          # want 0
launchctl list | grep -c 'com\.mac-optimize\.'                                                             # want 0
ls ~/Library/LaunchAgents/com.mac-optimize.*.plist 2>/dev/null | wc -l                                     # want 0
```

Preserved on purpose: `~/Library/Logs/*.log`, `~/.config/mac-reclaim/keep.txt`,
and any worktree backups.

## Rollback

Nothing here modifies the system outside `~/.local`, `~/Library/LaunchAgents`, and the
caches it reclaims. To go back to the pre-shared-library version:

```bash
git log --oneline -- lib/common.sh          # find the adoption commit
git revert <commit>                          # or: git checkout <prev> -- bin/ lib/
make install
```

---

## Results template

```
macOS:            
bash:             
free space before:
free space after 4c:

2  parse                 pass / fail:
2  library isolation     AM_PLATFORM=      am_mtime=      am_idle_days=
2  am_stale_entries      keep0 listed old? Y/N   keep5 empty? Y/N
3  make install          pass / fail:
3  make doctor           passed=   failed=
3a installed vs repo     counts match? Y/N
4a diskreport            ran clean? Y/N
4b dry-run delta KiB           (must be ~0)
4b shared tier shown?    Y/N   (brew/bun `would:` lines present)
4c mac-reclaim reclaimed       MiB
4d deep tier             candidates=      accepted=
4e worktree-audit        SAFE=   REVIEW=   hand-verified a SAFE row? Y/N
4e backup round-trip     bundle verify pass? Y/N  (skip if unused)
5  vendor-lib drift      none / diff:
5  install idempotent    Y/N
6  uninstall residue     bins=  lib=  agents=  plists=   (all want 0)

Anything unexpected:
```

Report failures with the exact command and full output in the private session
record; summarize only the sanitized failure and STOP check in public changes.

## Results

Do not commit output from a live workstation to this repository. Record the
machine-specific results, timestamps, process IDs, disk paths, and diagnostic
logs in a private session note instead. The public repository should contain
the procedure and reproducible assertions, not an operator's inventory.

For a release verification snapshot, record only aggregate pass/fail outcomes
and the exact test commands:

```text
make test                         pass/fail
bash test/mac-safemode-test.sh   pass/fail
make doctor                      passed/failed
```

If a check fails, keep the complete output in the private note and report the
failure without copying user paths, hostnames, usernames, tokens, or raw logs
into this repository.

## Safe Mode benchmark workflow

The Safe Mode tool is intentionally interactive and non-destructive:

```bash
mac-safemode prepare
# follow Apple's Startup Options instructions, then:
mac-safemode finish       # while running in Safe Mode
# restart normally, then:
mac-safemode finish       # writes the comparison report
```

The tool persists its state under the user's macOS Application Support
directory, outside `/tmp`, and writes private JSON plus a Markdown comparison
report. It does not change NVRAM or boot policy, kill processes, delete data,
or request a reboot unless `--reboot` is explicitly supplied and confirmed.

## Remaining manual checks

The deep reclaim and worktree operations remain intentionally separate from
this verification procedure. Run their dry-run or audit forms first, inspect
the output, and only then choose an explicit destructive operation. Never
commit live output from those checks.
