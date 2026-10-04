#!/usr/bin/env bash
# agent-machine-lib/common.sh — shared primitives for machine-hygiene tooling on
# boxes that run fleets of AI coding agents.
#
# Sourced by mac-optimize and wsl-optimize. Everything here is either genuinely
# platform-independent (package-manager caches are identical on both) or
# dispatches on AM_PLATFORM. Nothing in this file deletes anything on its own.
#
# Usage:  . "$(dirname "$0")/../lib/common.sh"
#
# Contract: define AM_TOOL before sourcing to name the calling tool in output.

# Guard against double-sourcing.
[ -n "${AM_COMMON_SH:-}" ] && return 0
AM_COMMON_SH=1

AM_TOOL="${AM_TOOL:-$(basename "${0:-tool}")}"

# ── platform ─────────────────────────────────────────────────────────────────
# AM_PLATFORM: macos | wsl2 | linux
am_detect_platform() {
  case "$(uname -s)" in
    Darwin) AM_PLATFORM=macos ;;
    Linux)
      # WSL2 advertises itself in the kernel release string. /proc/version is
      # checked too because some custom kernels drop the uname suffix.
      if grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease /proc/version 2>/dev/null; then
        AM_PLATFORM=wsl2
      else
        AM_PLATFORM=linux
      fi ;;
    *) AM_PLATFORM=unknown ;;
  esac
  export AM_PLATFORM
}
[ -n "${AM_PLATFORM:-}" ] || am_detect_platform

am_is_macos(){ [ "$AM_PLATFORM" = macos ]; }
am_is_wsl(){   [ "$AM_PLATFORM" = wsl2 ]; }

# ── output ───────────────────────────────────────────────────────────────────
# Colour only when stdout is a terminal, so piped/logged output stays clean.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  AM_C_OK=$'\033[32m'; AM_C_NO=$'\033[31m'; AM_C_WARN=$'\033[33m'
  AM_C_DIM=$'\033[2m'; AM_C_B=$'\033[1m';   AM_C_0=$'\033[0m'
else
  AM_C_OK=""; AM_C_NO=""; AM_C_WARN=""; AM_C_DIM=""; AM_C_B=""; AM_C_0=""
fi

am_hdr(){  printf "\n%s%s%s\n" "$AM_C_B" "$1" "$AM_C_0"; }
am_ok(){   printf "  %s✓%s %s\n" "$AM_C_OK" "$AM_C_0" "$1"; }
am_no(){   printf "  %s✗%s %s\n" "$AM_C_NO" "$AM_C_0" "$1"; }
am_warn(){ printf "  %s!%s %s\n" "$AM_C_WARN" "$AM_C_0" "$1"; }
am_info(){ printf "  %s·%s %s\n" "$AM_C_DIM" "$AM_C_0" "$1"; }
am_dim(){  printf "  %s%s%s\n" "$AM_C_DIM" "$1" "$AM_C_0"; }
am_row(){  printf "  %-34s %s\n" "$1" "$2"; }
am_act(){  printf "  %s→%s %s\n" "$AM_C_OK" "$AM_C_0" "$1"; }

# ── sizes ────────────────────────────────────────────────────────────────────
am_du_kb(){ du -sk "$1" 2>/dev/null | cut -f1; }          # KiB, 0 if missing

# Modification time as a unix timestamp. BSD (macOS) and GNU stat take different
# flags for this and neither accepts the other's, so try both. Prints 0 if the
# path is missing, so arithmetic on the result never breaks.
am_mtime(){
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0
}

# Days since $1 was modified. 0 if unknown.
am_idle_days(){
  local m; m=$(am_mtime "$1")
  [ "${m:-0}" -gt 0 ] || { echo 0; return; }
  echo $(( ( $(date +%s) - m ) / 86400 ))
}
am_mib(){   printf '%d' $(( ${1:-0} / 1024 )); }

# Free space on the filesystem holding $1 (default /), in KiB. -Pk is the
# POSIX form; BSD and GNU df disagree on everything else.
am_free_kb(){ df -Pk "${1:-/}" 2>/dev/null | awk 'NR==2{print $4}'; }

