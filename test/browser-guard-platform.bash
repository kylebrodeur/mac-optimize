#!/usr/bin/env bash
# Portability test: browser-guard must resolve the right Playwright layout on
# macOS, Linux, and Windows — not just the machine it was written on.
#
# The bug this guards: platform_dir() hardcoded `chrome-mac-arm64`, so the copy
# vendored into wsl-optimize (Linux) could never work. It also meant a macOS-x64
# or Linux user got a wrong path silently.
#
# Run: bash test/browser-guard-platform.bash

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BG="$REPO/bin/browser-guard"

FAILS=0
pass(){ printf '  ok   %s\n' "$1"; }
fail(){ printf '  FAIL %s\n' "$1"; FAILS=$((FAILS + 1)); }

# Source the tool without running its main dispatch, so we can call the pure
# platform helpers directly. `--help` exits 0 before dispatch is reached, but we
# need the functions; source a stripped copy instead.
STRIPPED="$(mktemp)"
sed '/^case "\$CMD" in/,$d' "$BG" > "$STRIPPED"
# shellcheck source=/dev/null
. "$STRIPPED"

# Probe a platform by shadowing uname, then asking for the resolved layout.
# $1 = uname -s, $2 = uname -m
probe(){
  uname(){ case "$1" in -s) printf '%s\n' "$U_S" ;; -m) printf '%s\n' "$U_M" ;; *) printf '%s\n' "$U_S" ;; esac; }
  U_S="$1" U_M="$2"
  printf '%s|%s|%s\n' "$(pw_platform)" "$(platform_dir chromium)" "$(executable_rel chromium)"
}

expect(){ # expect <desc> <got> <want>
  [ "$2" = "$3" ] && pass "$1" || fail "$1 — got [$2] want [$3]"
}

expect "macOS arm64 resolves Playwright's mac-arm64 layout" \
  "$(probe Darwin arm64)" \
  "mac-arm64|chrome-mac-arm64|Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"

expect "macOS x64 resolves mac-x64 (not arm64)" \
  "$(probe Darwin x86_64)" \
  "mac-x64|chrome-mac-x64|Google Chrome for Testing.app/Contents/MacOS/Google Chrome for Testing"

expect "Linux x64 resolves chrome-linux64 (the wsl-optimize case)" \
  "$(probe Linux x86_64)" \
  "linux-x64|chrome-linux64|chrome"

expect "Linux arm64 resolves chrome-linux-arm64" \
  "$(probe Linux aarch64)" \
  "linux-arm64|chrome-linux-arm64|chrome"

expect "Windows resolves chrome-win64 + .exe" \
  "$(probe MINGW64_NT-10.0 x86_64)" \
  "win-x64|chrome-win64|chrome.exe"

# The headless shell has its own table, and must not reuse the full browser's.
probe_headless(){
  uname(){ case "$1" in -s) printf '%s\n' "$U_S" ;; -m) printf '%s\n' "$U_M" ;; *) printf '%s\n' "$U_S" ;; esac; }
  U_S="$1" U_M="$2"
  printf '%s|%s\n' "$(platform_dir chromium-headless-shell)" "$(executable_rel chromium-headless-shell)"
}
expect "macOS headless shell dir + binary name" \
  "$(probe_headless Darwin arm64)" \
  "chrome-headless-shell-mac-arm64|chrome-headless-shell"
expect "Linux headless shell dir + binary name" \
  "$(probe_headless Linux x86_64)" \
  "chrome-headless-shell-linux64|chrome-headless-shell"
expect "Windows headless shell gets .exe" \
  "$(probe_headless MINGW64_NT-10.0 x86_64)" \
  "chrome-headless-shell-win64|chrome-headless-shell.exe"

# Cache roots must follow the platform, not assume macOS.
probe_cache(){
  uname(){ case "$1" in -s) printf '%s\n' "$U_S" ;; -m) printf '%s\n' "$U_M" ;; *) printf '%s\n' "$U_S" ;; esac; }
  U_S="$1" U_M="$2"
  printf '%s\n' "$(pw_cache_roots)"
}
expect "macOS cache root is Library/Caches" \
  "$(probe_cache Darwin arm64)" "$HOME/Library/Caches/ms-playwright"
expect "Linux cache root is ~/.cache" \
  "$(probe_cache Linux x86_64)" "$HOME/.cache/ms-playwright"

# The executable path builder must compose them consistently.
uname(){ case "$1" in -s) printf '%s\n' "$U_S" ;; -m) printf '%s\n' "$U_M" ;; *) printf '%s\n' "$U_S" ;; esac; }
U_S=Linux U_M=x86_64
expect "Linux executable_in composes the full path" \
  "$(executable_in /shared chromium-headless-shell 1243)" \
  "/shared/chromium_headless_shell-1243/chrome-headless-shell-linux64/chrome-headless-shell"

unset -f uname
rm -f "$STRIPPED"

printf '\n%s\n' "$([ "$FAILS" -eq 0 ] && echo 'browser-guard platform tests passed' || echo "$FAILS check(s) failed")"
exit "$([ "$FAILS" -eq 0 ] && echo 0 || echo 1)"
