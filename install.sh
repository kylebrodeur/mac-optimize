#!/usr/bin/env bash
# install.sh — deploy the tooling into ~/.local/bin and load the launchd agents.
# Idempotent: safe to re-run; it copies fresh scripts and reloads the agents.
# Portable: the launchd plists are templates; __HOME__/__PATH__ are filled in
# here for the current user, so nothing is hardcoded to one machine.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
BINDIR="$HOME/.local/bin"
LADIR="$HOME/Library/LaunchAgents"
UID_N="$(id -u)"

# PATH baked into the launchd agents (they get a near-empty environment).
# Covers Apple Silicon (/opt/homebrew) and Intel (/usr/local) Homebrew plus the
# pnpm home; mac-reclaim's `command -v` guards skip whatever isn't installed.
LA_PATH="$HOME/.local/bin:$HOME/Library/pnpm:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$BINDIR" "$LADIR"

echo "Installing scripts → $BINDIR"
for f in "$REPO"/bin/*; do
  install -m 0755 "$f" "$BINDIR/$(basename "$f")"
  echo "  $(basename "$f")"
done

LIBDIR="$HOME/.local/lib/mac-optimize"
echo "Installing shared library → $LIBDIR"
mkdir -p "$LIBDIR"
install -m 0644 "$REPO/lib/common.sh" "$LIBDIR/common.sh"
echo "  common.sh (vendored from agent-machine-lib)"

echo "Installing + loading launchd agents → $LADIR"
for p in "$REPO"/launchd/*.plist; do
  label="$(basename "$p" .plist)"
  dest="$LADIR/$(basename "$p")"
  sed -e "s|__HOME__|$HOME|g" -e "s|__PATH__|$LA_PATH|g" "$p" > "$dest"
  launchctl bootout "gui/$UID_N/$label" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_N" "$dest"
  echo "  loaded $label"
done

echo
echo "Loaded agents:"
launchctl list | grep 'com\.mac-optimize\.' || echo "  (none — check errors above)"

cat <<'NOTE'

One-time note: the first time diskguard posts a low-disk banner, macOS may ask you
to allow notifications for the invoking process (osascript / Script Editor) under
System Settings → Notifications. No blocking dialogs are ever used, so a missed
banner is only cosmetic — the reclaim still runs and is logged to
~/Library/Logs/diskguard.log.
NOTE