# ── guards ───────────────────────────────────────────────────────────────────
# True if any process is using $1. Two independent detectors, because neither is
# sufficient alone:
#   * `lsof +D` catches open files, but MISSES a running browser: measured 14
#     live Chrome processes out of a dir while `lsof +D` reported exit 1.
#   * `pgrep -f` catches a process whose command line names the dir, which is
#     how a running browser shows up. Own pid is excluded so the caller's own
#     argv (which contains the path) is never mistaken for a running process.
# Absence of both tools is treated as "in use" — refusing to guess is the safe
# default for a deletion guard.
am_in_use(){
  [ -e "$1" ] || return 1
  local found=0 pids
  if command -v lsof >/dev/null 2>&1; then
    # Test for OUTPUT, not exit status: lsof's exit code is unreliable on macOS
    # — it returns 1 even when it matched (measured: 3 matches, exit 1).
    [ -n "$(lsof -t +D "$1" 2>/dev/null)" ] && found=1
  fi
  if [ "$found" -eq 0 ] && command -v pgrep >/dev/null 2>&1; then
    # Own pid excluded so the caller's argv (which contains the path) is never
    # mistaken for a running process.
    pids="$(pgrep -f -- "$1" 2>/dev/null | grep -vx "$$" | grep -vx "${PPID:-0}")"
    [ -n "$pids" ] && found=1
  fi
  # If neither tool exists we cannot tell; refusing to guess means "in use".
  if ! command -v lsof >/dev/null 2>&1 && ! command -v pgrep >/dev/null 2>&1; then
    return 0
  fi
  [ "$found" -eq 1 ]
}

# Allowlist: one substring per line. Missing file means nothing is allowlisted.
am_allowlisted(){
  local path="$1" file="${2:-}"
  [ -n "$file" ] && [ -f "$file" ] || return 1
  grep -qF -f "$file" <<< "$path"
}

# Entries under $1 older than $2 days, excluding the newest $3. Newest-first
# ordering then tail is what makes "keep N newest regardless of age" work.
#
# Deliberately avoids `find -printf`, which is GNU-only and silently produces
# nothing on macOS — the mtime is fetched per entry through am_mtime instead so
# this behaves identically on both platforms.
am_stale_entries(){
  local root="$1" days="${2:-30}" keep="${3:-5}" e
  [ -d "$root" ] || return 0
  {
    find "$root" -maxdepth 1 -mindepth 1 -mtime "+$days" -print 2>/dev/null | while IFS= read -r e; do
      printf '%s %s\n' "$(am_mtime "$e")" "$e"
    done
  } | sort -rn | tail -n +$((keep + 1)) | cut -d' ' -f2-
}

# ── browser caches ───────────────────────────────────────────────────────────
# Playwright's cache is the ONE entry in the safe tier that is NOT safe by
# construction. Its other entries are purpose-built pruners (pnpm store prune
# drops unreferenced packages only; npm's _cacache is a re-download cache), but
# `rm -rf ms-playwright` destroys a ~560 MB pinned *binary* that does not
# rebuild on demand — Playwright hard-fails with "Executable doesn't exist"
# and the next agent run pays the full download again. Deleting the whole cache
# to reclaim its bytes costs the same bytes back, on a delay.
#
# So: prune superseded revisions only, and never a revision an installed
# playwright-core still pins. That keeps the reclaim useful (old revisions
# still go) without turning the next test run into a download.

