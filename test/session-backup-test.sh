#!/usr/bin/env bash
# session-backup-test.sh — self-contained tests for profile-driven backups.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$HERE/../bin/session-backup"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  FAIL %s [%s]\n' "$1" "$2"; }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else no "$1" "$2"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "python3 required"; exit 1; }
SANDBOX="$(mktemp -d)"
export HOME="$SANDBOX/home"
BACKUP_ROOT="$SANDBOX/drive/mac-optimize-backups"
mkdir -p "$HOME" "$BACKUP_ROOT"
export SESSION_BACKUP_DEST="$BACKUP_ROOT"
export NO_COLOR=1
trap 'rm -rf "$SANDBOX"' EXIT

PI="$HOME/.pi/agent/sessions"
OMP="$HOME/.omp/agent/sessions"
CC="$HOME/.claude"
DESKTOP="$HOME/Library/Application Support/Claude"

mkdir -p "$PI/project" "$OMP/project/run" "$CC/projects/project/session/subagents" \
  "$CC/file-history/session" "$DESKTOP/Cache" "$DESKTOP/vm_bundles"
printf '{"pi":true}\n' > "$PI/project/one.jsonl"
printf '{"omp":true}\n' > "$OMP/project/run.jsonl"
printf 'sidecar\n' > "$OMP/project/run/tool.log"
printf '{"nested":true}\n' > "$OMP/project/run/nested.jsonl"
printf '{"claude":true}\n' > "$CC/projects/project/session.jsonl"
printf '{"subagent":true}\n' > "$CC/projects/project/session/subagents/child.jsonl"
printf 'file history\n' > "$CC/file-history/session/version.txt"
printf 'persistent\n' > "$DESKTOP/Preferences"
printf 'cache\n' > "$DESKTOP/Cache/data"
printf 'vm\n' > "$DESKTOP/vm_bundles/rootfs.img"
printf 'derived index\n' > "$HOME/.pi/session-search-index.json"

printf '%s\n' '== profiles =='
PROFILES="$($TOOL profiles)"
check "profiles lists pi" "case \"$PROFILES\" in *pi*) true;; *) false;; esac"
check "profiles lists omp" "case \"$PROFILES\" in *omp*) true;; *) false;; esac"
check "profiles lists claude-code" "case \"$PROFILES\" in *claude-code*) true;; *) false;; esac"
check "profiles lists claude-desktop" "case \"$PROFILES\" in *claude-desktop*) true;; *) false;; esac"

printf '%s\n' '== backup =='
"$TOOL" backup all >/dev/null 2>&1
DEST="$BACKUP_ROOT/session-backups"
check "pi transcript copied" "[ -f '$DEST/pi/project/one.jsonl' ]"
check "omp parent copied" "[ -f '$DEST/omp/project/run.jsonl' ]"
check "omp sidecar copied" "[ -f '$DEST/omp/project/run/tool.log' ]"
check "omp nested sidecar copied" "[ -f '$DEST/omp/project/run/nested.jsonl' ]"
check "claude transcript copied" "[ -f '$DEST/claude-code/projects/project/session.jsonl' ]"
check "claude subagent copied" "[ -f '$DEST/claude-code/projects/project/session/subagents/child.jsonl' ]"
check "claude file history copied" "[ -f '$DEST/claude-code/file-history/session/version.txt' ]"
check "desktop persistent state copied" "[ -f '$DEST/claude-desktop/app-state/Preferences' ]"
check "desktop cache excluded" "[ ! -e '$DEST/claude-desktop/app-state/Cache/data' ]"
check "desktop vm bundle excluded" "[ ! -e '$DEST/claude-desktop/app-state/vm_bundles/rootfs.img' ]"
check "derived pi index excluded" "[ ! -e '$DEST/pi/session-search-index.json' ]"

python3 - "$DEST" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
for name in ("pi", "omp", "claude-code", "claude-desktop"):
    manifest = json.loads((root / name / "manifest.json").read_text())
    assert manifest["profile"] == name
    assert manifest["entries"], name
    assert all(len(entry["sha256"]) == 64 for entry in manifest["entries"])
assert any(unit["coupled"] for unit in json.loads((root / "omp" / "manifest.json").read_text())["units"])
PY
check "manifests contain content hashes" "[ \$? -eq 0 ]"

printf '%s\n' '== verify =='
"$TOOL" verify all >/dev/null 2>&1
check "verify passes after backup" "[ \$? -eq 0 ]"
STATUS="$($TOOL status all 2>&1)"
check "status reports four profiles" "case \"$STATUS\" in *'pi'*'omp'*'claude-code'*'claude-desktop'*) true;; *) false;; esac"

printf '%s\n' '== drift detection =='
printf 'changed\n' >> "$OMP/project/run/tool.log"
if "$TOOL" verify omp >/dev/null 2>&1; then
  no "verify detects changed source" "expected non-zero exit"
else
  ok "verify detects changed source"
fi

printf '%s\n' '== dry-run =='
rm -rf "$BACKUP_ROOT/dry-run"
"$TOOL" backup pi --dest "$BACKUP_ROOT/dry-run" --dry-run >/dev/null 2>&1
check "dry-run does not create manifest" "[ ! -e '$BACKUP_ROOT/dry-run/session-backups/pi/manifest.json' ]"

printf '%s\n' '== configurable OMP session dir =='
rm -rf "$BACKUP_ROOT/ompcustom"
CUSTOM_OMP="$SANDBOX/omp-sessions"
mkdir -p "$CUSTOM_OMP/project"
printf '{"omp":true}\n' > "$CUSTOM_OMP/project/redirected.jsonl"
mkdir -p "$HOME/.config/mac-optimize"
printf 'OMP_SESSION_DIR=%s\n' "$CUSTOM_OMP" > "$HOME/.config/mac-optimize/omp-session-dir.conf"
rm -rf "$DEST/omp"
"$TOOL" backup omp --dest "$BACKUP_ROOT/ompcustom" >/dev/null 2>&1
check "config-file relocation backed up" "[ -f '$BACKUP_ROOT/ompcustom/session-backups/omp/project/redirected.jsonl' ]"
check "config-file relocation skips default dir" "[ ! -e '$BACKUP_ROOT/ompcustom/session-backups/omp/project/run.jsonl' ]"

printf '%s\n' '== env override =='
rm -rf "$BACKUP_ROOT/ompenv"
ENV_OMP="$SANDBOX/omp-env-sessions"
mkdir -p "$ENV_OMP/project"
printf '{"omp":true}\n' > "$ENV_OMP/project/envonly.jsonl"
OMP_SESSION_DIR="$ENV_OMP" "$TOOL" backup omp --dest "$BACKUP_ROOT/ompenv" >/dev/null 2>&1
check "env override backed up" "[ -f '$BACKUP_ROOT/ompenv/session-backups/omp/project/envonly.jsonl' ]"
check "env override skips config dir" "[ ! -e '$BACKUP_ROOT/ompenv/session-backups/omp/project/redirected.jsonl' ]"

printf '\nsession-backup: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
