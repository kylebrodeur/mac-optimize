# Agent handoff — verify the agent-machine-lib adoption on macOS

**Audience:** an AI coding agent running on Kyle's Mac.
**Written by:** an agent working on the WSL2 side, which could not run macOS code.
**Delete this file once the remaining manual deep-tier review lands.** It documents
a temporary state.

---

## 1. Why you exist

`mac-optimize` originally contained the code that was extracted into
[`agent-machine-lib`](https://github.com/kylebrodeur/agent-machine-lib). That
shared copy was then **fixed** — so for a while this repo held the older, buggier
versions of code it had donated. The adoption commit closed that inversion.

That WSL2 work has now been exercised on macOS. See `TESTING.md`'s
“Results — 2026-07-31 macOS verification” section for command-level results.
The macOS run found and fixed a shared `WORKTREE_ROOTS` safety bug in
`agent-machine-lib`, re-vendored the fix into both `mac-optimize` and
`wsl-optimize`, and reinstalled the fixed macOS tools.

Remaining work: rerun §4b once `diskguard` is idle and the deep candidate scan
completes, then have Kyle review the §4d deep-tier candidates before any real
deep deletion. The destructive/interactive §4d and §4e prune/backup flows were
intentionally skipped; do not treat them as passed.

## 2. What changed, precisely

| Change | Risk |
|---|---|
| `lib/common.sh` vendored from `agent-machine-lib` | new file; nothing depended on it before |
| `bin/worktree-audit` **replaced** by the shared copy | behaviour change — see §4 |
| `mac-reclaim` safe tier → `am_reclaim_caches` | behaviour change — see §4 |
| `mac-reclaim --deep` delegates `~/.claude/projects` to `agent-session-kill` | only when that tool is installed |
| `install.sh` deploys the lib to `~/.local/lib/mac-optimize/` | resolver depends on this exact path |
| `uninstall.sh` removes it; `make vendor-lib` refreshes both vendored files | — |

Everything macOS-only was left untouched: `.ShipIt` scrub, `codex-runtimes`,
VS Code caches, `~/Library/Logs/*`, `_cacache`, `vm_bundles`,
`local-agent-mode-sessions`, the `workspaceStorage` orphan logic, APFS snapshot
reporting, `diskguard`, `diskreport`.

## 3. Run the tests first

**[TESTING.md](TESTING.md)** is the procedure — do not improvise. It has explicit
expected values and STOP conditions. Fill in its results template as you go.

Highest-value checks, in order:

1. **§2 library-in-isolation.** `AM_PLATFORM` must be `macos` and
   `am_mtime "$HOME"` must not be `0`. A `0` means *both* `stat` forms failed and
   every age-based decision downstream is silently wrong.
2. **§2 `am_stale_entries` backdated-file test.** It was rewritten to avoid
   `find -printf` (GNU-only, returns *nothing* on macOS — a silent wrong answer).
   If `keep 0` lists nothing, the rewrite is broken.
3. **§4b safe-tier dry-run.** You should see `would: brew cleanup -s` and
   `would: bun pm cache rm`. If you instead see `(dry-run: safe tier skipped)`,
   the shared tier is not wired in and everything after is suspect.
4. **§3a installed-vs-repo.** Run `worktree-audit` from `/tmp` and from the repo;
   counts must match. This exact bug shipped on the WSL side: the repo copy worked
   and the installed copy classified **zero** entries with no error, because the
   library resolver didn't match the install path.

## 4. Review these specifically

Things I changed or suspect, that static analysis can't settle:

**a. `am_mtime` fallback order.** It tries GNU `stat -c %Y` *first*, then BSD
`stat -f %m`. On macOS the first call fails (stderr suppressed) and the second
succeeds. Confirm there's no visible stderr leakage and no measurable slowdown in
loops — `worktree-audit` and `am_stale_entries` call it per entry.

**b. `find -maxdepth`/`-mindepth` in `am_stale_entries`.** macOS `find` supports
both, but confirm the ordering doesn't warn. BSD `find` is stricter about option
placement than GNU.

**c. bash 3.2.** macOS ships `/bin/bash` 3.2.57. I checked for `mapfile`,
`readarray`, `declare -A`, `${x,,}`, `${x^^}`, `coproc` — **none present** in
`lib/common.sh`, `worktree-audit`, or `mac-reclaim`. But the shebang is
`#!/usr/bin/env bash`, so which bash actually runs depends on PATH. Verify under
**3.2 specifically**, not just brew's bash 5:

```bash
/bin/bash --version | head -1
/bin/bash -n bin/mac-reclaim bin/worktree-audit lib/common.sh
/bin/bash -c '. lib/common.sh; echo "$AM_PLATFORM"; am_mtime "$HOME"'
```

**d. The `_cacache` double-clean.** The shared tier runs `npm cache verify`; the
macOS tail *also* scrubs `~/.npm/_cacache`. Harmless (it's a re-download cache)
and deliberate — the scrub reclaims more. Confirm no error output from doing both.

**e. `bun pm cache rm`.** I changed the shared helper from
`rm -rf ~/.bun/install/cache` to `bun pm cache rm`, because `mac-reclaim` was
already doing it correctly and the extraction had regressed it. Confirm it works
and doesn't prompt.

**f. Delegation logic.** With `agent-session-kill` installed, `--deep` should
print that it's delegating `~/.claude/projects` and should **not** list candidates
from that directory — while still listing `vm_bundles` /
`local-agent-mode-sessions` candidates. Test both with and without the tool on
PATH.

**g. launchd reload.** `install.sh` does `bootout` then `bootstrap`, which is
correct. But the systemd equivalent (`enable --now`) silently failed to apply a
changed unit **twice** during this work. Verify a re-run actually reloads — check
the agents' PIDs change:

```bash
launchctl list | grep 'com\.mac-optimize\.'
make install
launchctl list | grep 'com\.mac-optimize\.'   # PIDs should differ
```

## 4.5 Shells — Kyle's login shell is zsh, the scripts are bash

This is the single most likely way you will reach a **plausible wrong answer**.

The tools all carry `#!/usr/bin/env bash`, so they run under bash regardless of
the login shell. The hazard is *your spot-checks*: if you re-run a snippet from a
script inline in zsh, you may get the opposite result.

**zsh does not word-split unquoted parameter expansions.** bash does:

```bash
bash -c 'x="a b c"; set -- $x; echo "$# args"'   # 3 args
zsh  -c 'x="a b c"; set -- $x; echo "$# args"'   # 1 arg
```

`worktree-audit` used to rely on that splitting for
`git rev-list "$ref" --not $exclude`. In zsh the whole newline-separated ref list
arrives as ONE argument, git errors, prints nothing to stdout, and `wc -l` reports
`0` — which the script reads as "no unique commits", i.e. **safe to delete**. This
exact trap is documented in the macOS writeup as the bug that cost the most time.

It has now been rewritten to build an array, so it behaves identically in both
shells. But when verifying anything by hand:

- **Run spot-checks in the same shell as the script**: `bash -c '...'`, not inline zsh.
- If you must use zsh, split explicitly: `${(f)var}` for newlines, or use an array.
- `${BASH_SOURCE[0]}` (used by the library resolver in `bin/worktree-audit`) does
  not exist in zsh. Executing the script is fine; *sourcing* it from zsh is not.
- `lib/common.sh` itself is zsh-safe and can be sourced from either shell —
  verified.

Also check under macOS's system bash, not just brew's:

```bash
/bin/bash --version | head -1     # 3.2.57 on macOS
/bin/bash -n bin/*.sh bin/* lib/common.sh
```

## 5. Traps that cost real time on the WSL side

- **A patch can parse, run clean, and change nothing.** A fix of mine used
  `candidates.push()` in a function whose branches `return` directly — dead code
  that looked successful. **Assert on output, never on exit status alone.**
- **Verify the effect, not the intent.** Three separate bugs were "config that
  looked applied but wasn't": `enable --now` not restarting, `Persistent=true`
  being a no-op on a monotonic timer, and a `sed` whose `$` was a literal not an
  anchor. Read state back from `ps`/`list-timers`/a diff — not from the file you
  just wrote.
- **Test the installed artifact, not the working copy.** See §3.4.
- **Dry-run means dry.** Assert free space is unchanged; don't trust the output.

## 6. Authority and constraints

**You may:** edit this repo, run the test procedure, fix what breaks, commit and
push to `main`, and push fixes to `agent-machine-lib` if the bug is in the shared
code (then `make vendor-lib` here and in `wsl-optimize`).

**Do not:**
- Mass-edit Kyle's other repos. He declined that explicitly.
- Reinstate a global `npm`→`pnpm` shell wrapper. It was removed deliberately —
  see `~/.config/pm-pin/NOTES.md` on that machine. Per-repo `packageManager` +
  `only-allow` is the chosen approach; `pm-pin` is the helper.
- Merge `agent-session-kill` (Node/TS, cross-platform) or `wsl-gpu-guard` (Python,
  WSL-only) into these repos. Delegation and detection are the intended coupling.
- Duplicate `worktree-audit` back into this repo. If it needs changing, change it
  in `agent-machine-lib` and re-vendor to both consumers.
- Run `mac-reclaim --deep --yes` before a human has reviewed a dry-run.

**If a fix belongs in shared code**, the order is: fix `agent-machine-lib` → push
→ `make vendor-lib` in *both* `mac-optimize` and `wsl-optimize` → push both. All
three must stay in step; `lib/.vendored-from` records the source commit.

## 7. Report back

Fill in TESTING.md's results template. For each failure include the exact
command, full output, and which STOP check tripped. Also state plainly:

- Did §4b show the shared tier, or the old "safe tier skipped" path?
- Does `worktree-audit` behave identically installed vs. from the repo?
- Anything that worked but looked wrong.

If everything passes, say so and **delete this file** in the same commit.

## 8. Context

- Companion repo: [`wsl-optimize`](https://github.com/kylebrodeur/wsl-optimize) — same
  structure, WSL2 failure modes (OOM + a virtual disk that only grows).
- Shared code: [`agent-machine-lib`](https://github.com/kylebrodeur/agent-machine-lib).
- Design writeups: [macOS disk](https://gist.github.com/kylebrodeur/b61cea0434f8995e03a9277f4f33ac3f),
  [WSL2 OOM forensics](https://gist.github.com/kylebrodeur/68059cbfdc0f4b1d9d483fe466e4de1b),
  [wsl-optimize build gotchas](https://gist.github.com/kylebrodeur/45d45e7c7848e001b7b94bbaf1a19cbb).