# True if $1, or anything it symlinks to, is in use. A shared browser dir IS a
# symlink, and `lsof +D` does not follow symlinks — so without resolving the
# target first, a running browser would not protect the shared copy and a prune
# could delete a browser out from under a live test.
am_browser_dir_in_use(){
  local dir="$1" target
  am_in_use "$dir" && return 0
  # Resolve one level: <rev>/<platform-dir> -> real browser dir. Also covers the
  # hardlink-copied shell, where the files are shared by inode rather than path.
  for target in "$dir"/*; do
    [ -e "$target" ] || continue
    if [ -L "$target" ]; then
      local resolved; resolved="$(cd "$target" 2>/dev/null && pwd -P)" || continue
      am_in_use "$resolved" && return 0
    fi
  done
  # Hardlinks share the inode rather than the path, so a path-based check misses
  # them. Compare inodes of the executables against open files as a final guard.
  if command -v lsof >/dev/null 2>&1; then
    local exe inode open_inodes
    exe="$(find "$dir" -maxdepth 5 -type f \( -name 'chrome' -o -name 'chrome-headless-shell' -o -name 'Google Chrome for Testing' \) 2>/dev/null | head -1)"
    if [ -n "$exe" ]; then
      inode="$(am_inode "$exe")"
      if [ -n "$inode" ] && [ "$inode" != 0 ]; then
        open_inodes="$(lsof -n 2>/dev/null | awk -v n="$inode" '$0 ~ /chrome/ && $0 ~ (" " n " ") {print "hit"; exit}')"
        [ -n "$open_inodes" ] && return 0
      fi
    fi
  fi
  return 1
}

# Inode of a path (BSD and GNU differ), 0 if unknown.
am_inode(){
  stat -f %i "$1" 2>/dev/null || stat -c %i "$1" 2>/dev/null || echo 0
}

# Prints "name revision" pairs from a Playwright browsers.json.
# No JSON parser available (zero-dependency contract), and the file is
# machine-generated with a fixed key order — `name` is always immediately
# followed by `revision` — so flattening and matching is reliable here.
am_browsers_json_revisions(){
  local f="$1"
  [ -r "$f" ] || return 0
  tr -d '[:space:]' < "$f" \
    | grep -o '"name":"[^"]*","revision":"[^"]*"' \
    | sed -e 's/^"name":"//' -e 's/","revision":"/ /' -e 's/"$//'
}

# Prints "name revision" for every browser an install that uses THIS cache
# pins. The `.links` map is exactly the right source: Playwright writes one
# entry per playwright-core package that has installed into this cache, so a
# linked package is by definition a live consumer. A link whose package has
# been deleted resolves to nothing and contributes no pins.
am_browser_cache_refs(){
  local root="$1" link pkg
  [ -d "$root/.links" ] || return 0
  for link in "$root"/.links/*; do
    [ -f "$link" ] || continue
    pkg="$(cat "$link" 2>/dev/null)"
    [ -n "$pkg" ] && am_browsers_json_revisions "$pkg/browsers.json"
  done | sort -u
}

# Where each browser tool keeps its cache on this platform. Overridable, because
# these differ per OS *and* per user config — assume nothing, probe the paths the
# tool actually uses and let an env var redirect any of them.
#   AM_PLAYWRIGHT_CACHE, AM_PUPPETEER_CACHE
am_browser_cache_roots(){
  local d
  if [ -n "${AM_PLAYWRIGHT_CACHE:-}" ]; then
    printf '%s\n' "$AM_PLAYWRIGHT_CACHE"
  else
    case "$AM_PLATFORM" in
      macos) d="$HOME/Library/Caches/ms-playwright" ;;
      *)     d="${XDG_CACHE_HOME:-$HOME/.cache}/ms-playwright" ;;
    esac
    [ -d "$d" ] && printf '%s\n' "$d"
    # A non-default PLAYWRIGHT_BROWSERS_PATH means the tool never populated the
    # standard cache at all. Report it so a prune can see where browsers really are.
    if [ -n "${PLAYWRIGHT_BROWSERS_PATH:-}" ] && [ "$PLAYWRIGHT_BROWSERS_PATH" != "0" ]; then
      [ -d "$PLAYWRIGHT_BROWSERS_PATH" ] && printf '%s\n' "$PLAYWRIGHT_BROWSERS_PATH"
    fi
  fi
  if [ -n "${AM_PUPPETEER_CACHE:-}" ]; then
    printf '%s\n' "$AM_PUPPETEER_CACHE"
  else
    d="${PUPPETEER_CACHE_DIR:-$HOME/.cache/puppeteer}"
    [ -d "$d" ] && printf '%s\n' "$d"
  fi
}

# am_browser_cache_prune <cache_root> <dry:0|1> <emit_fn>
# Removes superseded browser revisions, keeping:
#   * any revision pinned by an installed playwright-core (.links),
#   * any revision a process currently has open (never yank a running binary),
#   * the newest $BROWSER_KEEP_NEWEST unreferenced revisions (rollback margin).
am_browser_cache_prune(){
  local root="$1" dry="${2:-0}" emit="${3:-am_default_emit}"
  [ -d "$root" ] || return 0
  local keep="${BROWSER_KEEP_NEWEST:-1}"
  local refs; refs="$(am_browser_cache_refs "$root")"
  # Callers scanning live repos (e.g. `browser-guard gc`) pass extra pins here.
  # The `.links` map is authoritative only for caches Playwright itself wrote to;
  # a *shared* root is populated by us, so the live repo scan is the real truth.
  # Format: "name rev; name rev; ..." separated by ';'.
  if [ -n "${AM_BROWSER_KEEP:-}" ]; then
    refs="$(printf '%s\n%s\n' "$refs" \
      "$(printf '%s' "$AM_BROWSER_KEEP" | tr ';' '\n' | sed 's/^ *//; s/ *$//' | grep -v '^$')" \
      | sort -u)"
  fi

  # Collect "<mtime> <name> <revision> <path>" for revision dirs.
  local cand="" d base rev
  for d in "$root"/*; do
    [ -d "$d" ] || continue
    base="${d##*/}"
    case "$base" in .*) continue ;; esac
    rev="${base##*-}"
    case "$rev" in ''|*[!0-9]*) continue ;; esac   # only <name>-<digits>
    cand="$cand$(am_mtime "$d") ${base%-*} $rev $d
