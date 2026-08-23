#!/usr/bin/env bash
# codex-backup-test.sh — self-contained regression harness for bin/codex-backup.
#
# Builds a disposable $HOME with a fake ~/.codex/sessions tree and a fake backup
# drive, then exercises every subcommand and asserts the safety-critical
# invariants:
#   * backup is cumulative (rsync, no --delete)
#   * prune is dry-run by default and only ever deletes files verified in backup
#   * prune keeps the N newest and anything NOT backed up
#   * restore round-trips byte-for-byte and never clobbers newer local files
#   * a scheduled --quiet backup no-ops (exit 0) when no drive is present
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TOOL="$HERE/../bin/codex-backup"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
no(){ FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; }
check(){ if eval "$2" >/dev/null 2>&1; then ok "$1"; else no "$1   [$2]"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "python3 required"; exit 1; }

SANDBOX="$(mktemp -d)"
export HOME="$SANDBOX/home"
BACKUP_ROOT="$SANDBOX/drive/mac-optimize-backups"
mkdir -p "$HOME" "$BACKUP_ROOT"
export CODEX_BACKUP_DEST="$BACKUP_ROOT"
export NO_COLOR=1
trap 'rm -rf "$SANDBOX"' EXIT

S="$HOME/.codex/sessions"
DEST="$BACKUP_ROOT/codex-sessions"

# mkfile <relpath> <cwd> <extra-KB> <touch-stamp YYYYMMDDhhmm>
mkfile(){
  local f="$S/$1"; mkdir -p "$(dirname "$f")"
  printf '{"timestamp":"x","type":"session_meta","payload":{"cwd":"%s"}}\n' "$2" > "$f"
  head -c $(( $3 * 1024 )) /dev/zero | tr '\0' 'x' >> "$f"
  touch -t "$4" "$f"
}

d_old=$(date -v-60d +%Y/%m/%d);      t_old=$(date -v-60d +%Y%m%d%H%M);  iso_old=$(date -v-60d +%Y-%m-%dT%H-%M-%S); day_old=$(date -v-60d +%Y-%m-%d)
d_mid=$(date -v-20d +%Y/%m/%d);      t_mid=$(date -v-20d +%Y%m%d%H%M);  iso_mid=$(date -v-20d +%Y-%m-%dT%H-%M-%S)
d_new=$(date -v-2d  +%Y/%m/%d);      t_new=$(date -v-2d  +%Y%m%d%H%M);  iso_new=$(date -v-2d  +%Y-%m-%dT%H-%M-%S)

OLD1="$d_old/rollout-$iso_old-000000000001.jsonl"
OLD2="$d_old/rollout-$iso_old-000000000002.jsonl"
MID1="$d_mid/rollout-$iso_mid-000000000003.jsonl"
NEW1="$d_new/rollout-$iso_new-000000000004.jsonl"
NEW2="$d_new/rollout-$iso_new-000000000005.jsonl"
mkfile "$OLD1" /proj/alpha 100 "$t_old"
mkfile "$OLD2" /proj/alpha 100 "$t_old"
mkfile "$MID1" /proj/beta   50 "$t_mid"
mkfile "$NEW1" /proj/beta   50 "$t_new"
mkfile "$NEW2" /proj/alpha  50 "$t_new"

echo "== backup =="
"$TOOL" backup --quiet
check "backup created dest tree"          "[ -f '$DEST/$OLD1' ]"
check "backup copied all 5"               "[ \$(find '$DEST' -name '*.jsonl' | wc -l) -eq 5 ]"
check "local index written"               "[ -f '$HOME/.codex/codex-backup-index.json' ]"
check "index counts 5 sessions"           "grep -q '\"count\": 5' '$HOME/.codex/codex-backup-index.json'"
check "on-drive index json written"       "[ -f '$BACKUP_ROOT/codex-index.json' ]"
check "on-drive index tsv written"        "[ -f '$BACKUP_ROOT/codex-index.tsv' ]"

echo "== verify =="
"$TOOL" verify >/dev/null 2>&1
check "verify exit 0 (all backed up)"     "[ \$? -eq 0 ]"
check "verify reports 5 verified"         "\"$TOOL\" verify | grep -q '5'"

echo "== prune dry-run (default) =="
DRY="$("$TOOL" prune --older-than 30 --keep-recent 1 2>&1)"
check "dry-run finds 2 safe files"        "echo \"\$DRY\" | grep -q 'safe to delete (verified in backup): 2 files'"
check "dry-run is non-destructive"        "[ -f '$S/$OLD1' ] && [ -f '$S/$OLD2' ]"
check "dry-run names it a dry run"        "echo \"\$DRY\" | grep -qi 'Dry-run'"

echo "== unsafe (not-backed-up) file is protected =="
UNSAFE="$d_old/rollout-$iso_old-0000000000ff.jsonl"
mkfile "$UNSAFE" /proj/gamma 10 "$t_old"     # created AFTER backup → no backup copy

echo "== prune --apply =="
APPLY="$("$TOOL" prune --older-than 30 --keep-recent 1 --apply 2>&1)"
check "apply deleted backed-up old1"      "[ ! -f '$S/$OLD1' ]"
check "apply deleted backed-up old2"      "[ ! -f '$S/$OLD2' ]"
check "backup still retains old1"         "[ -f '$DEST/$OLD1' ]"
check "unsafe file KEPT (no backup)"      "[ -f '$S/$UNSAFE' ]"
check "recent files kept (new/mid)"       "[ -f '$S/$NEW1' ] && [ -f '$S/$MID1' ]"
check "apply reports kept-unsafe"         "echo \"\$APPLY\" | grep -qi 'NOT backed up'"

echo "== restore round-trip =="
"$TOOL" restore --date "$day_old" >/dev/null 2>&1
check "restore brought old1 back"         "[ -f '$S/$OLD1' ]"
check "restored bytes match backup"       "cmp -s '$S/$OLD1' '$DEST/$OLD1'"

echo "== restore does not clobber newer local =="
printf 'LOCAL-NEWER\n' > "$S/$NEW1"; touch "$S/$NEW1"
"$TOOL" restore --date "$(date -v-2d +%Y-%m-%d)" >/dev/null 2>&1
check "newer local NEW1 untouched"        "grep -q 'LOCAL-NEWER' '$S/$NEW1'"

echo "== restore --cwd selector =="
OUT_CWD="$("$TOOL" restore --cwd /proj/alpha --to "$SANDBOX/restore-out" 2>&1)"
check "restore --cwd matched alpha files" "[ -f '$SANDBOX/restore-out/$OLD1' ]"
check "restore --cwd skipped beta files"  "[ ! -f '$SANDBOX/restore-out/$MID1' ]"

echo "== scheduled --quiet no-op without drive =="
env -u CODEX_BACKUP_DEST "$TOOL" backup --dest "$SANDBOX/not-mounted/mac-optimize-backups" --quiet
check "quiet no-op exits 0 when unmounted" "[ \$? -eq 0 ]"

echo
printf 'codex-backup: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
