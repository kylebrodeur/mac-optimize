#!/usr/bin/env bash
# uninstall.sh — unload the launchd agents and remove the deployed scripts.
# Leaves this repo intact. Logs are left in place (remove them manually if wanted).
set -uo pipefail

UID_N="$(id -u)"

for label in com.mac-optimize.diskguard com.mac-optimize.mac-reclaim; do
  launchctl bootout "gui/$UID_N/$label" 2>/dev/null || true
  rm -f "$HOME/Library/LaunchAgents/$label.plist"
  echo "removed agent  $label"
done

for s in mac-reclaim diskreport worktree-audit diskguard; do
  rm -f "$HOME/.local/bin/$s"
  echo "removed script $HOME/.local/bin/$s"
done

echo
echo "Done. Repo left intact."
echo "Optional: rm -f ~/Library/Logs/diskguard*.log ~/Library/Logs/mac-reclaim*.log"