"
  done
  [ -n "$cand" ] || return 0

  # Pass 1: drop referenced revisions from consideration.
  # Directory names and browsers.json names disagree on separators --
  # `chromium_headless_shell-1243` on disk is `chromium-headless-shell` in the
  # json -- so normalise both sides before comparing, or a pinned browser looks
  # unreferenced and gets deleted.
  local refs_norm; refs_norm="$(printf '%s\n' "$refs" | tr '-' '_')"
  local unreferenced="" line mt nm rv path
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    mt="${line%% *}"; line="${line#* }"
    nm="${line%% *}"; line="${line#* }"
    rv="${line%% *}"; path="${line#* }"
    if printf '%s\n' "$refs_norm" | grep -qx "$nm $rv"; then
      "$emit" SKIP "$nm r$rv kept — pinned by an installed playwright-core"
    elif am_browser_dir_in_use "$path"; then
      "$emit" SKIP "$nm r$rv kept — currently in use"
    else
      unreferenced="$unreferenced$mt $nm $rv $path
"
    fi
  done <<< "$cand"

  # Pass 2: newest-first, keep a rollback margin, discard the rest.
  local seen=0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    mt="${line%% *}"; line="${line#* }"
    nm="${line%% *}"; line="${line#* }"
    rv="${line%% *}"; path="${line#* }"
    seen=$((seen + 1))
    if [ "$seen" -le "$keep" ]; then
      "$emit" SKIP "$nm r$rv kept — newest $keep unreferenced revision(s)"
      continue
    fi
    if [ "$dry" -eq 1 ]; then
      "$emit" SKIP "would: remove superseded $nm r$rv ($(am_mib "$(am_du_kb "$path")") MiB)"
    else
      local freed; freed="$(am_mib "$(am_du_kb "$path")")"
      if rm -rf "$path" 2>/dev/null; then
        "$emit" ACTION "removed superseded $nm r$rv (frees ${freed} MiB)"
      else
        "$emit" SKIP "could not remove $nm r$rv"
      fi
    fi
  done <<< "$(printf '%s' "$unreferenced" | sort -rn)"
}

