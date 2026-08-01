# TESTING — mac-optimize

End-to-end verification on macOS: clone → install → run → maintain → uninstall.

> **Read this first.** This procedure is the durable macOS verification checklist
> for the shared `agent-machine-lib` adoption. The first macOS pass ran on
> 2026-07-31; its results are recorded below. Every destructive step is gated
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
`python3`; `lsof` is the open-file guard, and without it `am_in_use` deliberately
reports "in use" for everything (safe, but the deep tier will find no candidates).

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

## Results — 2026-07-31 macOS verification

```
macOS:            26.5.2 (25F84)
bash:             GNU bash, version 3.2.57(1)-release (arm64-apple-darwin25)
free space before: 17Gi at prerequisite check; 19Gi at diskreport after install-triggered reclaim
free space after 4c: 21Gi

2  parse                 pass
2  library isolation     AM_PLATFORM=macos  am_mtime=1785542320  am_idle_days=0
2  am_stale_entries      keep0 listed old? Y   keep5 empty? Y
3  make install          pass
3  make doctor           passed=9   failed=0
3a installed vs repo     counts match? Y (installed=5 repo=5)
4a diskreport            ran clean? Y
4b dry-run delta KiB     inconclusive under launchd race: +2160348, then +1659184
4b shared tier shown?    Y   brew shown in real env; bun shown with dry-run no-op bun shim
4c mac-reclaim reclaimed 712 MiB; immediate rerun reclaimed 1 MiB
4d deep tier             candidates=123  accepted=0 (skipped pending human review)
4e worktree-audit        SAFE=3   REVIEW=0   hand-verified a SAFE row? Y
4e backup round-trip     bundle verify pass? skipped (no backup flow used)
5  vendor-lib drift      fixed: marker and bytes now match agent-machine-lib@f5a959b0fe635a27ceb402cee3f9595dbae22db7
5  install idempotent    Y (diskguard PID 39726 -> 40441 -> 40482)
6  uninstall residue     bins=0  lib=0  agents=0  plists=0; tools reinstalled afterward

Anything unexpected:
- Found and fixed a shared `WORKTREE_ROOTS` safety bug: env roots were additive with default roots, so an explicit constrained root or nonexistent root could still scan default roots. Fixed in `agent-machine-lib`, added regression coverage for env root, nonexistent env root, and positional-root precedence, then re-vendored `mac-optimize` and `wsl-optimize`.
- The real environment lacks `bun`, so the literal `would: bun pm cache rm` branch was verified with a temporary no-op `bun` shim; dry-run did not invoke the shim.
- `make install` starts `diskguard` with `RunAtLoad`; while disk was below the warning threshold it ran real safe reclaim concurrently with §4b dry-run measurements. TESTING.md now requires waiting for `diskguard` to go idle before delta measurement.
- A later deep dry-run attempt hung in the candidate scan and was killed (`bash ./bin/mac-reclaim --deep --dry-run`, pid 43932). Do not treat §4b delta verification as clean until rerun after `diskguard` is idle and the scan completes.
- `WORKTREE_ROOTS="$HOME/some/other/dir" worktree-audit` previously looked like it worked while still scanning defaults. The fixed behavior now treats `WORKTREE_ROOTS` as the constrained scan root.
- Historical `diskguard.log` tail includes older `rm: ... .npm/_cacache ... Directory not empty` lines from 2026-07-30, before this verification run.
- Operational stability note for gist/writeup: user-observed outcome during this
  macOS run was no significant crash, out-of-memory incident, or Force Quit “apps
  paused” event. Telemetry snapshot at 20:58 covered a machine up for `1 day,
  6:19` since `Thu Jul 30 14:39:11 2026`: `memory_pressure -Q` reported `46%`
  system-wide memory free; `sysctl vm.swapusage` reported `5120.00M` total swap
  with `4721.75M` used; DiagnosticReports files modified in the last six hours
  counted `0` crash/IPS, `0` panic-named, and `0` hang/spin-named reports. A
  six-hour unified-log scan still showed RunningBoard/memorystatus bookkeeping
  messages, and macOS log retention/filtering is not a complete absence proof.
```

### Remaining manual checks from 2026-07-31

The first macOS pass intentionally did not run destructive or interactive cleanup
against Kyle's live state. To finish the remaining review safely:

```bash
(
set -euo pipefail
# 1. Ensure the RunAtLoad diskguard job is idle before measuring a dry-run delta.
while launchctl list | awk '/com\.mac-optimize\.diskguard/ && $1 != "-" {found=1} END{exit !found}'; do
  echo "waiting for diskguard to finish…"
  sleep 5
done

# 2. Re-run the deep dry-run and review every candidate reason.
before=$(df -Pk /System/Volumes/Data | awk 'NR==2{print $4}')
./bin/mac-reclaim --deep --dry-run | tee /tmp/mac-optimize-deep-dry-run.txt
after=$(df -Pk /System/Volumes/Data | awk 'NR==2{print $4}')
echo "delta KiB: $((after-before))    # must be ~0"

# 3. Only after reviewing the dry-run output, run the prompted deep tier.
mac-reclaim --deep

# 4. Worktree cleanup is separate: audit first, verify one SAFE row, then choose.
worktree-audit
worktree-audit --backup     # only if REVIEW rows should be archived
worktree-audit --prune      # only if SAFE rows should be removed
)
```

Do **not** run `mac-reclaim --deep --yes` or `worktree-audit --backup --prune --yes`
on live state unless the dry-run/audit output has already been reviewed.
