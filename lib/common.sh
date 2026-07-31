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
# True if any process holds a file open under $1. Absence of lsof is treated as
# "in use" — refusing to guess is the safe default for a deletion guard.
am_in_use(){
  [ -e "$1" ] || return 1
  command -v lsof >/dev/null 2>&1 || return 0
  lsof +D "$1" >/dev/null 2>&1
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

# ── safe-tier cache reclaim ──────────────────────────────────────────────────
# Identical on macOS and WSL2: these are package-manager caches, and every one
# is rebuilt on demand by its owning tool. Safe *by construction* — not by
# carefulness — because of what they are, not how carefully we delete them.
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

  # Platform-specific tail.
  case "$AM_PLATFORM" in
    macos)
      d="$HOME/Library/Caches/ms-playwright"; [ -d "$d" ] && _try "playwright cache" rm -rf "$d"
      command -v brew >/dev/null 2>&1 && _try "brew cleanup -s" brew cleanup -s
      ;;
    wsl2|linux)
      d="$HOME/.cache/ms-playwright"; [ -d "$d" ] && _try "playwright cache" rm -rf "$d"
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
