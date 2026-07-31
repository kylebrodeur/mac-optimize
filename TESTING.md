# TESTING — mac-optimize

End-to-end verification on macOS: clone → install → run → maintain → uninstall.

> **Read this first.** As of the `agent-machine-lib` adoption commit, this repo's
> shared code has been **statically verified only** (parses, loads, platform-detects)
> — it has not been *run* on macOS. This document is the first-run verification.
> Every destructive step is gated behind a dry-run whose correctness you assert
> before proceeding. If a **STOP** check fails, stop and report it.

Record results as you go; the last section is a copy-paste template.

---

## 0. Prerequisites

```bash
sw_vers                       # macOS version
bash --version | head -1      # /bin/bash 3.2 is fine — scripts target it
command -v git python3 lsof   # required
command -v pnpm uv bun brew npm   # optional; each is command -v guarded
df -h /System/Volumes/Data | tail -1   # note free space BEFORE anything
```

**STOP if:** `python3` or `lsof` is missing. The deep tier's orphan detection needs
`python3`; `lsof` is the open-file guard, and without it `am_in_use` deliberately
reports "in use" for everything (safe, but the deep tier will find no candidates).

Record: macOS version, bash version, free space.

---

## 1. Clone

```bash
git clone https://github.com/kylebrodeur/mac-optimize.git
cd mac-optimize
git log --oneline -3
```

**Expect:** the top commit mentions adopting `agent-machine-lib`.

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
`~/.local/lib/mac-optimize/`, and two launchd agents loaded.

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

```bash
before=$(df -Pk /System/Volumes/Data | awk 'NR==2{print $4}')
./bin/mac-reclaim --deep --dry-run
after=$(df -Pk /System/Volumes/Data | awk 'NR==2{print $4}')
echo "delta KiB: $((after-before))    # must be ~0"
```

**Expect:** `would:` lines for pnpm/uv/npm/bun/brew, a list of deep candidates each
with a reason, and `delta ≈ 0` (small noise from other processes is fine; hundreds of
MiB is not).

**STOP if:** delta is materially negative — a dry-run deleted something.

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
# for a repo it called SAFE, confirm the branch's commits exist elsewhere
git -C <repo> log --oneline <branch> --not $(git -C <repo> for-each-ref --format='%(refname)' refs/heads refs/tags refs/remotes | grep -vxF refs/heads/<branch>) | wc -l
```

**Expect:** `0` — no unique commits. **STOP if** non-zero for a SAFE row.

If you use `--backup`, **round-trip one restore** before trusting it:

```bash
ls ~/.local/share/worktree-backups/
cat ~/.local/share/worktree-backups/manifest.tsv     # includes a restore command
git bundle verify ~/.local/share/worktree-backups/<name>.bundle
```

### 4f. Default roots

`worktree-audit` now probes `~/workspace`, `~/projects`, `~/src`, `~/code` instead of
assuming `~/workspace`.

```bash
worktree-audit                       # should find repos wherever yours actually live
WORKTREE_ROOTS=~/some/other/dir worktree-audit
```

## 5. Maintain

```bash
make doctor          # expect 0 failed
make vendor-lib      # refresh the shared library + worktree-audit
git diff --stat      # shows drift, if any, from agent-machine-lib@main
```

If `vendor-lib` produces a diff, re-run the section 2 library checks before committing.

**Idempotency** — re-running install must actually re-apply, not no-op:

```bash
make install && make install && make doctor
launchctl list | grep 'com\.mac-optimize\.'
```

**Note the launchd analog of a trap we hit twice on systemd:** `enable --now` there
was satisfied by "already running" and silently ignored a changed unit. `install.sh`
here does `launchctl bootout` then `bootstrap`, which is correct — but verify the
agents are actually reloaded (check their PIDs change) rather than assuming.

Automation: `diskguard` at login + every 3 h, `mac-reclaim` weekly Sundays 11:00.

```bash
tail -20 ~/Library/Logs/diskguard.log
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

Report failures with the exact command, its full output, and which STOP check tripped.