# ── safe-tier cache reclaim ──────────────────────────────────────────────────
# Mostly package-manager caches, all rebuilt on demand by their owning tool.
# Safe *by construction* — not by carefulness — because of what they are, not
# how carefully we delete them. The browser cache is the exception, and goes
# through am_browser_cache_prune instead of rm -rf (see above).
#
# am_reclaim_caches <dry:0|1> <emit_fn>
# emit_fn is called as: emit_fn ACTION|SKIP "message"
am_reclaim_caches(){
  local dry="${1:-0}" emit="${2:-am_default_emit}"
  local d

  _try(){ # _try <desc> <cmd...>
    local desc="$1"; shift
    if [ "$dry" -eq 1 ]; then "$emit" SKIP "would: $desc"; return; fi
    if "$@" >/dev/null 2>&1; then "$emit" ACTION "$desc"; else "$emit" SKIP "$desc (nothing to do)"; fi
  }

  command -v pnpm >/dev/null 2>&1 && _try "pnpm store prune (unreferenced only)" pnpm store prune
  command -v uv   >/dev/null 2>&1 && _try "uv cache prune"                       uv cache prune
  command -v npm  >/dev/null 2>&1 && _try "npm cache verify (_cacache is a re-download cache)" npm cache verify
  command -v pip  >/dev/null 2>&1 && _try "pip cache purge"                      pip cache purge
  command -v go   >/dev/null 2>&1 && _try "go clean -cache"                      go clean -cache

  # `bun pm cache rm` is the supported way; fall back to removing the dir only if
  # bun is absent but its cache is still on disk.
  if command -v bun >/dev/null 2>&1; then
    _try "bun pm cache rm" bun pm cache rm
  else
    d="$HOME/.bun/install/cache"
    [ -d "$d" ] && _try "bun install cache (bun not installed)" rm -rf "$d"
  fi

  command -v cargo-cache >/dev/null 2>&1 && _try "cargo cache --autoclean" cargo cache --autoclean

  # Browser binaries: superseded revisions only, never a pinned one. NOT the
  # rm -rf that used to be here — see the browser-caches section above for why
  # deleting the whole cache costs back every byte it reclaims. Roots are probed
  # per platform and honour AM_PLAYWRIGHT_CACHE / AM_PUPPETEER_CACHE overrides,
  # so a custom PLAYWRIGHT_BROWSERS_PATH is respected rather than assumed away.
  local bd
  while IFS= read -r bd; do
    [ -n "$bd" ] && am_browser_cache_prune "$bd" "$dry" "$emit"
  done < <(am_browser_cache_roots)

  # Platform-specific tail.
  case "$AM_PLATFORM" in
    macos)
      command -v brew >/dev/null 2>&1 && _try "brew cleanup -s" brew cleanup -s
      ;;
    wsl2|linux)
      # apt and journald need root; only touch them with passwordless sudo.
      if [ -d /var/cache/apt/archives ]; then
        if sudo -n true 2>/dev/null; then _try "apt-get clean" sudo -n apt-get clean
        else "$emit" SKIP "apt cache — needs: sudo apt-get clean"; fi
      fi
      if [ -d /var/log/journal ]; then
        if sudo -n true 2>/dev/null; then _try "journal vacuum (14d)" sudo -n journalctl --vacuum-time=14d
        else "$emit" SKIP "journal — needs: sudo journalctl --vacuum-time=14d"; fi
      fi
      ;;
  esac
}

am_default_emit(){ case "$1" in ACTION) am_act "$2";; *) am_info "$2";; esac; }

# ── delegation ───────────────────────────────────────────────────────────────
# Prefer a dedicated, better-tested tool over a half-copy of it. agent-session-kill
# handles agent transcripts with trash-first deletion and protection lists for
# auth/settings/skills — strictly better than re-implementing that here.
am_have_agent_session_kill(){ command -v agent-session-kill >/dev/null 2>&1; }

am_suggest_session_cleanup(){
  if am_have_agent_session_kill; then
    am_info "agent sessions: run 'agent-session-kill' (trash-first, protection lists)"
  else
    am_info "agent sessions: 'npm i -g agent-session-kill' for a safer interactive cleanup"
  fi
}
